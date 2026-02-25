"""
AVA Doorbell v4.0 — Configuration Management

Load/save config.json, generate go2rtc.yaml, and config utilities.
"""

import json
import logging
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, Optional

import yaml

logger = logging.getLogger(__name__)

# Config paths — AVA_CONFIG env var points to the config FILE
_config_env = os.getenv("AVA_CONFIG", "")
if _config_env and Path(_config_env).suffix == ".json":
    CONFIG_FILE = Path(_config_env)
    CONFIG_DIR = CONFIG_FILE.parent
else:
    CONFIG_DIR = Path(_config_env) if _config_env else (Path.home() / "ava-doorbell" / "config")
    CONFIG_FILE = CONFIG_DIR / "config.json"

CONFIG_BACKUP = CONFIG_FILE.with_suffix(".json.bak")
GO2RTC_FILE = CONFIG_DIR / "go2rtc.yaml"


# ============================================================================
# IP Detection
# ============================================================================

def get_current_ip() -> str:
    """Get the Pi's current LAN IP address."""
    try:
        result = subprocess.run(
            ["hostname", "-I"], capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().split()[0]
    except Exception as e:
        logger.warning(f"Failed to detect IP: {e}")
    return "127.0.0.1"


# ============================================================================
# Config Load / Save
# ============================================================================

_config_cache: Optional[Dict[str, Any]] = None


def load_config() -> Dict[str, Any]:
    """Load configuration, using in-memory cache to avoid disk reads on every request."""
    global _config_cache
    if _config_cache is not None:
        return _config_cache

    try:
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE) as f:
                _config_cache = json.load(f)
                return _config_cache

        # Fall back to default config in config dir
        default_file = CONFIG_DIR / "config.default.json"
        if default_file.exists():
            logger.info(f"Config not found, loading defaults from {default_file}")
            with open(default_file) as f:
                config = json.load(f)
            save_config(config)
            return config

        # Check source tree default (first-run before install)
        source_default = Path(__file__).parent.parent.parent / "config" / "config.default.json"
        if source_default.exists():
            logger.info(f"Loading defaults from source: {source_default}")
            with open(source_default) as f:
                config = json.load(f)
            save_config(config)
            return config

        logger.warning(f"No config files found: {CONFIG_FILE}")
        return {}
    except Exception as e:
        logger.error(f"Failed to load config: {e}")
        return {}


def save_config(config: Dict[str, Any]) -> bool:
    """Save configuration to config.json with atomic write + backup."""
    global _config_cache
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)

        # Create backup of existing config
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE) as f:
                with open(CONFIG_BACKUP, "w") as bak:
                    bak.write(f.read())

        # Atomic write: write to temp file, fsync, then rename
        tmp_file = CONFIG_FILE.with_suffix(".json.tmp")
        with open(tmp_file, "w") as f:
            json.dump(config, f, indent=2)
            f.flush()
            os.fsync(f.fileno())

        os.rename(str(tmp_file), str(CONFIG_FILE))
        _config_cache = config  # Update cache atomically with save

        logger.info("Config saved successfully")
        return True
    except Exception as e:
        logger.error(f"Failed to save config: {e}")
        return False


# ============================================================================
# go2rtc Config Generation
# ============================================================================

def generate_go2rtc_config(config: Dict[str, Any]) -> str:
    """Generate go2rtc.yaml from camera config.

    Returns: "written" if new config written, "unchanged" if identical, "empty" if no cameras.
    """
    try:
        cameras = config.get("cameras", [])
        if not cameras:
            logger.warning("No cameras configured for go2rtc")
            return "empty"

        streams = {}
        for cam in cameras:
            cam_id = cam.get("id", "")
            if not cam_id:
                continue

            sub_url = cam.get("url", "")
            main_url = cam.get("main_url", "")

            if not sub_url:
                sub_url = (
                    f"rtsp://{cam.get('username', 'admin')}:{cam.get('password', '')}@"
                    f"{cam.get('ip')}:{cam.get('port', 554)}/{cam.get('path', 'cam/realmonitor')}"
                    f"?channel={cam.get('channel', 1)}&subtype=1"
                )
            if not main_url:
                main_url = sub_url.replace("subtype=1", "subtype=0") if sub_url else ""

            streams[cam_id] = [sub_url]

            if main_url and main_url != sub_url:
                streams[f"{cam_id}_main"] = [main_url]

        server_config = config.get("server", {})
        api_port = server_config.get("go2rtc_port", 1984)
        api_tls_port = server_config.get("go2rtc_tls_port", 1985)

        cert_file = CONFIG_DIR / "ssl" / "ava-admin.crt"
        key_file = CONFIG_DIR / "ssl" / "ava-admin.key"

        go2rtc_config: Dict[str, Any] = {
            "streams": streams,
            "api": {
                "listen": f":{api_port}",
                "origin": "*",  # LAN-only; frontend proxies all go2rtc access via /api/ws-proxy
            },
            "rtsp": {"listen": ":8554"},
            "webrtc": {
                "listen": ":8555",
                # No STUN — LAN-only deployment
            },
        }

        has_tls = cert_file.exists() and key_file.exists()
        if has_tls:
            go2rtc_config["api"]["tls_listen"] = f":{api_tls_port}"
            go2rtc_config["api"]["tls_cert"] = str(cert_file)
            go2rtc_config["api"]["tls_key"] = str(key_file)

        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        new_content = yaml.dump(go2rtc_config, default_flow_style=False)

        # Only write and signal restart if config actually changed
        if GO2RTC_FILE.exists():
            existing = GO2RTC_FILE.read_text()
            if existing == new_content:
                logger.info(f"go2rtc.yaml unchanged ({len(streams)} streams) — skipping restart")
                return "unchanged"

        GO2RTC_FILE.write_text(new_content)
        tls_msg = f" (TLS on port {api_tls_port})" if has_tls else " (no TLS)"
        logger.info(f"go2rtc.yaml generated with {len(streams)} streams{tls_msg}")
        return "written"
    except Exception as e:
        logger.error(f"Failed to generate go2rtc.yaml: {e}")
        return "empty"


# ============================================================================
# Config Utilities
# ============================================================================

def normalize_layouts(layouts: Any) -> Dict[str, list]:
    """Ensure layouts are always dict-of-arrays."""
    if not isinstance(layouts, dict):
        return {}
    normalized = {}
    sizes = {"single": 1, "2up": 2, "4up": 4, "6up": 6, "8up": 8, "9up": 9}
    for key, val in layouts.items():
        size = sizes.get(key, 6)
        if isinstance(val, list):
            normalized[key] = val
        elif isinstance(val, dict):
            normalized[key] = [val.get(str(i), "") for i in range(size)]
        else:
            normalized[key] = ["" for _ in range(size)]
    return normalized


def sanitize_config(config: Dict[str, Any]) -> Dict[str, Any]:
    """Remove sensitive data from config for public API."""
    safe_config = {
        "server": config.get("server", {}),
        "cameras": [],
        "layouts": normalize_layouts(config.get("layouts", {})),
        "preset_layouts": config.get("preset_layouts", []),
        "auto_cycle": config.get("auto_cycle", {}),
        "default_layout": config.get("default_layout", "single"),
        "version": config.get("version", "4.0"),
    }

    for cam in config.get("cameras", []):
        safe_config["cameras"].append({
            "id": cam.get("id"),
            "name": cam.get("name"),
            "type": cam.get("type", "direct"),
            "talk_enabled": cam.get("talk_enabled", False),
            "rotation": cam.get("rotation", 0),
        })

    return safe_config


def update_layouts_with_cameras(config: Dict[str, Any]) -> None:
    """Fill empty layout slots with available cameras."""
    cameras = config.get("cameras", [])
    cam_ids = [c["id"] for c in cameras]
    layouts = config.get("layouts", {})

    for layout_name, size in [("2up", 2), ("4up", 4), ("6up", 6), ("8up", 8), ("9up", 9)]:
        current = layouts.get(layout_name, [""] * size)
        if isinstance(current, dict):
            current = [current.get(str(i), "") for i in range(size)]

        used = set(c for c in current if c)
        available = [c for c in cam_ids if c not in used]
        for i in range(len(current)):
            if not current[i] and available:
                current[i] = available.pop(0)

        layouts[layout_name] = current

    config["layouts"] = layouts
