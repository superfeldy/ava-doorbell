"""
AVA Doorbell v4.0 — Service Management Routes

Systemd service status, restart, logs, and system info.
"""

import logging
import re
import subprocess
import time
from datetime import datetime
from typing import Dict, Tuple

from fastapi import APIRouter, Depends, HTTPException, Query

from .. import config as config_module
from ..dependencies import require_auth

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["services"])

# Track restart times to prevent double-restarts
_service_last_restart: Dict[str, float] = {}

ALL_SERVICES = ["go2rtc", "alarm-scanner", "ava-talk", "ava-admin", "mosquitto", "smbd"]


def _get_service_status(service: str) -> Tuple[bool, str]:
    """Get systemd service status."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service],
            capture_output=True, text=True, timeout=5,
        )
        is_active = result.returncode == 0
        return is_active, "active" if is_active else "inactive"
    except Exception as e:
        logger.error(f"Failed to check {service} status: {e}")
        return False, "error"


def _restart_service(service: str, skip_if_recent: int = 0) -> bool:
    """Restart a systemd service."""
    if skip_if_recent > 0:
        last = _service_last_restart.get(service, 0)
        if time.time() - last < skip_if_recent:
            logger.info(f"Skipping {service} restart — already restarted {int(time.time() - last)}s ago")
            return True

    try:
        result = subprocess.run(
            ["sudo", "systemctl", "restart", service],
            capture_output=True, text=True, timeout=30,
        )
        success = result.returncode == 0
        if success:
            _service_last_restart[service] = time.time()
            logger.info(f"Service {service} restarted")
        else:
            logger.error(f"Failed to restart {service}: {result.stderr}")
        return success
    except Exception as e:
        logger.error(f"Restart {service} failed: {e}")
        return False


@router.get("/services")
async def list_services(user: str = Depends(require_auth)):
    """Get status of all systemd services."""
    statuses = {}
    for service in ALL_SERVICES:
        is_active, status = _get_service_status(service)
        statuses[service] = {"status": status, "active": is_active}
    return statuses


@router.post("/services/{service}/restart")
async def restart_service_endpoint(service: str, user: str = Depends(require_auth)):
    """Restart a specific systemd service."""
    if service not in ALL_SERVICES:
        raise HTTPException(status_code=400, detail=f"Unknown service: {service}")
    if _restart_service(service):
        return {"status": "restarted"}
    raise HTTPException(status_code=500, detail="Restart failed")


@router.post("/restart-all")
async def restart_all_services(user: str = Depends(require_auth)):
    """Restart all AVA services."""
    services = ["go2rtc", "alarm-scanner", "ava-talk", "mosquitto", "smbd"]
    results = {}
    for service in services:
        skip = 30 if service == "go2rtc" else 0
        results[service] = _restart_service(service, skip_if_recent=skip)
    return {"status": "restarted", "results": results}


@router.get("/status")
async def api_status(user: str = Depends(require_auth)):
    """Dashboard status: service states, IP, uptime."""
    services = {
        "go2rtc": _get_service_status("go2rtc")[0],
        "alarm_scanner": _get_service_status("alarm-scanner")[0],
        "ava_talk": _get_service_status("ava-talk")[0],
        "mosquitto": _get_service_status("mosquitto")[0],
        "smbd": _get_service_status("smbd")[0],
    }

    pi_ip = config_module.get_current_ip()

    uptime = "--"
    try:
        result = subprocess.run(
            ["uptime", "-p"], capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            uptime = result.stdout.strip().replace("up ", "")
    except Exception:
        pass

    return {**services, "pi_ip": pi_ip, "uptime": uptime}


@router.get("/logs")
async def api_logs(
    service: str = Query("all"),
    lines: int = Query(100, le=500),
    since: str = Query(""),
    user: str = Depends(require_auth),
):
    """Fetch recent service logs from journald."""
    # Validate inputs before try/except so HTTPException isn't swallowed
    if service != "all" and service not in ALL_SERVICES:
        raise HTTPException(status_code=400, detail=f"Unknown service: {service}")

    if since and not re.match(r'^[\d\-T: .+]+$', since):
        raise HTTPException(status_code=400, detail="Invalid 'since' format")

    try:
        cmd = ["journalctl", "--no-pager", "-n", str(lines), "--output=short-iso"]

        if service == "all":
            for svc in ALL_SERVICES:
                cmd += ["-u", svc]
        else:
            cmd += ["-u", service]

        if since:
            cmd += ["--since", since]

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        log_lines = result.stdout.strip().split("\n") if result.stdout.strip() else []

        return {"lines": log_lines, "count": len(log_lines)}
    except Exception as e:
        logger.error(f"Log fetch failed: {e}")
        return {"error": str(e)}
