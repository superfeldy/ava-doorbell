"""
AVA Doorbell v4.0 — Backup & Restore Routes
"""

import copy
import logging
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile, File

from .. import config as config_module
from ..dependencies import require_auth

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["backup"])

# Top-level keys allowed in a config backup
_ALLOWED_TOP_KEYS = {
    "admin", "server", "cameras", "doorbell", "nvr", "layouts",
    "preset_layouts", "auto_cycle", "notifications", "smb",
    "default_layout", "version",
}


def _strip_passwords(config: dict) -> dict:
    """Return a deep copy of config with password fields removed."""
    safe = copy.deepcopy(config)
    # Remove admin secrets
    admin = safe.get("admin", {})
    admin.pop("password_hash", None)
    admin.pop("api_token_hash", None)
    admin.pop("session_secret", None)
    # Remove doorbell/NVR passwords
    for section in ("doorbell", "nvr"):
        if section in safe and isinstance(safe[section], dict):
            safe[section].pop("password", None)
    # Remove per-camera passwords
    for cam in safe.get("cameras", []):
        if isinstance(cam, dict):
            cam.pop("password", None)
    return safe


def _validate_restore_config(config: dict) -> None:
    """Validate restored config structure. Raises HTTPException on invalid data."""
    # Reject unknown top-level keys
    unknown = set(config.keys()) - _ALLOWED_TOP_KEYS
    if unknown:
        raise HTTPException(status_code=400, detail=f"Unknown config keys: {', '.join(sorted(unknown))}")
    # cameras must be a list
    if "cameras" in config and not isinstance(config["cameras"], list):
        raise HTTPException(status_code=400, detail="'cameras' must be a list")
    # server ports must be ints
    server = config.get("server", {})
    if isinstance(server, dict):
        for key in ("admin_port", "go2rtc_port", "talk_port", "mqtt_port"):
            if key in server and not isinstance(server[key], int):
                raise HTTPException(status_code=400, detail=f"server.{key} must be an integer")
    elif "server" in config:
        raise HTTPException(status_code=400, detail="'server' must be a dict")
    # layouts must be a dict
    if "layouts" in config and not isinstance(config["layouts"], dict):
        raise HTTPException(status_code=400, detail="'layouts' must be a dict")


@router.get("/backup")
async def backup_config(user: str = Depends(require_auth)):
    """Download config backup (passwords stripped)."""
    config = config_module.load_config()
    return {"timestamp": datetime.now().isoformat(), "config": _strip_passwords(config)}


@router.post("/backup")
async def backup_config_post(user: str = Depends(require_auth)):
    """Download config backup (POST variant, passwords stripped)."""
    config = config_module.load_config()
    return {"timestamp": datetime.now().isoformat(), "config": _strip_passwords(config)}


@router.post("/restore")
async def restore_config(request: Request, user: str = Depends(require_auth)):
    """Restore config from JSON upload."""
    import json

    content_type = request.headers.get("content-type", "")

    if "multipart" in content_type:
        form = await request.form()
        file = form.get("file")
        if not file:
            raise HTTPException(status_code=400, detail="No file provided")
        content = await file.read()
        try:
            config_data = json.loads(content)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise HTTPException(status_code=400, detail="Invalid JSON file")
        config = config_data.get("config", config_data)
    else:
        try:
            data = await request.json()
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid JSON body")
        config = data.get("config", {})

    if not config:
        raise HTTPException(status_code=400, detail="No config provided")

    _validate_restore_config(config)

    # Preserve current admin block (password_hash, token, setup_complete)
    existing = config_module.load_config()
    if "admin" in existing:
        config["admin"] = existing["admin"]

    if not config_module.save_config(config):
        raise HTTPException(status_code=500, detail="Failed to save config")

    config_module.generate_go2rtc_config(config)
    logger.info("Config restored from backup")
    return {"status": "restored"}
