"""
AVA Doorbell v4.0 — Settings & Layout Routes

Settings update, password change, layout management.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from starlette.responses import JSONResponse

from .. import auth, config as config_module
from ..dependencies import require_auth
from ..models import PasswordChangeRequest

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["settings"])

# Keys that must never be overwritten via the settings API
_PROTECTED_KEYS = {"admin", "version", "setup_complete"}


@router.get("/config/full")
async def get_full_config(user: str = Depends(require_auth)):
    """Get full config including passwords (admin only)."""
    return config_module.load_config()


@router.post("/config")
async def save_config_endpoint(request: Request, user: str = Depends(require_auth)):
    """Save full configuration and regenerate go2rtc.yaml."""
    config = await request.json()
    if not config:
        raise HTTPException(status_code=400, detail="Invalid config")

    # Preserve existing admin block — never allow client to overwrite auth data
    existing = config_module.load_config()
    if "admin" in existing:
        config["admin"] = existing["admin"]

    if not config_module.save_config(config):
        raise HTTPException(status_code=500, detail="Failed to save config")

    config_module.generate_go2rtc_config(config)
    return {"status": "ok"}


@router.get("/layouts")
async def get_layouts(user: str = Depends(require_auth)):
    """Get layout assignments."""
    config = config_module.load_config()
    return config.get("layouts", {})


@router.post("/layouts")
async def save_layouts(request: Request, user: str = Depends(require_auth)):
    """Update layout assignments."""
    layouts = await request.json()
    config = config_module.load_config()
    config["layouts"] = layouts
    config_module.save_config(config)
    logger.info("Layouts updated")
    return {"status": "ok"}


@router.post("/settings")
async def update_settings(request: Request, user: str = Depends(require_auth)):
    """Update doorbell, NVR, or notification settings."""
    data = await request.json()
    config = config_module.load_config()

    # Map frontend form field names → config.json paths
    FIELD_MAP = {
        "notification_ring_topic": ("notifications", "mqtt_topic_ring"),
        "notification_event_topic": ("notifications", "mqtt_topic_event"),
        "notification_status_topic": ("notifications", "mqtt_topic_status"),
        "notification_ring_cooldown": ("notifications", "ring_cooldown_seconds"),
        "mqtt_broker": ("server", "mqtt_broker"),
        "mqtt_port": ("server", "mqtt_port"),
        "mqtt_topic": ("notifications", "mqtt_topic_ring"),
        "smb_enabled": ("smb", "enabled"),
        "auto_cycle_enabled": ("auto_cycle", "enabled"),
        "auto_cycle_interval": ("auto_cycle", "interval_seconds"),
    }

    for key, value in data.items():
        # Convert numeric strings
        if key.endswith(("_port", "_channels", "_channel", "_cooldown", "_interval")):
            try:
                value = int(value) if value != "" else value
            except (ValueError, TypeError):
                pass

        # Convert boolean strings
        if key.endswith("_enabled") and isinstance(value, str):
            value = value.lower() in ("true", "1", "yes")

        if key in FIELD_MAP:
            section_name, field_name = FIELD_MAP[key]
            config.setdefault(section_name, {})[field_name] = value
        elif key.startswith("doorbell_"):
            config.setdefault("doorbell", {})[key.removeprefix("doorbell_")] = value
        elif key.startswith("nvr_"):
            config.setdefault("nvr", {})[key.removeprefix("nvr_")] = value
        elif key in _PROTECTED_KEYS:
            logger.warning(f"Blocked write to protected key: {key}")
            continue
        else:
            logger.warning(f"Ignored unknown settings key: {key}")
            continue

    if not config_module.save_config(config):
        raise HTTPException(status_code=500, detail="Failed to save config")

    config_module.generate_go2rtc_config(config)
    return {"status": "saved"}


@router.post("/password")
async def change_password(body: PasswordChangeRequest, user: str = Depends(require_auth)):
    """Change admin password (requires current password)."""
    config = config_module.load_config()
    password_hash = config.get("admin", {}).get("password_hash", "")

    if not auth.verify_password(body.old_password, password_hash):
        raise HTTPException(status_code=401, detail="Invalid current password")

    config.setdefault("admin", {})["password_hash"] = auth.hash_password(body.new_password)
    config_module.save_config(config)
    logger.info("Admin password changed")
    return {"status": "ok"}


# Alias for backward-compatible URL
@router.post("/change-password")
async def change_password_alias(body: PasswordChangeRequest, user: str = Depends(require_auth)):
    """Change password (alias)."""
    return await change_password(body, user)


@router.post("/rerun-setup")
async def rerun_setup(request: Request, user: str = Depends(require_auth)):
    """Reset setup_complete flag so the setup wizard can be re-run."""
    data = await request.json()
    password = data.get("password", "")

    # Require current password as confirmation
    config = config_module.load_config()
    password_hash = config.get("admin", {}).get("password_hash", "")
    if not auth.verify_password(password, password_hash):
        raise HTTPException(status_code=401, detail="Invalid password")

    config.setdefault("admin", {})["setup_complete"] = False
    config_module.save_config(config)

    # Enable setup mode on the running app
    from ..main import app
    app.state.setup_mode = True

    logger.info("Setup wizard re-enabled by admin")
    return {"status": "ok", "redirect": "/setup"}


# ============================================================================
# Preset Layouts
# ============================================================================

@router.get("/presets")
async def get_presets(user: str = Depends(require_auth)):
    """Get saved preset layouts."""
    config = config_module.load_config()
    return config.get("preset_layouts", [])


@router.post("/presets")
async def save_presets(request: Request, user: str = Depends(require_auth)):
    """Save preset layouts (replaces all presets)."""
    presets = await request.json()
    if not isinstance(presets, list):
        raise HTTPException(status_code=400, detail="Expected array of presets")

    config = config_module.load_config()
    config["preset_layouts"] = presets
    if not config_module.save_config(config):
        raise HTTPException(status_code=500, detail="Failed to save presets")

    logger.info(f"Saved {len(presets)} preset layouts")
    return {"status": "ok", "count": len(presets)}
