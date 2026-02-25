"""
AVA Doorbell v4.0 — Camera Management Routes

CRUD operations for camera configurations and stream testing.
"""

import logging
import subprocess
from typing import Any, Dict, Tuple

from fastapi import APIRouter, Depends, HTTPException

from .. import config as config_module
from ..dependencies import require_auth
from ..models import CameraCreate, CameraUpdate

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/cameras", tags=["cameras"])


def _test_stream(camera_config: Dict[str, Any]) -> Tuple[bool, str]:
    """Test if a camera RTSP stream is reachable via ffprobe."""
    url = camera_config.get("url", "")
    if not url:
        url = (
            f"rtsp://{camera_config.get('username', 'admin')}:{camera_config.get('password', '')}@"
            f"{camera_config.get('ip')}:{camera_config.get('port', 554)}/"
            f"{camera_config.get('path', 'cam/realmonitor')}"
            f"?channel={camera_config.get('channel', 1)}&subtype=1"
        )

    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-rtsp_transport", "tcp",
                "-timeout", "8000000",
                "-show_format", "-show_streams",
                url,
            ],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            return True, "Stream accessible"
        stderr = result.stderr.strip()[:150] if result.stderr else "Unknown error"
        return False, stderr
    except subprocess.TimeoutExpired:
        return False, "Timeout (10s) - camera may be unreachable"
    except Exception as e:
        return False, str(e)[:100]


@router.get("")
async def list_cameras(user: str = Depends(require_auth)):
    """List all cameras."""
    config = config_module.load_config()
    return config.get("cameras", [])


@router.post("", status_code=201)
async def add_camera(body: CameraCreate, user: str = Depends(require_auth)):
    """Add a new camera."""
    config = config_module.load_config()

    # Auto-generate ID from name
    name_slug = body.name.lower().replace(" ", "_")
    cam_count = len(config.get("cameras", []))
    camera_id = f"cam_{name_slug}_{cam_count}"

    cam_data = body.model_dump()
    cam_data["id"] = camera_id

    config.setdefault("cameras", []).append(cam_data)
    config_module.save_config(config)
    config_module.generate_go2rtc_config(config)

    logger.info(f"Camera added: {camera_id}")
    return cam_data


@router.put("/{cam_id}")
async def update_camera(
    cam_id: str,
    body: CameraUpdate,
    user: str = Depends(require_auth),
):
    """Update camera configuration."""
    config = config_module.load_config()
    cameras = config.get("cameras", [])

    for camera in cameras:
        if camera.get("id") == cam_id:
            updates = body.model_dump(exclude_unset=True)
            camera.update(updates)
            config_module.save_config(config)
            config_module.generate_go2rtc_config(config)
            logger.info(f"Camera updated: {cam_id}")
            return camera

    raise HTTPException(status_code=404, detail="Camera not found")


@router.delete("/{cam_id}")
async def delete_camera(cam_id: str, user: str = Depends(require_auth)):
    """Delete a camera."""
    config = config_module.load_config()
    cameras = config.get("cameras", [])
    config["cameras"] = [c for c in cameras if c.get("id") != cam_id]

    config_module.save_config(config)
    config_module.generate_go2rtc_config(config)
    logger.info(f"Camera deleted: {cam_id}")
    return {"status": "deleted"}


@router.post("/{cam_id}/test")
async def test_stream(cam_id: str, user: str = Depends(require_auth)):
    """Test if camera stream is reachable."""
    config = config_module.load_config()
    cameras = config.get("cameras", [])

    for camera in cameras:
        if camera.get("id") == cam_id:
            is_reachable, message = _test_stream(camera)
            return {"reachable": is_reachable, "message": message}

    raise HTTPException(status_code=404, detail="Camera not found")
