"""
AVA Doorbell v4.0 — Public Routes

Endpoints that don't require authentication: live view, safe config,
health check, WebRTC/frame proxies, WebSocket info.
"""

import logging
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any, Dict
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Query, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from fastapi.templating import Jinja2Templates

from .. import config as config_module

logger = logging.getLogger(__name__)
router = APIRouter()

# Shared httpx client for proxying to go2rtc — reuses TCP connections
# instead of creating/destroying a connection pool per request.
# Critical for /api/frame.jpeg which may be polled at 4 fps.
_go2rtc_client = httpx.AsyncClient(
    timeout=10,
    limits=httpx.Limits(max_connections=8, max_keepalive_connections=4),
)

templates = Jinja2Templates(directory="admin/templates")


# ============================================================================
# Pages
# ============================================================================

@router.get("/view", response_class=HTMLResponse)
async def multiview(
    request: Request, layout: str = "grid", camera: str = "", mode: str = ""
):
    """Multiview/live-view page (public)."""
    config = config_module.load_config()
    return templates.TemplateResponse(
        "multiview.html",
        {
            "request": request,
            "layout": layout,
            "camera": camera,
            "cameras": config.get("cameras", []),
            "mode": mode,
        },
    )


# ============================================================================
# API
# ============================================================================

@router.get("/app/download")
async def download_apk():
    """Serve the Android APK for sideloading onto tablets."""
    apk_path = config_module.CONFIG_DIR.parent / "apk" / "ava-doorbell.apk"
    if not apk_path.exists():
        return JSONResponse({"error": "APK not found on server"}, status_code=404)
    return FileResponse(
        path=str(apk_path),
        filename="ava-doorbell.apk",
        media_type="application/vnd.android.package-archive",
    )


@router.get("/api/config")
async def get_safe_config():
    """Get sanitized config (no passwords)."""
    config = config_module.load_config()
    return config_module.sanitize_config(config)


@router.get("/api/health")
async def health_check():
    """Health check — returns status of all services."""
    services = ["go2rtc", "alarm-scanner", "ava-talk", "ava-admin", "mosquitto"]
    statuses = {}

    for service in services:
        try:
            result = subprocess.run(
                ["systemctl", "is-active", service],
                capture_output=True, text=True, timeout=5,
            )
            statuses[service] = "active" if result.returncode == 0 else "inactive"
        except Exception:
            statuses[service] = "error"

    return {"timestamp": datetime.now().isoformat(), "services": statuses}


@router.get("/api/ws-info")
async def ws_info():
    """Return go2rtc WebSocket URL info for frontend MSE/WebRTC connections."""
    config = config_module.load_config()
    server = config.get("server", {})
    go2rtc_port = server.get("go2rtc_port", 1984)
    go2rtc_tls_port = server.get("go2rtc_tls_port", 1985)
    pi_ip = config_module.get_current_ip()

    cert_file = config_module.CONFIG_DIR / "ssl" / "ava-admin.crt"
    tls_available = cert_file.exists()

    return {
        "ws_base": f"ws://{pi_ip}:{go2rtc_port}",
        "wss_base": f"wss://{pi_ip}:{go2rtc_tls_port}" if tls_available else None,
        "http_base": f"http://{pi_ip}:{go2rtc_port}",
        "https_base": f"https://{pi_ip}:{go2rtc_tls_port}" if tls_available else None,
        "tls_available": tls_available,
    }


# ============================================================================
# Proxies (same-origin for go2rtc)
# ============================================================================

@router.post("/api/webrtc")
async def proxy_webrtc(request: Request, src: str = Query(...)):
    """Proxy WebRTC SDP exchange to go2rtc (avoids CORS)."""
    body = await request.body()
    if not body:
        return JSONResponse({"error": "Missing SDP offer"}, status_code=400)

    config = config_module.load_config()
    server = config.get("server", {})
    go2rtc_port = server.get("go2rtc_port", 1984)

    try:
        resp = await _go2rtc_client.post(
            f"http://localhost:{go2rtc_port}/api/webrtc?src={quote(src)}",
            content=body,
            headers={"Content-Type": "application/sdp"},
        )
        if not resp.content:
            return JSONResponse({"error": "No answer from go2rtc"}, status_code=502)
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            media_type="application/sdp",
        )
    except httpx.ConnectError:
        logger.error("WebRTC proxy: cannot reach go2rtc")
        return JSONResponse(
            {"error": "Cannot reach go2rtc - is it running?"}, status_code=502
        )
    except Exception as e:
        logger.error(f"WebRTC proxy error: {e}")
        return JSONResponse({"error": str(e)}, status_code=502)


def _get_go2rtc_port() -> int:
    """Get go2rtc port from config (always reads fresh — config may change)."""
    config = config_module.load_config()
    return config.get("server", {}).get("go2rtc_port", 1984)


@router.get("/api/frame.jpeg")
async def proxy_frame(src: str = Query(...)):
    """Proxy a single JPEG frame from go2rtc for snapshot/fallback display."""
    go2rtc_port = _get_go2rtc_port()

    try:
        resp = await _go2rtc_client.get(
            f"http://localhost:{go2rtc_port}/api/frame.jpeg?src={quote(src)}",
        )
        if not resp.content:
            return Response(status_code=204)
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            media_type="image/jpeg",
        )
    except Exception as e:
        err_str = str(e)
        if "Connection refused" in err_str or "closed" in err_str:
            logger.debug(f"Frame proxy: go2rtc unavailable ({e})")
        else:
            logger.warning(f"Frame proxy error: {e}")
        return JSONResponse({"error": str(e)}, status_code=502)
