"""
AVA Doorbell v4.0 — Authentication Routes

Login, logout, and API token management.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from .. import auth, config as config_module
from ..dependencies import require_auth
from ..models import TokenRequest, TokenResponse

logger = logging.getLogger(__name__)
router = APIRouter()

templates = Jinja2Templates(directory="admin/templates")


@router.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    """Render login page."""
    return templates.TemplateResponse("login.html", {"request": request})


@router.post("/login")
async def login(request: Request):
    """Authenticate via form POST."""
    form = await request.form()
    password = form.get("password", "")
    ip = request.client.host if request.client else "unknown"

    # Rate limiting
    if not auth.check_rate_limit(ip):
        logger.warning(f"Rate limit exceeded for IP {ip}")
        return templates.TemplateResponse(
            "login.html",
            {"request": request, "error": "Too many attempts. Try again later."},
            status_code=429,
        )

    config = config_module.load_config()
    password_hash = config.get("admin", {}).get("password_hash", "")

    if not password_hash:
        # No password set — should only happen if setup wizard wasn't completed
        # but someone navigated to /login directly
        return templates.TemplateResponse(
            "login.html",
            {"request": request, "error": "No password configured. Complete setup first."},
            status_code=400,
        )

    if auth.verify_password(password, password_hash):
        timeout = config.get("admin", {}).get("session_timeout_minutes", 60) * 60
        request.session["user_id"] = "admin"
        request.session["last_activity"] = __import__("time").time()
        request.session["_timeout"] = timeout
        logger.info(f"Login successful from {ip}")
        return RedirectResponse("/", status_code=303)

    # Only count failed attempts toward the rate limit
    auth.record_failed_attempt(ip)

    return templates.TemplateResponse(
        "login.html",
        {"request": request, "error": "Invalid password"},
        status_code=401,
    )


@router.get("/logout")
async def logout(request: Request):
    """Logout and clear session."""
    request.session.clear()
    logger.info("User logged out")
    return RedirectResponse("/view", status_code=303)


@router.post("/api/token", response_model=TokenResponse)
async def create_api_token(
    body: TokenRequest,
    user: str = Depends(require_auth),
):
    """Generate a new API token (requires current password)."""
    config = config_module.load_config()
    password_hash = config.get("admin", {}).get("password_hash", "")

    if not password_hash or not auth.verify_password(body.password, password_hash):
        raise HTTPException(status_code=401, detail="Invalid password")

    token = auth.generate_api_token()
    config.setdefault("admin", {})["api_token_hash"] = auth.hash_token(token)
    config_module.save_config(config)

    logger.info("New API token generated")
    return TokenResponse(token=token)
