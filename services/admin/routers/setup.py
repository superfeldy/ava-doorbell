"""
AVA Doorbell v4.0 — Setup Wizard Routes

First-run setup wizard: set password, configure network, discover cameras.
"""

import asyncio
import json
import logging
import re
import subprocess
import threading

import httpx
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from pathlib import Path
from starlette.responses import StreamingResponse

from .. import auth, config as config_module
from ..config import generate_go2rtc_config, update_layouts_with_cameras
from ..discovery import discover_devices, scan_nvr, _dedup_doorbell_channel
from ..ssl_manager import ensure_ssl_cert

logger = logging.getLogger(__name__)
router = APIRouter(tags=["setup"])

templates = Jinja2Templates(directory=str(Path(__file__).parent.parent / "templates"))


def _require_setup_mode():
    """Raise 403 if setup is already complete. Guards setup-only endpoints."""
    config = config_module.load_config()
    if config.get("admin", {}).get("setup_complete", False):
        raise HTTPException(status_code=403, detail="Setup already completed")


@router.get("/setup", response_class=HTMLResponse)
async def setup_page(request: Request):
    """Render setup wizard page."""
    return templates.TemplateResponse("setup.html", {"request": request})


@router.get("/api/setup/status")
async def setup_status():
    """Get setup wizard progress.

    Only exposes setup_complete to unauthenticated callers.
    Full status (has_password, has_cameras, pi_ip, server) is only
    returned when setup is not yet complete (wizard needs it).
    """
    config = config_module.load_config()
    admin = config.get("admin", {})
    setup_complete = admin.get("setup_complete", False)

    if setup_complete:
        return {"setup_complete": True}

    return {
        "setup_complete": False,
        "has_password": bool(admin.get("password_hash", "")),
        "has_cameras": len(config.get("cameras", [])) > 0,
        "pi_ip": config_module.get_current_ip(),
        "server": config.get("server", {}),
    }


_IP_PATTERN = re.compile(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$")


@router.post("/api/setup/test-device")
async def test_device(request: Request):
    """Ping a device and optionally test Dahua HTTP API credentials."""
    _require_setup_mode()
    data = await request.json()
    ip = data.get("ip", "").strip()
    username = data.get("username", "")
    password = data.get("password", "")

    if not ip or not _IP_PATTERN.match(ip):
        raise HTTPException(status_code=400, detail="Invalid IP address format")

    result = {"reachable": False, "auth_ok": None, "device_type": None}

    # Ping check (non-blocking)
    try:
        proc = await asyncio.create_subprocess_exec(
            "ping", "-c", "1", "-W", "2", ip,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        retcode = await asyncio.wait_for(proc.wait(), timeout=5)
        result["reachable"] = retcode == 0
    except (asyncio.TimeoutError, OSError):
        result["reachable"] = False

    # Credential test via Dahua HTTP API
    if result["reachable"] and username and password:
        try:
            async with httpx.AsyncClient(timeout=5) as client:
                resp = await client.get(
                    f"http://{ip}/cgi-bin/magicBox.cgi?action=getDeviceType",
                    auth=(username, password),
                )
                if resp.status_code == 200:
                    result["auth_ok"] = True
                    # Parse device type from response (format: type=VTO2000A)
                    for line in resp.text.splitlines():
                        if "type=" in line:
                            result["device_type"] = line.split("=", 1)[1].strip()
                            break
                elif resp.status_code == 401:
                    result["auth_ok"] = False
                else:
                    result["auth_ok"] = None
        except Exception:
            result["auth_ok"] = None

    return result


@router.post("/api/setup/password")
async def setup_password(request: Request):
    """Set initial admin password (setup step)."""
    data = await request.json()
    password = data.get("password", "")

    if not password or len(password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters")

    config = config_module.load_config()

    # Only allow if setup is not yet complete
    if config.get("admin", {}).get("setup_complete", False):
        raise HTTPException(status_code=400, detail="Setup already completed")

    config.setdefault("admin", {})["password_hash"] = auth.hash_password(password)
    config_module.save_config(config)

    logger.info("Setup: admin password set")
    return {"status": "ok"}


@router.post("/api/setup/network")
async def setup_network(request: Request):
    """Configure network and generate SSL cert (setup step)."""
    _require_setup_mode()
    data = await request.json()
    config = config_module.load_config()

    # Update server config if provided
    server = config.setdefault("server", {})
    if "admin_port" in data:
        server["admin_port"] = int(data["admin_port"])

    config_module.save_config(config)

    # Generate SSL cert with current IP
    current_ip = config_module.get_current_ip()
    cert_path, key_path = ensure_ssl_cert(config_module.CONFIG_DIR, current_ip)

    logger.info(f"Setup: network configured, IP={current_ip}, SSL={'yes' if cert_path else 'no'}")
    return {
        "status": "ok",
        "pi_ip": current_ip,
        "ssl_ready": cert_path is not None,
    }


@router.post("/api/setup/cameras")
async def setup_cameras(request: Request):
    """Discover and configure cameras (setup step)."""
    _require_setup_mode()
    data = await request.json()
    config = config_module.load_config()

    # Store credentials
    if data.get("doorbell_ip"):
        db = config.setdefault("doorbell", {})
        db["ip"] = data["doorbell_ip"]
        db["username"] = data.get("doorbell_username", "admin")
        db["password"] = data.get("doorbell_password", "")

        # Add doorbell camera
        cameras = config.get("cameras", [])
        db_user = db["username"]
        db_pass = db["password"]
        db_ip = db["ip"]

        # Remove existing doorbell
        cameras = [c for c in cameras if c.get("id") != "doorbell_direct"]
        cameras.insert(0, {
            "id": "doorbell_direct",
            "name": "Doorbell",
            "url": f"rtsp://{db_user}:{db_pass}@{db_ip}:554/cam/realmonitor?channel=1&subtype=1",
            "main_url": f"rtsp://{db_user}:{db_pass}@{db_ip}:554/cam/realmonitor?channel=1&subtype=0",
            "type": "direct",
            "talk_enabled": True,
        })
        config["cameras"] = cameras

    if data.get("nvr_ip"):
        nvr = config.setdefault("nvr", {})
        nvr["ip"] = data["nvr_ip"]
        nvr["username"] = data.get("nvr_username", "admin")
        nvr["password"] = data.get("nvr_password", "")
        nvr["rtsp_port"] = int(data.get("nvr_rtsp_port", 554))

        # Scan NVR channels
        nvr_cams = scan_nvr(nvr)
        if nvr_cams:
            nvr_cams = _dedup_doorbell_channel(config, nvr_cams)
            cameras = [c for c in config.get("cameras", []) if c.get("type") != "nvr"]
            cameras.extend(nvr_cams)
            config["cameras"] = cameras

    update_layouts_with_cameras(config)
    config_module.save_config(config)
    generate_go2rtc_config(config)

    logger.info(f"Setup: {len(config.get('cameras', []))} cameras configured")
    return {
        "status": "ok",
        "cameras": config.get("cameras", []),
    }


@router.post("/api/setup/cameras/scan")
async def setup_cameras_scan(request: Request):
    """SSE streaming version of camera scan with live progress updates."""
    _require_setup_mode()
    data = await request.json()
    config = config_module.load_config()

    # Queue for thread-safe progress reporting
    progress_queue: asyncio.Queue = asyncio.Queue()
    loop = asyncio.get_event_loop()

    def on_progress(stage: str, detail: str, current: int, total: int):
        """Thread-safe progress callback — pushes events into asyncio queue."""
        asyncio.run_coroutine_threadsafe(
            progress_queue.put({"stage": stage, "detail": detail, "current": current, "total": total}),
            loop,
        )

    async def event_stream():
        # Run the scan in a thread to avoid blocking the event loop
        def do_scan():
            nonlocal config

            # Doorbell (instant — no scan needed)
            if data.get("doorbell_ip"):
                db = config.setdefault("doorbell", {})
                db["ip"] = data["doorbell_ip"]
                db["username"] = data.get("doorbell_username", "admin")
                db["password"] = data.get("doorbell_password", "")

                cameras = config.get("cameras", [])
                db_user, db_pass, db_ip = db["username"], db["password"], db["ip"]
                cameras = [c for c in cameras if c.get("id") != "doorbell_direct"]
                cameras.insert(0, {
                    "id": "doorbell_direct",
                    "name": "Doorbell",
                    "url": f"rtsp://{db_user}:{db_pass}@{db_ip}:554/cam/realmonitor?channel=1&subtype=1",
                    "main_url": f"rtsp://{db_user}:{db_pass}@{db_ip}:554/cam/realmonitor?channel=1&subtype=0",
                    "type": "direct",
                    "talk_enabled": True,
                })
                config["cameras"] = cameras
                on_progress("doorbell", "Doorbell added", 1, 1)

            # NVR scan (slow — reports progress)
            if data.get("nvr_ip"):
                nvr = config.setdefault("nvr", {})
                nvr["ip"] = data["nvr_ip"]
                nvr["username"] = data.get("nvr_username", "admin")
                nvr["password"] = data.get("nvr_password", "")
                nvr["rtsp_port"] = int(data.get("nvr_rtsp_port", 554))

                nvr_cams = scan_nvr(nvr, on_progress=on_progress)
                if nvr_cams:
                    nvr_cams = _dedup_doorbell_channel(config, nvr_cams)
                    cameras = [c for c in config.get("cameras", []) if c.get("type") != "nvr"]
                    cameras.extend(nvr_cams)
                    config["cameras"] = cameras

            update_layouts_with_cameras(config)
            config_module.save_config(config)
            generate_go2rtc_config(config)

            # Signal completion
            on_progress("complete", "", 0, 0)

        # Start scan in background thread
        scan_thread = threading.Thread(target=do_scan, daemon=True)
        scan_thread.start()

        # Stream SSE events until scan completes
        while True:
            try:
                event = await asyncio.wait_for(progress_queue.get(), timeout=60)
            except asyncio.TimeoutError:
                yield f"data: {json.dumps({'stage': 'timeout', 'detail': 'Scan timed out'})}\n\n"
                break

            if event["stage"] == "complete":
                # Send final result with camera list
                cameras = config.get("cameras", [])
                # Sanitize — strip passwords from response
                safe_cameras = [
                    {k: v for k, v in c.items() if k not in ("url", "main_url")}
                    for c in cameras
                ]
                yield f"data: {json.dumps({'stage': 'complete', 'cameras': safe_cameras})}\n\n"
                break
            else:
                yield f"data: {json.dumps(event)}\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@router.post("/api/setup/complete")
async def setup_complete(request: Request):
    """Mark setup as complete."""
    config = config_module.load_config()

    # Verify password is set
    if not config.get("admin", {}).get("password_hash"):
        raise HTTPException(status_code=400, detail="Password must be set before completing setup")

    config.setdefault("admin", {})["setup_complete"] = True
    config_module.save_config(config)

    # Exit setup mode on the running app
    from ..main import app
    app.state.setup_mode = False

    # Restart go2rtc so it picks up the newly generated go2rtc.yaml
    try:
        result = subprocess.run(
            ["sudo", "systemctl", "restart", "go2rtc"],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode == 0:
            logger.info("Setup: go2rtc restarted with new camera config")
        else:
            logger.warning(f"Setup: go2rtc restart failed: {result.stderr}")
    except Exception as e:
        logger.warning(f"Setup: go2rtc restart error: {e}")

    logger.info("Setup wizard completed")
    return {"status": "ok", "redirect": "/login"}
