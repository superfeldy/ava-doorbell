#!/usr/bin/env python3
"""
AVA Doorbell v4.0 - Alarm/Event Scanner Service

Connects to a Dahua-compatible doorbell camera via HTTP event API using long-polling,
parses doorbell ring and alarm events, and publishes structured JSON to MQTT.

Features:
  - HTTP Digest authentication to doorbell event API
  - Dahua multipart event format parsing
  - MQTT publishing with configurable event types
  - Ring cooldown to prevent event spam
  - Auto-reconnect with exponential backoff
  - Graceful shutdown
  - Comprehensive error handling and logging
"""

import asyncio
import json
import logging
import os
import signal
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Any
from argparse import ArgumentParser

import httpx
import paho.mqtt.client as mqtt


# ============================================================================
# Configuration & Constants
# ============================================================================

DEFAULT_CONFIG_PATH = Path.home() / "ava-doorbell" / "config" / "config.json"
DEFAULT_MQTT_PORT = 1883
DEFAULT_EVENTS = ["DoorBell", "AlarmLocal", "VideoMotion", "MDResult",
                  "CallNoAnswered", "BackKeyLight", "VoiceDetect", "PhoneCallDetect",
                  "AccessControl", "CallSnap", "ProfileAlarmTransmit",
                  "LeFunctionStatusSync", "IntelliFrame",
                  # Commonly-seen codes that are NOT ring events — included so they
                  # don't flood the log as "Unrecognized event code".
                  "RtspSessionDisconnect", "VideoMotionInfo", "VideoTalk",
                  "_DoTalkAction_", "_CallRemoveMask", "TimeChange",
                  "NTPAdjustTime"]
DEFAULT_RING_COOLDOWN = 10  # seconds

# Event codes that indicate someone pressed the doorbell button.
# Different Dahua models report button presses differently:
#   - "DoorBell"          — standard ring event on most VTO models
#   - "AlarmLocal"        — physical button press on some models
#   - "PhoneCallDetect"   — VTO call-button press
#   - "CallNoAnswered"    — call initiated but not answered (still means someone rang)
#   - "BackKeyLight"      — button backlight triggered by press on some models
#   - "AccessControl"     — VTO intercom button on some firmware versions
RING_EVENT_CODES = {"DoorBell", "AlarmLocal", "PhoneCallDetect", "CallNoAnswered",
                    "BackKeyLight", "AccessControl"}
DEFAULT_RECONNECT_DELAYS = [5, 10, 20, 60]  # exponential backoff in seconds

# Logging configuration
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


# ============================================================================
# Configuration Loading
# ============================================================================

def load_config(config_path: Optional[str] = None) -> Dict[str, Any]:
    """
    Load configuration from JSON file.

    Args:
        config_path: Override config path (from CLI or env var)

    Returns:
        Configuration dictionary

    Raises:
        FileNotFoundError: If config file cannot be found
        json.JSONDecodeError: If config file is invalid JSON
    """
    path = Path(config_path or os.getenv("AVA_CONFIG") or DEFAULT_CONFIG_PATH)

    if not path.exists():
        raise FileNotFoundError(f"Config file not found: {path}")

    with open(path, "r") as f:
        config = json.load(f)

    logger.info(f"Loaded config from {path}")
    return config


# ============================================================================
# Event Parsing
# ============================================================================

def parse_dahua_event(line: str) -> Optional[Dict[str, Any]]:
    """
    Parse a single line from Dahua event stream.

    Expected format: Code=DoorBell;action=Start;index=0

    Args:
        line: Raw event line from HTTP stream

    Returns:
        Parsed event dict with 'code', 'action', 'index' keys, or None
    """
    line = line.strip()
    if not line or not line.startswith("Code="):
        return None

    event = {}
    for part in line.split(";"):
        if "=" in part:
            key, value = part.split("=", 1)
            event[key.lower()] = value

    if "code" in event:
        return event

    return None


# ============================================================================
# MQTT Client
# ============================================================================

class MQTTPublisher:
    """Thread-safe MQTT publisher with Last Will Testament support."""

    def __init__(
        self,
        broker_host: str = "localhost",
        broker_port: int = DEFAULT_MQTT_PORT,
        ring_topic: str = "doorbell/ring",
        event_topic: str = "doorbell/event",
        status_topic: str = "doorbell/status",
    ):
        self.broker_host = broker_host
        self.broker_port = broker_port
        self.ring_topic = ring_topic
        self.event_topic = event_topic
        self.status_topic = status_topic

        self.client = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
        self.client.will_set(status_topic, "offline", qos=1, retain=True)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect

        self._connected = False

    def _on_connect(self, client, userdata, connect_flags, rc, properties):
        if rc == 0:
            self._connected = True
            logger.info(f"MQTT connected to {self.broker_host}:{self.broker_port}")
            self.client.publish(self.status_topic, "online", qos=1, retain=True)
        else:
            logger.error(f"MQTT connection failed with code {rc}")
            self._connected = False

    def _on_disconnect(self, client, userdata, disconnect_flags, rc, properties):
        self._connected = False
        if rc != 0:
            logger.warning(f"MQTT disconnected unexpectedly with code {rc}")
        else:
            logger.info("MQTT disconnected")

    def connect(self):
        try:
            self.client.connect(self.broker_host, self.broker_port, keepalive=60)
            self.client.loop_start()
        except Exception as e:
            logger.error(f"Failed to connect to MQTT: {e}")
            raise

    def disconnect(self):
        try:
            self.client.publish(self.status_topic, "offline", qos=1, retain=True)
            self.client.loop_stop()
            self.client.disconnect()
        except Exception as e:
            logger.error(f"Error disconnecting from MQTT: {e}")

    def publish_ring(self, event: Dict[str, Any]):
        payload = json.dumps({
            "event": event.get("code"),
            "action": event.get("action"),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "index": event.get("index", 0),
            "source": "doorbell",
        })
        self.client.publish(self.ring_topic, payload, qos=1)
        logger.info(f"Published ring event: {payload}")

    def publish_event(self, event: Dict[str, Any]):
        payload = json.dumps({
            "event": event.get("code"),
            "action": event.get("action"),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "index": event.get("index", 0),
            "source": "doorbell",
        })
        self.client.publish(self.event_topic, payload, qos=0)
        logger.debug(f"Published event: {payload}")


# ============================================================================
# Event Scanner
# ============================================================================

class DoorBellEventScanner:
    """Async event scanner for Dahua doorbell camera."""

    def __init__(
        self,
        doorbell_ip: str,
        doorbell_username: str,
        doorbell_password: str,
        mqtt_publisher: MQTTPublisher,
        event_codes: Optional[List[str]] = None,
        ring_cooldown: int = DEFAULT_RING_COOLDOWN,
    ):
        self.doorbell_ip = doorbell_ip
        self.doorbell_username = doorbell_username
        self.doorbell_password = doorbell_password
        self.mqtt_publisher = mqtt_publisher
        self.event_codes = event_codes or DEFAULT_EVENTS
        self.ring_cooldown = ring_cooldown

        self.event_url = f"http://{doorbell_ip}/cgi-bin/eventManager.cgi?action=attach&codes=[All]"
        self.running = False
        self.last_ring_time = 0
        self.reconnect_attempt = 0

    async def start(self):
        self.running = True
        while self.running:
            try:
                await self._connect_and_stream()
            except asyncio.CancelledError:
                logger.info("Event scanner cancelled")
                break
            except Exception as e:
                logger.error(f"Unexpected error in event loop: {e}", exc_info=True)
            if self.running:
                await self._reconnect()

    async def _connect_and_stream(self):
        auth = httpx.DigestAuth(self.doorbell_username, self.doorbell_password)
        timeout = httpx.Timeout(connect=10.0, read=None, write=10.0, pool=10.0)

        async with httpx.AsyncClient(auth=auth, timeout=timeout) as client:
            try:
                async with client.stream("GET", self.event_url) as resp:
                    if resp.status_code != 200:
                        logger.error(
                            f"Event API returned status {resp.status_code} "
                            f"(url={self.doorbell_ip}, user={self.doorbell_username})"
                        )
                        return

                    logger.info(f"Connected to doorbell event stream at {self.doorbell_ip}")
                    self.reconnect_attempt = 0
                    await self._read_stream(resp)

            except httpx.TimeoutException:
                logger.warning("Event stream timeout, reconnecting...")
                raise
            except httpx.HTTPError as e:
                logger.warning(f"HTTP client error: {e}")
                raise

    async def _read_stream(self, resp):
        async for line_str in resp.aiter_lines():
            if not self.running:
                break

            line_str = line_str.strip()
            if not line_str:
                continue

            if line_str.startswith("Code="):
                logger.debug(f"Raw event line: {line_str}")

            event = parse_dahua_event(line_str)
            if event:
                code = event.get("code", "")
                if code in self.event_codes:
                    await self._handle_event(event)
                else:
                    logger.debug(f"Unrecognized event code: {code} (raw: {line_str})")

    async def _handle_event(self, event: Dict[str, Any]):
        code = event.get("code")
        action = event.get("action")

        logger.info(f"Event detected: {code} ({action})")
        self.mqtt_publisher.publish_event(event)

        is_ring = (code in RING_EVENT_CODES and action == "Start")

        if is_ring:
            now = asyncio.get_event_loop().time()
            if now - self.last_ring_time >= self.ring_cooldown:
                logger.info(f"RING detected via {code} ({action}) — publishing to ring topic")
                self.mqtt_publisher.publish_ring(event)
                self.last_ring_time = now
            else:
                logger.debug(f"Ring event suppressed by cooldown (elapsed: {now - self.last_ring_time:.1f}s)")

    async def _reconnect(self):
        delays = DEFAULT_RECONNECT_DELAYS
        delay = delays[min(self.reconnect_attempt, len(delays) - 1)]
        logger.warning(f"Reconnecting in {delay} seconds (attempt {self.reconnect_attempt + 1})")
        await asyncio.sleep(delay)
        self.reconnect_attempt += 1

    def stop(self):
        self.running = False


# ============================================================================
# Main Application
# ============================================================================

class AlarmScannerApp:
    """Main application coordinator."""

    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.mqtt_publisher = None
        self.event_scanner = None
        self._task = None

    def initialize(self):
        doorbell_cfg = self.config.get("doorbell", {})
        server_cfg = self.config.get("server", {})
        notif_cfg = self.config.get("notifications", {})

        doorbell_ip = doorbell_cfg.get("ip", "localhost")
        doorbell_username = doorbell_cfg.get("username", "admin")
        doorbell_password = doorbell_cfg.get("password", "")
        mqtt_port = server_cfg.get("mqtt_port", DEFAULT_MQTT_PORT)
        event_codes = doorbell_cfg.get("events", DEFAULT_EVENTS)
        ring_cooldown = notif_cfg.get("ring_cooldown_seconds", DEFAULT_RING_COOLDOWN)

        ring_topic = notif_cfg.get("mqtt_topic_ring", "doorbell/ring")
        event_topic = notif_cfg.get("mqtt_topic_event", "doorbell/event")
        status_topic = notif_cfg.get("mqtt_topic_status", "doorbell/status")

        logger.info(f"Initializing with doorbell IP: {doorbell_ip}")
        logger.info(f"Monitoring events: {', '.join(event_codes)}")
        logger.info(f"Ring cooldown: {ring_cooldown}s")

        self.mqtt_publisher = MQTTPublisher(
            broker_host="localhost",
            broker_port=mqtt_port,
            ring_topic=ring_topic,
            event_topic=event_topic,
            status_topic=status_topic,
        )
        self.mqtt_publisher.connect()

        self.event_scanner = DoorBellEventScanner(
            doorbell_ip=doorbell_ip,
            doorbell_username=doorbell_username,
            doorbell_password=doorbell_password,
            mqtt_publisher=self.mqtt_publisher,
            event_codes=event_codes,
            ring_cooldown=ring_cooldown,
        )

    async def run(self):
        self._task = asyncio.create_task(self.event_scanner.start())
        try:
            await self._task
        except asyncio.CancelledError:
            logger.info("Application cancelled")

    def shutdown(self):
        logger.info("Shutting down...")
        if self.event_scanner:
            self.event_scanner.stop()
        if self._task:
            self._task.cancel()
        if self.mqtt_publisher:
            self.mqtt_publisher.disconnect()
        logger.info("Shutdown complete")

    def publish_test_ring(self):
        if not self.mqtt_publisher:
            logger.error("MQTT not initialized")
            return
        test_event = {
            "code": "DoorBell",
            "action": "Start",
            "index": "0",
        }
        self.mqtt_publisher.publish_ring(test_event)
        logger.info("Published test ring event")


# ============================================================================
# Entry Point
# ============================================================================

def main():
    parser = ArgumentParser(description="AVA Doorbell v4.0 - Alarm/Event Scanner Service")
    parser.add_argument("--config", help="Override config file path")
    parser.add_argument("--test", action="store_true", help="Publish test event and exit")

    args = parser.parse_args()

    try:
        config = load_config(args.config)
    except FileNotFoundError as e:
        logger.error(f"Configuration error: {e}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON config: {e}")
        sys.exit(1)

    app = AlarmScannerApp(config)

    try:
        app.initialize()

        if args.test:
            import time
            # Wait for MQTT connection to be established
            for i in range(20):
                if app.mqtt_publisher._connected:
                    break
                time.sleep(0.25)
            if not app.mqtt_publisher._connected:
                logger.error("MQTT not connected after 5s — cannot send test ring")
                app.shutdown()
                return
            app.publish_test_ring()
            time.sleep(1)  # give MQTT time to deliver
            app.shutdown()
            logger.info("Test mode complete")
            return

        def signal_handler(signum, frame):
            logger.info(f"Received signal {signum}, initiating shutdown")
            app.shutdown()
            sys.exit(0)

        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)

        asyncio.run(app.run())

    except Exception as e:
        logger.error(f"Fatal error: {e}", exc_info=True)
        app.shutdown()
        sys.exit(1)


if __name__ == "__main__":
    main()
