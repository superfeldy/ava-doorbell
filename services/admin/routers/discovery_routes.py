"""
AVA Doorbell v4.0 — Discovery Routes

Network scanning and NVR channel discovery endpoints.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request

from .. import config as config_module
from ..config import update_layouts_with_cameras
from ..dependencies import require_auth
from ..discovery import (
    _dedup_doorbell_channel,
    discover_devices,
    scan_nvr,
)
from ..routers.services import _restart_service

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["discovery"])


@router.post("/scan-nvr")
async def scan_nvr_endpoint(user: str = Depends(require_auth)):
    """Scan NVR for active channels using saved config."""
    config = config_module.load_config()
    nvr_config = config.get("nvr", {})

    if not nvr_config.get("ip"):
        raise HTTPException(status_code=400, detail="NVR IP not configured. Set it in Settings first.")

    cameras = scan_nvr(nvr_config)
    return {"cameras": cameras}


@router.post("/discover")
async def discover_endpoint(user: str = Depends(require_auth)):
    """Discover NVRs and doorbells on the local network."""
    devices = discover_devices()
    return devices


@router.post("/discover-and-add")
async def discover_and_add_endpoint(request: Request, user: str = Depends(require_auth)):
    """Discover devices, scan NVR channels, and add cameras automatically."""
    data = await request.json() if request.headers.get("content-type", "").startswith("application/json") else {}
    config = config_module.load_config()

    devices = discover_devices()
    added_cameras = []

    # Process discovered NVRs
    for nvr_device in devices.get("nvrs", []):
        nvr_ip = nvr_device["ip"]
        config.setdefault("nvr", {})["ip"] = nvr_ip

        nvr_user = data.get("nvr_username", config.get("nvr", {}).get("username", "admin"))
        nvr_pass = data.get("nvr_password", config.get("nvr", {}).get("password", ""))
        config["nvr"]["username"] = nvr_user
        config["nvr"]["password"] = nvr_pass
        config["nvr"]["rtsp_port"] = 554

        nvr_cams = scan_nvr(config["nvr"])
        if nvr_cams:
            nvr_cams = _dedup_doorbell_channel(config, nvr_cams)
            cameras = [c for c in config.get("cameras", []) if c.get("type") != "nvr"]
            cameras.extend(nvr_cams)
            config["cameras"] = cameras
            added_cameras.extend(nvr_cams)

    # Process discovered doorbells
    for db_device in devices.get("doorbells", []):
        db_ip = db_device["ip"]
        db_user = data.get("doorbell_username", config.get("doorbell", {}).get("username", "admin"))
        db_pass = data.get("doorbell_password", config.get("doorbell", {}).get("password", ""))

        config.setdefault("doorbell", {})["ip"] = db_ip
        config["doorbell"]["username"] = db_user
        config["doorbell"]["password"] = db_pass

        cameras = config.get("cameras", [])
        found_existing = False
        for cam in cameras:
            if cam.get("type") == "direct" or cam.get("id") == "doorbell_direct":
                cam["url"] = f"rtsp://{db_user}:{db_pass}@{db_ip}:554/cam/realmonitor?channel=1&subtype=1"
                cam["main_url"] = f"rtsp://{db_user}:{db_pass}@{db_ip}:554/cam/realmonitor?channel=1&subtype=0"
                found_existing = True
                break

        if not found_existing:
            cameras.append({
                "id": "doorbell_direct",
                "name": "Doorbell",
                "url": f"rtsp://{db_user}:{db_pass}@{db_ip}:554/cam/realmonitor?channel=1&subtype=1",
                "main_url": f"rtsp://{db_user}:{db_pass}@{db_ip}:554/cam/realmonitor?channel=1&subtype=0",
                "type": "direct",
                "talk_enabled": True,
            })
            added_cameras.append({"id": "doorbell_direct", "ip": db_ip})

        config["cameras"] = cameras

    if added_cameras:
        update_layouts_with_cameras(config)
        config_module.save_config(config)
        config_module.generate_go2rtc_config(config)
        _restart_service("go2rtc")

    return {
        "discovered": devices,
        "added_cameras": added_cameras,
        "total_cameras": len(config.get("cameras", [])),
    }
