"""
AVA Doorbell v4.0 — SMB (Samba) Management Routes
"""

import getpass
import logging
import os
import subprocess

from fastapi import APIRouter, Depends, HTTPException, Request

from .. import config as config_module
from ..dependencies import require_auth
from ..routers.services import _get_service_status, _restart_service
from ..smb_manager import regenerate_smb_conf

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/smb", tags=["smb"])


@router.get("/status")
async def smb_status(user: str = Depends(require_auth)):
    """Get SMB service status and share info."""
    is_active, status = _get_service_status("smbd")
    config = config_module.load_config()
    smb_config = config.get("smb", {})
    install_dir = os.path.expanduser("~/ava-doorbell")

    share_defs = {
        "config": {"name": "ava-config", "path": f"{install_dir}/config", "desc": "Configuration files"},
        "services": {"name": "ava-services", "path": f"{install_dir}/services", "desc": "Service scripts"},
        "recordings": {"name": "ava-recordings", "path": f"{install_dir}/recordings", "desc": "Recordings"},
    }

    shares = []
    enabled_shares = smb_config.get("shares", {})
    for key, info in share_defs.items():
        if enabled_shares.get(key, True):
            shares.append({
                "id": key,
                "name": info["name"],
                "path": info["path"],
                "description": info["desc"],
                "exists": os.path.isdir(info["path"]),
                "enabled": True,
            })

    hostname = "unknown"
    try:
        result = subprocess.run(["hostname"], capture_output=True, text=True, timeout=3)
        if result.returncode == 0:
            hostname = result.stdout.strip()
    except Exception:
        pass

    return {
        "active": is_active,
        "status": status,
        "enabled": smb_config.get("enabled", False),
        "workgroup": smb_config.get("workgroup", "WORKGROUP"),
        "hostname": hostname,
        "shares": shares,
    }


@router.post("/config")
async def smb_update_config(request: Request, user: str = Depends(require_auth)):
    """Update SMB configuration."""
    data = await request.json()
    config = config_module.load_config()
    smb = config.setdefault("smb", {})

    if "enabled" in data:
        smb["enabled"] = bool(data["enabled"])
    if "workgroup" in data:
        smb["workgroup"] = str(data["workgroup"]).strip() or "WORKGROUP"
    if "shares" in data:
        smb.setdefault("shares", {})
        for key in ("config", "services", "recordings"):
            if key in data["shares"]:
                smb["shares"][key] = bool(data["shares"][key])

    if not config_module.save_config(config):
        raise HTTPException(status_code=500, detail="Failed to save config")

    regenerate_smb_conf(config)

    if smb.get("enabled", False):
        _restart_service("smbd")
        logger.info("SMB enabled and restarted")
    else:
        subprocess.run(["sudo", "systemctl", "stop", "smbd"], capture_output=True, timeout=10)
        logger.info("SMB disabled and stopped")

    return {"status": "ok"}


@router.post("/password")
async def smb_change_password(request: Request, user: str = Depends(require_auth)):
    """Change Samba user password."""
    data = await request.json()
    password = data.get("password", "")
    if not password or len(password) < 4:
        raise HTTPException(status_code=400, detail="Password must be at least 4 characters")

    username = getpass.getuser()
    result = subprocess.run(
        ["sudo", "smbpasswd", "-s", "-a", username],
        input=f"{password}\n{password}\n",
        capture_output=True, text=True, timeout=10,
    )

    if result.returncode == 0:
        logger.info(f"SMB password changed for user {username}")
        return {"status": "ok"}
    else:
        logger.error(f"SMB password change failed: {result.stderr}")
        raise HTTPException(status_code=500, detail="Failed to set password")
