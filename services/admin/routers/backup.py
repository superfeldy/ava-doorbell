"""
AVA Doorbell v4.0 — Backup & Restore Routes
"""

import logging
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile, File

from .. import config as config_module
from ..dependencies import require_auth

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["backup"])


@router.get("/backup")
async def backup_config(user: str = Depends(require_auth)):
    """Download config backup."""
    config = config_module.load_config()
    return {"timestamp": datetime.now().isoformat(), "config": config}


@router.post("/backup")
async def backup_config_post(user: str = Depends(require_auth)):
    """Download config backup (POST variant)."""
    config = config_module.load_config()
    return {"timestamp": datetime.now().isoformat(), "config": config}


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
        config_data = json.loads(content)
        config = config_data.get("config", config_data)
    else:
        data = await request.json()
        config = data.get("config", {})

    if not config:
        raise HTTPException(status_code=400, detail="No config provided")

    # Preserve current admin block (password_hash, token, setup_complete)
    existing = config_module.load_config()
    if "admin" in existing:
        config["admin"] = existing["admin"]

    if not config_module.save_config(config):
        raise HTTPException(status_code=500, detail="Failed to save config")

    config_module.generate_go2rtc_config(config)
    logger.info("Config restored from backup")
    return {"status": "restored"}
