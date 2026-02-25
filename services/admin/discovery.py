"""
AVA Doorbell v4.0 — Network Discovery

Scan local network for NVRs and doorbells. Probe NVR channels via RTSP.
Uses socket scanning only (no nmap dependency).
"""

import concurrent.futures
import logging
import socket
import subprocess
import threading
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# RTSP URL templates for different NVR/camera brands
NVR_URL_FORMATS = [
    # Dahua / Amcrest
    "rtsp://{user}:{pass}@{ip}:{port}/cam/realmonitor?channel={ch}&subtype={sub}",
    # Hikvision
    "rtsp://{user}:{pass}@{ip}:{port}/Streaming/Channels/{ch}{sub_hik}",
    # Hikvision ISAPI
    "rtsp://{user}:{pass}@{ip}:{port}/ISAPI/Streaming/channels/{ch}{sub_hik}",
    # Generic ONVIF
    "rtsp://{user}:{pass}@{ip}:{port}/stream{ch}",
]


# ============================================================================
# Device Discovery
# ============================================================================

def discover_devices() -> Dict[str, List[Dict[str, Any]]]:
    """Scan local network for NVRs and doorbell cameras."""
    results: Dict[str, list] = {"nvrs": [], "doorbells": [], "cameras": []}

    subnet = _get_local_subnet()
    if not subnet:
        logger.error("Cannot determine local subnet for discovery")
        return results

    logger.info(f"Starting network discovery on {subnet}...")
    open_hosts = _scan_ports(subnet, [554, 37777, 8000, 80])

    for host_info in open_hosts:
        ip = host_info["ip"]
        ports = host_info["ports"]
        logger.info(f"Found device at {ip} with open ports: {ports}")

        device: Dict[str, Any] = {"ip": ip, "ports": ports}

        if 37777 in ports:
            device["type"] = "doorbell"
            device["brand"] = "Dahua"
            results["doorbells"].append(device)
        elif 554 in ports:
            device["type"] = "nvr_or_camera"
            results["nvrs"].append(device)
        elif 8000 in ports:
            device["type"] = "hikvision"
            device["brand"] = "Hikvision"
            results["nvrs"].append(device)

    logger.info(
        f"Discovery complete: {len(results['doorbells'])} doorbells, "
        f"{len(results['nvrs'])} NVRs/cameras found"
    )
    return results


def _get_local_subnet() -> Optional[str]:
    """Get the local /24 subnet."""
    try:
        result = subprocess.run(
            ["ip", "-4", "route", "show", "default"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return None
        parts = result.stdout.strip().split()
        if "via" in parts:
            gateway = parts[parts.index("via") + 1]
            octets = gateway.split(".")
            if len(octets) == 4:
                return f"{octets[0]}.{octets[1]}.{octets[2]}.0/24"
        return None
    except Exception as e:
        logger.error(f"Failed to get subnet: {e}")
        return None


def _scan_ports(subnet: str, ports: List[int]) -> List[Dict[str, Any]]:
    """Scan a /24 subnet for hosts with specific open ports using socket scan."""
    hosts = []
    base = subnet.replace("/24", "").rsplit(".", 1)[0]

    def check_host(ip: str) -> Optional[Dict[str, Any]]:
        open_ports = []
        for port in ports:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1.0)
                if sock.connect_ex((ip, port)) == 0:
                    open_ports.append(port)
                sock.close()
            except Exception:
                pass
        return {"ip": ip, "ports": open_ports} if open_ports else None

    with concurrent.futures.ThreadPoolExecutor(max_workers=50) as executor:
        futures = {
            executor.submit(check_host, f"{base}.{i}"): i for i in range(1, 255)
        }
        for future in concurrent.futures.as_completed(futures, timeout=30):
            try:
                result = future.result()
                if result:
                    hosts.append(result)
            except Exception:
                pass

    return hosts


def _is_valid_ip(ip: str) -> bool:
    """Check if string looks like an IP address."""
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        return all(0 <= int(p) <= 255 for p in parts)
    except ValueError:
        return False


# ============================================================================
# NVR Channel Scanning
# ============================================================================

def _probe_rtsp(url: str, timeout: int = 8) -> Tuple[bool, str]:
    """Probe an RTSP URL with ffprobe."""
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-rtsp_transport", "tcp",
                "-timeout", "5000000",
                "-show_format",
                url,
            ],
            capture_output=True, text=True, timeout=timeout,
        )
        if result.returncode == 0:
            return True, ""
        return False, result.stderr.strip()[:200] if result.stderr else "Unknown error"
    except subprocess.TimeoutExpired:
        return False, "Timeout"
    except Exception as e:
        return False, str(e)[:100]


def scan_nvr(
    nvr_config: Dict[str, Any],
    on_progress: Optional[Any] = None,
) -> List[Dict[str, Any]]:
    """Scan NVR for active channels, trying multiple RTSP URL formats.

    Args:
        nvr_config: NVR connection details.
        on_progress: Optional callback(stage, detail, current, total) for live updates.
    """
    found_cameras = []
    nvr_ip = nvr_config.get("ip", "")
    nvr_user = nvr_config.get("username", "admin")
    nvr_pass = nvr_config.get("password", "")
    nvr_port = nvr_config.get("rtsp_port", nvr_config.get("port", 554))
    max_channels = nvr_config.get("max_channels", 16)

    def _progress(stage: str, detail: str = "", current: int = 0, total: int = 0):
        if on_progress:
            try:
                on_progress(stage, detail, current, total)
            except Exception:
                pass

    if not nvr_ip:
        logger.warning("NVR IP not configured")
        return []

    # Detect which URL format works by testing channel 1
    working_format = None
    logger.info(f"Scanning NVR at {nvr_ip}:{nvr_port} (user={nvr_user})")
    _progress("format", f"Testing RTSP formats on {nvr_ip}...", 0, len(NVR_URL_FORMATS))

    err = ""
    for idx, fmt in enumerate(NVR_URL_FORMATS):
        test_url = fmt.format(
            user=nvr_user, **{"pass": nvr_pass},
            ip=nvr_ip, port=nvr_port, ch=1, sub=1, sub_hik="02",
        )
        brand = fmt.split("@")[1].split("/")[1] if "@" in fmt else "generic"
        _progress("format", f"Trying {brand}...", idx + 1, len(NVR_URL_FORMATS))
        logger.info(f"Trying format: {fmt.split('@')[1] if '@' in fmt else fmt}")
        success, err = _probe_rtsp(test_url)
        if success:
            working_format = fmt
            logger.info(f"Found working format: {fmt}")
            _progress("format_ok", f"Format found: {brand}")
            break
        logger.debug(f"Format failed: {err}")

    if not working_format:
        logger.error(
            f"No working RTSP format found for NVR at {nvr_ip}. "
            f"Last error: {err}. Check credentials and NVR RTSP settings."
        )
        _progress("error", f"No working RTSP format — check credentials")
        return []

    # Scan channels in parallel (4 workers keeps NVR happy, way faster than sequential)
    _progress("channels", f"Probing {max_channels} channels...", 0, max_channels)
    _probed_lock = threading.Lock()
    probed = 0

    def probe_channel(channel: int) -> Optional[Dict[str, Any]]:
        nonlocal probed
        sub_url = working_format.format(
            user=nvr_user, **{"pass": nvr_pass},
            ip=nvr_ip, port=nvr_port, ch=channel, sub=1, sub_hik="02",
        )
        main_url = working_format.format(
            user=nvr_user, **{"pass": nvr_pass},
            ip=nvr_ip, port=nvr_port, ch=channel, sub=0, sub_hik="01",
        )
        success, ch_err = _probe_rtsp(sub_url)
        with _probed_lock:
            probed += 1
            current = probed
        if success:
            _progress("channel_ok", f"Channel {channel} active", current, max_channels)
            return {
                "channel": channel,
                "name": f"NVR Channel {channel}",
                "id": f"nvr_ch{channel}",
                "url": sub_url,
                "main_url": main_url,
                "type": "nvr",
            }
        else:
            _progress("channels", f"Channel {channel} — {'no stream' if 'Timeout' not in ch_err else 'timeout'}", current, max_channels)
            if "401" in ch_err or "Unauthorized" in ch_err:
                logger.error(f"NVR auth failed on channel {channel}")
            return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = {
            executor.submit(probe_channel, ch): ch
            for ch in range(1, max_channels + 1)
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                result = future.result()
                if result:
                    found_cameras.append(result)
            except Exception:
                pass

    # Sort by channel number
    found_cameras.sort(key=lambda c: c.get("channel", 0))

    _progress("done", f"Found {len(found_cameras)} cameras", max_channels, max_channels)
    return found_cameras


# ============================================================================
# Auto-Scan Helpers
# ============================================================================

def auto_scan_and_add_cameras(config: Dict[str, Any], max_retries: int = 3,
                               retry_delay: int = 15) -> bool:
    """Auto-scan NVR if configured but no NVR cameras exist.

    Returns True if config changed.
    """
    import time

    cameras = config.get("cameras", [])
    nvr_config = config.get("nvr", {})
    has_nvr_cameras = any(c.get("type") == "nvr" for c in cameras)

    if not (nvr_config.get("ip") and not has_nvr_cameras):
        return False

    logger.info("NVR configured but no NVR cameras found — auto-scanning...")

    found = []
    for attempt in range(1, max_retries + 1):
        found = scan_nvr(nvr_config)
        if found:
            break
        if attempt < max_retries:
            logger.info(
                f"NVR scan attempt {attempt} found nothing, "
                f"retrying in {retry_delay}s (NVR may still be booting)..."
            )
            time.sleep(retry_delay)

    if not found:
        logger.warning("NVR auto-scan found no cameras after %d attempts", max_retries)
        return False

    # Dedup: skip NVR channel that duplicates direct doorbell
    found = _dedup_doorbell_channel(config, found)

    logger.info(f"Auto-scan found {len(found)} NVR cameras — adding to config")
    cameras.extend(found)
    config["cameras"] = cameras

    from .config import update_layouts_with_cameras
    update_layouts_with_cameras(config)

    return True


def _dedup_doorbell_channel(config: Dict[str, Any], nvr_cameras: List[Dict]) -> List[Dict]:
    """Remove NVR channel that duplicates the direct doorbell connection."""
    cameras = config.get("cameras", [])
    has_direct = any(
        c.get("type") == "direct" or c.get("id") == "doorbell_direct"
        for c in cameras
    )
    if not has_direct:
        return nvr_cameras

    doorbell_ip = config.get("doorbell", {}).get("ip", "")
    doorbell_channel = config.get("nvr", {}).get("doorbell_channel")
    # Default to channel 1 if doorbell is connected directly but channel isn't set
    if doorbell_channel is None and doorbell_ip:
        doorbell_channel = 1
    if doorbell_channel is not None:
        before = len(nvr_cameras)
        nvr_cameras = [c for c in nvr_cameras if c.get("channel") != doorbell_channel]
        if len(nvr_cameras) < before:
            logger.info(f"Skipped NVR channel {doorbell_channel} (doorbell already connected directly)")

    return nvr_cameras
