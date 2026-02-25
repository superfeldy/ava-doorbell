#!/usr/bin/env python3
"""
AVA Doorbell v4.5 Two-Way Audio Relay Service

WebSocket server that relays Android/browser microphone audio (PCM16 or G.711A)
to a Dahua doorbell camera via direct RTSP backchannel.

Audio path:
  Android NativeTalkManager → WebSocket (PCM16) → this service → G.711A →
  RTP over TCP → doorbell RTSP backchannel → speaker

Requirements:
  - Doorbell must support ONVIF backchannel with unicast=true&proto=Onvif
  - Correct ITU-T G.711 A-law encoding
  - Software AGC for quiet Android mic input
"""

import asyncio
import hashlib
import json
import logging
import math
import os
import random
import re
import signal
import socket
import ssl
import struct
import sys
import time
from pathlib import Path
from typing import Optional, Set
from dataclasses import dataclass

import websockets
from websockets.asyncio.server import serve as ws_serve, ServerConnection


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


# =============================================================================
# G.711 A-law Encoding
# =============================================================================

def _linear2alaw(pcm: int) -> int:
    """ITU-T G.711 A-law encoding of a single signed 16-bit PCM sample."""
    if pcm >= 0:
        sign = 0x00
    else:
        sign = 0x80
        pcm = -pcm
    if pcm > 32767:
        pcm = 32767

    if pcm >= 256:
        exponent = 7
        mask = 0x4000
        for i in range(7, 0, -1):
            if pcm & mask:
                exponent = i
                break
            mask >>= 1
        mantissa = (pcm >> (exponent + 3)) & 0x0F
    else:
        exponent = 0
        mantissa = pcm >> 4

    alaw = sign | (exponent << 4) | mantissa
    return alaw ^ 0x55


def _build_alaw_table() -> list[int]:
    """Pre-compute 65536-entry A-law lookup table."""
    table = []
    for u in range(65536):
        if u >= 32768:
            signed_val = u - 65536
        else:
            signed_val = u
        table.append(_linear2alaw(signed_val))
    return table


ALAW_TABLE = _build_alaw_table()
ALAW_SILENCE = 0xD5

# ---------------------------------------------------------------------------
# Software AGC + Noise Gate + Smoothing
# ---------------------------------------------------------------------------
# NOTE: Android VOICE_COMMUNICATION + AutomaticGainControl handles mic gain.
# Server-side gain should be minimal — just gentle leveling, no heavy boost.
AGC_TARGET = 12000          # target output level
AGC_MIN_GAIN = 1            # unity for close-up speech (peaks ~17000)
AGC_MAX_GAIN = 30           # boost for normal-distance speech (peaks ~300)
AGC_ATTACK = 0.05           # very fast gain reduction — catches loud transients in 1 chunk
AGC_RELEASE = 0.90          # fast release — recover gain in ~15 chunks (0.6s)
                            # noise gate masks gain recovery so pumping isn't audible
NOISE_GATE_THRESHOLD = 30   # gate threshold — let quiet speech tails through
NOISE_GATE_HOLD_CHUNKS = 12 # longer hold — prevents choppy speech tails
# Soft limiter: logarithmic compression above SOFT_LIMIT prevents clipping
SOFT_LIMIT = 12000          # compress above this level
SOFT_CEILING = 28000        # max output after compression (below 32767 hard clip)


@dataclass
class Config:
    """Configuration loaded from config.json."""
    doorbell_ip: str
    doorbell_username: str
    doorbell_password: str
    doorbell_rtsp_port: int = 554
    talk_port: int = 5001
    go2rtc_api: str = "http://127.0.0.1:1984"
    doorbell_stream: str = "doorbell_direct"


def load_config(config_path: Optional[str] = None) -> Config:
    """Load configuration from JSON file."""
    if config_path is None:
        config_path = os.getenv('AVA_CONFIG', str(Path.home() / 'ava-doorbell' / 'config' / 'config.json'))

    try:
        with open(config_path) as f:
            data = json.load(f)

        doorbell = data.get('doorbell', {})
        server = data.get('server', {})

        doorbell_stream = "doorbell_direct"
        for cam in data.get('cameras', []):
            if cam.get('talk_enabled', False):
                doorbell_stream = cam.get('id', doorbell_stream)
                break

        return Config(
            doorbell_ip=doorbell.get('ip'),
            doorbell_username=doorbell.get('username'),
            doorbell_password=doorbell.get('password'),
            doorbell_rtsp_port=doorbell.get('rtsp_port', 554),
            talk_port=server.get('talk_port', 5001),
            go2rtc_api="http://127.0.0.1:1984",
            doorbell_stream=doorbell_stream,
        )
    except Exception as e:
        logger.error(f"Failed to load config: {e}")
        raise


# =============================================================================
# Direct RTSP Backchannel to Doorbell
# =============================================================================

class DirectRtspBackchannel:
    """Sends A-law audio directly to doorbell via RTSP TCP interleaved backchannel.

    Connects to the doorbell's RTSP server with Require: www.onvif.org/ver20/backchannel
    and unicast=true&proto=Onvif, SETUPs the sendonly track, and sends RTP PCMA/8000
    packets interleaved over TCP. No go2rtc or ffmpeg middleman.
    """

    def __init__(self, config: Config):
        self.config = config
        self._sock: Optional[socket.socket] = None
        self._cseq = 0
        self._session: Optional[str] = None
        self._auth: Optional[str] = None
        self._realm: Optional[str] = None
        self._nonce: Optional[str] = None
        self._interleaved_channel = 0  # TCP interleaved channel for RTP
        self._rtp_seq = random.randint(0, 65535)
        self._rtp_ts = random.randint(0, 0xFFFFFFFF)
        self._rtp_ssrc = random.randint(0, 0xFFFFFFFF)
        self.connected = False

    def _next_cseq(self) -> int:
        self._cseq += 1
        return self._cseq

    def _digest_auth(self, method: str, uri: str) -> str:
        """Compute Digest authentication header."""
        user = self.config.doorbell_username
        pwd = self.config.doorbell_password
        ha1 = hashlib.md5(f"{user}:{self._realm}:{pwd}".encode()).hexdigest()
        ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
        response = hashlib.md5(f"{ha1}:{self._nonce}:{ha2}".encode()).hexdigest()
        return (f'Digest username="{user}", realm="{self._realm}", '
                f'nonce="{self._nonce}", uri="{uri}", response="{response}"')

    def _send_rtsp(self, request: str) -> str:
        """Send RTSP request and read response."""
        self._sock.sendall(request.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionError("RTSP connection closed")
            resp += chunk

        header_end = resp.index(b"\r\n\r\n") + 4
        header_text = resp[:header_end].decode()

        # Read body if Content-Length present
        cl_match = re.search(r'Content-Length:\s*(\d+)', header_text, re.IGNORECASE)
        if cl_match:
            body_len = int(cl_match.group(1))
            body = resp[header_end:]
            while len(body) < body_len:
                body += self._sock.recv(4096)
            return header_text + body.decode(errors='replace')

        return header_text

    def _rtsp_request(self, method: str, uri: str, extra_headers: str = "") -> str:
        """Send RTSP request with optional Digest auth, return response."""
        cseq = self._next_cseq()
        auth_hdr = ""
        if self._auth:
            auth_hdr = f"Authorization: {self._digest_auth(method, uri)}\r\n"
        session_hdr = ""
        if self._session:
            session_hdr = f"Session: {self._session}\r\n"

        req = (f"{method} {uri} RTSP/1.0\r\n"
               f"CSeq: {cseq}\r\n"
               f"User-Agent: AVA-Talk/1.0\r\n"
               f"{auth_hdr}{session_hdr}{extra_headers}\r\n")

        resp = self._send_rtsp(req)
        status_line = resp.split("\r\n")[0]

        # Handle 401 — authenticate and retry
        if "401" in status_line and not self._auth:
            realm_m = re.search(r'realm="([^"]+)', resp)
            nonce_m = re.search(r'nonce="([^"]+)', resp)
            if realm_m and nonce_m:
                self._realm = realm_m.group(1)
                self._nonce = nonce_m.group(1)
                self._auth = "digest"
                return self._rtsp_request(method, uri, extra_headers)

        return resp

    # Error codes returned by _connect_sync for caller to distinguish failure types
    ERR_NONE = ""
    ERR_DESCRIBE_404 = "describe_404"
    ERR_DESCRIBE_OTHER = "describe_other"
    ERR_NO_TRACK = "no_backchannel_track"
    ERR_SETUP = "setup_failed"
    ERR_PLAY = "play_failed"
    ERR_EXCEPTION = "exception"

    async def connect(self) -> str:
        """Connect to doorbell RTSP and set up backchannel.

        Returns: empty string on success, or an ERR_* code on failure.
        """
        loop = asyncio.get_running_loop()
        try:
            return await loop.run_in_executor(None, self._connect_sync)
        except Exception as e:
            logger.error(f"Backchannel connect failed: {e}")
            await self.close()
            return self.ERR_EXCEPTION

    def _connect_sync(self) -> str:
        """Synchronous RTSP connection + SETUP + PLAY.

        Returns: empty string on success, or an ERR_* code on failure.
        """
        ip = self.config.doorbell_ip
        port = self.config.doorbell_rtsp_port
        base_url = (f"rtsp://{ip}:{port}/cam/realmonitor"
                    f"?channel=1&subtype=1&unicast=true&proto=Onvif")

        logger.info(f"Connecting to doorbell RTSP: {ip}:{port}")
        self._sock = socket.create_connection((ip, port), timeout=10)
        self._sock.settimeout(5)

        # DESCRIBE with Require header to get backchannel
        resp = self._rtsp_request(
            "DESCRIBE", base_url,
            "Accept: application/sdp\r\n"
            "Require: www.onvif.org/ver20/backchannel\r\n")

        status_line = resp.split("\r\n")[0]
        if "200" not in status_line:
            logger.error(f"DESCRIBE failed: {status_line}")
            return self.ERR_DESCRIBE_404 if "404" in status_line else self.ERR_DESCRIBE_OTHER

        # Find sendonly (backchannel) track
        bc_track = None
        for m in re.finditer(r'm=audio.*?(?=m=|\Z)', resp, re.DOTALL):
            block = m.group()
            if "sendonly" in block:
                track_m = re.search(r'control:(\S+)', block)
                if track_m:
                    bc_track = track_m.group(1)
                # Check if PCMA/8000 is supported
                if "PCMA/8000" not in block:
                    logger.error("Backchannel doesn't support PCMA/8000")
                    return self.ERR_NO_TRACK
                break

        if not bc_track:
            logger.error("No sendonly backchannel track in SDP")
            return self.ERR_NO_TRACK

        logger.info(f"Backchannel track: {bc_track}")

        # SETUP backchannel track with TCP interleaved
        setup_url = f"{base_url}/{bc_track}"
        resp = self._rtsp_request(
            "SETUP", setup_url,
            f"Transport: RTP/AVP/TCP;unicast;interleaved={self._interleaved_channel}-{self._interleaved_channel + 1};mode=record\r\n")

        if "200" not in resp.split("\r\n")[0]:
            logger.error(f"SETUP failed: {resp.split(chr(10))[0]}")
            return self.ERR_SETUP

        # Extract session ID
        sess_m = re.search(r'Session:\s*([^;\r\n]+)', resp)
        if sess_m:
            self._session = sess_m.group(1).strip()

        # Parse actual interleaved channels from response
        transport_m = re.search(r'interleaved=(\d+)-(\d+)', resp)
        if transport_m:
            self._interleaved_channel = int(transport_m.group(1))

        logger.info(f"SETUP OK, session={self._session}, channel={self._interleaved_channel}")

        # PLAY
        resp = self._rtsp_request("PLAY", base_url)
        if "200" not in resp.split("\r\n")[0]:
            logger.error(f"PLAY failed: {resp.split(chr(10))[0]}")
            return self.ERR_PLAY

        self._sock.settimeout(None)  # Non-blocking for sending
        self.connected = True
        logger.info("Direct RTSP backchannel ready — sending audio")
        return self.ERR_NONE

    def send_audio_sync(self, alaw_data: bytes) -> bool:
        """Send A-law audio as RTP over TCP interleaved (synchronous, non-blocking)."""
        if not self.connected or not self._sock:
            return False
        try:
            # Build RTP packet: PT=8 (PCMA), 8000 Hz clock
            rtp = bytearray(12 + len(alaw_data))
            rtp[0] = 0x80  # V=2, no padding, no extension, no CSRC
            rtp[1] = 8     # PT=8 (PCMA), no marker
            struct.pack_into('>H', rtp, 2, self._rtp_seq & 0xFFFF)
            struct.pack_into('>I', rtp, 4, self._rtp_ts & 0xFFFFFFFF)
            struct.pack_into('>I', rtp, 8, self._rtp_ssrc)
            rtp[12:] = alaw_data

            self._rtp_seq += 1
            self._rtp_ts += len(alaw_data)  # 1 sample = 1 byte for PCMA

            # TCP interleaved frame: $ + channel(1) + length(2) + RTP
            frame = bytearray(4 + len(rtp))
            frame[0] = 0x24  # '$'
            frame[1] = self._interleaved_channel
            struct.pack_into('>H', frame, 2, len(rtp))
            frame[4:] = rtp

            # Direct send — ~336 bytes on LAN is effectively instant
            self._sock.sendall(bytes(frame))
            return True
        except (BrokenPipeError, ConnectionError, OSError) as e:
            logger.warning(f"RTSP send failed: {e}")
            self.connected = False
            return False

    async def send_audio(self, alaw_data: bytes) -> bool:
        """Async wrapper for send_audio_sync."""
        return self.send_audio_sync(alaw_data)

    async def close(self) -> None:
        """Tear down RTSP session."""
        self.connected = False
        if self._sock and self._session:
            try:
                ip = self.config.doorbell_ip
                port = self.config.doorbell_rtsp_port
                base_url = (f"rtsp://{ip}:{port}/cam/realmonitor"
                            f"?channel=1&subtype=1&unicast=true&proto=Onvif")
                self._rtsp_request("TEARDOWN", base_url)
            except Exception:
                pass
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None
        self._session = None
        self._auth = None


# =============================================================================
# WebSocket Server
# =============================================================================

class TalkRelayServer:
    """WebSocket server for audio relay."""

    # Backchannel retry limits
    _BC_MAX_RETRIES = 5
    _BC_BACKOFF_BASE = 2.0   # seconds
    _BC_BACKOFF_MAX = 30.0   # seconds
    _BC_RESET_AT = 3          # attempt go2rtc reset after this many failures

    def __init__(self, config: Config):
        self.config = config
        self.clients: Set[ServerConnection] = set()
        self.backchannel: Optional[DirectRtspBackchannel] = None
        self.running = True
        # Per-server audio processing state (was class-level, corrupting across clients)
        self._diag_counter = 0
        self._agc_gain = float(AGC_MAX_GAIN)
        self._gate_hold = 0  # chunks remaining before gate closes
        # Backchannel retry state
        self._bc_fail_count = 0
        self._bc_backoff_until = 0.0
        self._bc_reset_attempted = False
        self._bc_gave_up = False

    async def handler(self, websocket: ServerConnection) -> None:
        self.clients.add(websocket)
        # Fresh mic session — reset backchannel retry state
        self._reset_bc_state()
        logger.info(f"Client connected. Total: {len(self.clients)}")

        msg_count = 0
        try:
            async for message in websocket:
                msg_count += 1
                if msg_count <= 3:
                    msg_type = type(message).__name__
                    msg_len = len(message) if isinstance(message, (bytes, str)) else 0
                    first_bytes = message[:8].hex() if isinstance(message, bytes) else repr(message[:50])
                    logger.info(f"WS msg #{msg_count}: type={msg_type}, len={msg_len}, first={first_bytes}")

                if isinstance(message, bytes) and len(message) > 1:
                    format_byte = message[0]
                    audio_data = message[1:]

                    if format_byte == 0x01:
                        alaw_data = self._pcm16_to_alaw(audio_data)
                    elif format_byte == 0x03:
                        alaw_data = audio_data
                    else:
                        logger.warning(f"Unknown format: {format_byte:#x}, len={len(message)}")
                        continue

                    if not self.backchannel or not self.backchannel.connected:
                        if not await self._open_backchannel(websocket):
                            continue

                    self.backchannel.send_audio_sync(alaw_data)

        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            self.clients.discard(websocket)
            logger.info(f"Client disconnected. Total: {len(self.clients)}")

            if not self.clients and self.backchannel:
                await self.backchannel.close()
                self.backchannel = None

    async def _open_backchannel(self, websocket: ServerConnection) -> bool:
        """Try to open backchannel with exponential backoff.

        Returns True if ready, False if unavailable/backing off.
        """
        if self.backchannel and self.backchannel.connected:
            return True

        if self._bc_gave_up:
            return False

        now = time.time()
        if now < self._bc_backoff_until:
            return False

        # First attempt for this session — notify client
        if self._bc_fail_count == 0:
            await self._send_status(websocket, "backchannel_connecting")

        self.backchannel = DirectRtspBackchannel(self.config)
        err = await self.backchannel.connect()

        if not err:
            # Success — reset state
            self._bc_fail_count = 0
            self._bc_backoff_until = 0.0
            self._bc_reset_attempted = False
            await self._send_status(websocket, "backchannel_ready")
            return True

        # Failed
        self._bc_fail_count += 1
        backoff = min(self._BC_BACKOFF_BASE * (2 ** (self._bc_fail_count - 1)), self._BC_BACKOFF_MAX)
        self._bc_backoff_until = time.time() + backoff
        logger.warning(f"Backchannel {err} — attempt #{self._bc_fail_count}, retry in {backoff:.0f}s")

        # After _BC_RESET_AT failures with 404, try go2rtc reset (once per session)
        if (err == DirectRtspBackchannel.ERR_DESCRIBE_404
                and self._bc_fail_count == self._BC_RESET_AT
                and not self._bc_reset_attempted):
            self._bc_reset_attempted = True
            recovered = await self._reset_doorbell_rtsp()
            if recovered:
                return True

        # Give up after max retries
        if self._bc_fail_count >= self._BC_MAX_RETRIES:
            logger.error(f"Backchannel unavailable after {self._bc_fail_count} attempts — giving up for this session")
            self._bc_gave_up = True
            await self._send_status(websocket, "backchannel_unavailable")
            return False

        await self._send_status(websocket, "backchannel_failed", retry_in=int(backoff))
        return False

    def _reset_bc_state(self) -> None:
        """Reset backchannel retry state for a new mic session."""
        self._bc_fail_count = 0
        self._bc_backoff_until = 0.0
        self._bc_reset_attempted = False
        self._bc_gave_up = False

    async def _reset_doorbell_rtsp(self) -> bool:
        """Disconnect and reconnect go2rtc's stream to reset doorbell RTSP state.

        Some Dahua VTO doorbells stop accepting the backchannel Require header
        after ring events or session timeouts. Cycling go2rtc's connection forces
        the doorbell's RTSP server to reset, which can re-enable backchannel.

        Returns True if backchannel recovered after reset.
        """
        go2rtc_api = self.config.go2rtc_api  # e.g. http://127.0.0.1:1984
        stream_name = self.config.doorbell_stream  # e.g. doorbell_direct

        logger.info("Attempting go2rtc stream reset to unstick doorbell backchannel")

        loop = asyncio.get_running_loop()
        try:
            source_url = await loop.run_in_executor(None, self._go2rtc_reset_sync, go2rtc_api, stream_name)
            if not source_url:
                return False

            # Wait for doorbell RTSP server to release state + go2rtc to reconnect
            await asyncio.sleep(4)

            # Retry backchannel after reset
            self.backchannel = DirectRtspBackchannel(self.config)
            err = await self.backchannel.connect()
            if not err:
                logger.info("Backchannel recovered after go2rtc reset!")
                self._bc_fail_count = 0
                self._bc_backoff_until = 0.0
                return True

            logger.warning(f"Backchannel still failing after go2rtc reset: {err}")
            return False

        except Exception as e:
            logger.error(f"go2rtc reset failed: {e}")
            return False

    @staticmethod
    def _go2rtc_reset_sync(go2rtc_api: str, stream_name: str) -> Optional[str]:
        """Synchronous go2rtc stream disconnect + reconnect. Returns source URL or None."""
        import urllib.request
        import urllib.parse

        try:
            # Get current stream sources
            req = urllib.request.Request(f"{go2rtc_api}/api/streams")
            with urllib.request.urlopen(req, timeout=5) as resp:
                streams = json.loads(resp.read())

            stream_info = streams.get(stream_name)
            if not stream_info:
                logger.warning(f"Stream '{stream_name}' not found in go2rtc")
                return None

            # Find the RTSP producer URL
            source_url = None
            for p in (stream_info.get("producers") or []):
                url = p.get("url", "")
                if url.startswith("rtsp://"):
                    source_url = url
                    break

            if not source_url:
                logger.warning("No RTSP producer found for stream")
                return None

            params = urllib.parse.urlencode({"dst": stream_name, "src": source_url})

            # DELETE — disconnect go2rtc from doorbell
            logger.info(f"Disconnecting go2rtc stream '{stream_name}'")
            req = urllib.request.Request(f"{go2rtc_api}/api/streams?{params}", method="DELETE")
            with urllib.request.urlopen(req, timeout=5) as resp:
                pass

            time.sleep(2)

            # PUT — reconnect go2rtc to doorbell
            logger.info(f"Reconnecting go2rtc stream '{stream_name}'")
            req = urllib.request.Request(f"{go2rtc_api}/api/streams?{params}", method="PUT")
            with urllib.request.urlopen(req, timeout=5) as resp:
                pass

            return source_url

        except Exception as e:
            logger.error(f"go2rtc API call failed: {e}")
            return None

    async def _send_status(self, websocket: ServerConnection, status: str, **kwargs) -> None:
        """Send a JSON status message to the WebSocket client."""
        try:
            msg = {"status": status, **kwargs}
            await websocket.send(json.dumps(msg))
        except Exception:
            pass  # Client may have disconnected

    def _pcm16_to_alaw(self, pcm_data: bytes) -> bytes:
        num_samples = len(pcm_data) // 2

        # Batch-unpack all PCM samples at once (~10x faster than per-sample int.from_bytes)
        raw = list(struct.unpack_from(f'<{num_samples}h', pcm_data))

        if not raw:
            return b''

        # --- 5-tap weighted moving average to smooth high-frequency noise ---
        # Kernel: [1, 2, 4, 2, 1] / 10  — stronger than 3-tap, removes
        # sample-to-sample oscillations that sound harsh after A-law encoding.
        n = len(raw)
        smoothed = [0] * n
        # Edge samples: use narrower kernel
        smoothed[0] = (raw[0] * 4 + raw[1] * 2 + raw[min(2, n-1)]) // 7
        if n > 1:
            smoothed[1] = (raw[0] * 2 + raw[1] * 4 + raw[2] * 2 + raw[min(3, n-1)]) // 9
        for i in range(2, n - 2):
            smoothed[i] = (raw[i-2] + raw[i-1] * 2 + raw[i] * 4 + raw[i+1] * 2 + raw[i+2]) // 10
        if n > 2:
            smoothed[n-2] = (raw[max(0, n-4)] + raw[n-3] * 2 + raw[n-2] * 4 + raw[n-1] * 2) // 9
        smoothed[n-1] = (raw[max(0, n-3)] + raw[n-2] * 2 + raw[n-1] * 4) // 7

        chunk_peak = max(abs(s) for s in smoothed)

        # Noise gate: suppress background noise when no speech detected
        if chunk_peak >= NOISE_GATE_THRESHOLD:
            self._gate_hold = NOISE_GATE_HOLD_CHUNKS
        elif self._gate_hold > 0:
            self._gate_hold -= 1
        else:
            # Gate closed — return silence
            return bytes([ALAW_SILENCE] * n)

        # AGC — modest gain, slow dynamics to avoid pumping artifacts
        gain = self._agc_gain
        if chunk_peak > 0:
            ideal_gain = AGC_TARGET / chunk_peak
            ideal_gain = max(AGC_MIN_GAIN, min(AGC_MAX_GAIN, ideal_gain))
            if ideal_gain < gain:
                gain = gain * AGC_ATTACK + ideal_gain * (1 - AGC_ATTACK)
            else:
                gain = gain * AGC_RELEASE + ideal_gain * (1 - AGC_RELEASE)
        gain = max(AGC_MIN_GAIN, min(AGC_MAX_GAIN, gain))
        self._agc_gain = gain
        int_gain = int(gain)

        # Diagnostic logging — first 10 chunks + every 50th chunk for speech data
        self._diag_counter += 1
        if self._diag_counter <= 10 or self._diag_counter % 50 == 0:
            rms = int((sum(s*s for s in smoothed) / len(smoothed)) ** 0.5)
            boosted_peak = min(32767, chunk_peak * int_gain)
            logger.info(
                f"PCM diag #{self._diag_counter}: "
                f"peak={chunk_peak}, rms={rms}, gain={int_gain}x, "
                f"boosted_peak={boosted_peak}, "
                f"gate={'OPEN' if self._gate_hold > 0 else 'CLOSED'}, "
                f"first5_raw={raw[:5]}, first5_smooth={smoothed[:5]}"
            )

        # Apply gain + soft limiter + encode to A-law
        headroom = SOFT_CEILING - SOFT_LIMIT
        alaw = bytearray(n)
        for idx, signed_val in enumerate(smoothed):
            signed_val *= int_gain
            # Soft logarithmic limiter: compress signal above SOFT_LIMIT
            # Maps any level smoothly into SOFT_LIMIT..SOFT_CEILING range
            abs_val = abs(signed_val)
            if abs_val > SOFT_LIMIT:
                excess = abs_val - SOFT_LIMIT
                compressed = headroom * excess // (excess + headroom)
                signed_val = (SOFT_LIMIT + compressed) * (1 if signed_val > 0 else -1)
            # Hard clip safety (shouldn't normally hit)
            if signed_val > 32767:
                signed_val = 32767
            elif signed_val < -32768:
                signed_val = -32768
            if signed_val < 0:
                unsigned_val = signed_val + 65536
            else:
                unsigned_val = signed_val
            alaw[idx] = ALAW_TABLE[unsigned_val]
        return bytes(alaw)

    async def start(self) -> None:
        logger.info(f"Starting talk relay on port {self.config.talk_port}")
        logger.info(f"Doorbell: {self.config.doorbell_ip}:{self.config.doorbell_rtsp_port}")

        self._shutdown = asyncio.Event()

        ssl_ctx = None
        config_dir = Path(os.getenv('AVA_CONFIG', str(Path.home() / 'ava-doorbell' / 'config')))
        if config_dir.suffix == '.json':
            config_dir = config_dir.parent
        cert_file = config_dir / 'ssl' / 'ava-admin.crt'
        key_file = config_dir / 'ssl' / 'ava-admin.key'

        if cert_file.exists() and key_file.exists():
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ssl_ctx.load_cert_chain(str(cert_file), str(key_file))
            logger.info("SSL enabled for talk relay (wss://)")
        else:
            logger.warning("SSL certs not found — running without TLS (ws://)")

        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, self._handle_shutdown, sig)

        try:
            async with ws_serve(
                self.handler, '0.0.0.0', self.config.talk_port,
                ssl=ssl_ctx,
                ping_interval=20,
                ping_timeout=10,
                max_size=65536,  # 64KB max message — prevents DoS from oversized frames
            ):
                proto = "wss" if ssl_ctx else "ws"
                logger.info(f"WebSocket server listening on {proto}://0.0.0.0:{self.config.talk_port}")
                await self._shutdown.wait()
                logger.info("Shutdown signal received — closing server")
        finally:
            self.running = False
            if self.backchannel:
                await self.backchannel.close()

    def _handle_shutdown(self, sig):
        logger.info(f"Received signal {sig}, shutting down...")
        self._shutdown.set()


# =============================================================================
# Test Tone
# =============================================================================

async def test_tone(config: Config) -> None:
    """Generate and send a 5-second 600Hz test tone via direct RTSP backchannel."""
    logger.info("Generating 600Hz test tone...")

    sample_rate = 8000
    frequency = 600
    duration = 5

    # Generate A-law encoded tone
    alaw_data = bytearray()
    for i in range(sample_rate * duration):
        sample = int(32768 * 0.8 * math.sin(2 * math.pi * frequency * i / sample_rate))
        sample = max(-32768, min(32767, sample))
        if sample < 0:
            u = sample + 65536
        else:
            u = sample
        alaw_data.append(ALAW_TABLE[u])

    bc = DirectRtspBackchannel(config)
    if await bc.connect():
        # Write in chunks
        chunk_size = 320
        for i in range(0, len(alaw_data), chunk_size):
            chunk = alaw_data[i:i+chunk_size]
            if len(chunk) < chunk_size:
                chunk += bytes([ALAW_SILENCE] * (chunk_size - len(chunk)))
            await bc.send_audio(bytes(chunk))
            await asyncio.sleep(0.04)

        await bc.close()
        logger.info("Test tone sent successfully")
    else:
        logger.error("Failed to connect for test tone")


async def main() -> None:
    config_path = None
    test_tone_mode = False

    for arg in sys.argv[1:]:
        if arg == '--test-tone':
            test_tone_mode = True
        elif arg == '--config' and len(sys.argv) > sys.argv.index(arg) + 1:
            config_path = sys.argv[sys.argv.index(arg) + 1]

    try:
        config = load_config(config_path)
    except Exception as e:
        logger.error(f"Configuration error: {e}")
        sys.exit(1)

    if test_tone_mode:
        await test_tone(config)
        return

    server = TalkRelayServer(config)

    try:
        await server.start()
    except Exception as e:
        logger.error(f"Server error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    asyncio.run(main())
