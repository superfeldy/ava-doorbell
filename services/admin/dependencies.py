"""
AVA Doorbell v4.0 — FastAPI Dependencies

Reusable dependency injection functions for route handlers.
"""

import logging
from typing import Any, Dict

from fastapi import Depends, HTTPException, Request
from fastapi.responses import RedirectResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from . import auth, config as config_module

logger = logging.getLogger(__name__)

# Optional bearer token extractor (doesn't fail if no token present)
_bearer_scheme = HTTPBearer(auto_error=False)


def get_config() -> Dict[str, Any]:
    """Load and return the current configuration."""
    return config_module.load_config()


async def require_auth(
    request: Request,
    token: HTTPAuthorizationCredentials | None = Depends(_bearer_scheme),
) -> str:
    """Require authentication via session cookie or Bearer token.

    Returns the authenticated user identifier.
    Raises HTTPException(401) for API routes or redirects to /login for pages.
    """
    is_api = request.url.path.startswith("/api/")

    # Check 1: Session cookie (browser)
    session = request.session
    if auth.is_session_valid(session):
        auth.refresh_session(session)
        return session["user_id"]

    # Session expired — clear it
    if "user_id" in session:
        session.clear()

    # Check 2: Bearer token (Android / API clients)
    if token and token.credentials:
        cfg = config_module.load_config()
        token_hash = cfg.get("admin", {}).get("api_token_hash", "")
        if token_hash and auth.verify_token(token.credentials, token_hash):
            return "api"

    # Not authenticated
    if is_api:
        raise HTTPException(
            status_code=401,
            detail={"error": "Not authenticated", "login_required": True},
        )
    raise HTTPException(status_code=307, headers={"Location": "/login"})


async def require_setup_complete(request: Request) -> None:
    """Ensure setup wizard has been completed.

    Used by the setup-redirect middleware; not typically a direct dependency.
    """
    cfg = config_module.load_config()
    if not cfg.get("admin", {}).get("setup_complete", False):
        raise HTTPException(status_code=307, headers={"Location": "/setup"})
