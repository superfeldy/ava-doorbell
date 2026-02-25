"""
AVA Doorbell v4.0 — Authentication & Authorization

Session-based auth for browsers, API token auth for Android/API clients.
Rate limiting for login attempts.
"""

import logging
import secrets
import time
from typing import Dict, List, Optional

from werkzeug.security import check_password_hash, generate_password_hash

logger = logging.getLogger(__name__)

# Rate limiting: IP -> [timestamps]
_login_attempts: Dict[str, List[float]] = {}
RATE_LIMIT_ATTEMPTS = 5
RATE_LIMIT_WINDOW = 900  # 15 minutes
SESSION_TIMEOUT = 3600   # 60 minutes (default, overridable via config)


# ============================================================================
# Password Hashing
# ============================================================================

def hash_password(password: str) -> str:
    """Generate a secure password hash."""
    return generate_password_hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    """Verify password against stored hash."""
    try:
        return check_password_hash(password_hash, password)
    except Exception as e:
        logger.error(f"Password verification failed: {e}")
        return False


# ============================================================================
# API Token
# ============================================================================

def generate_api_token() -> str:
    """Generate a random API token (64 hex chars)."""
    return secrets.token_hex(32)


def hash_token(token: str) -> str:
    """Hash an API token for storage."""
    return generate_password_hash(token)


def verify_token(token: str, token_hash: str) -> bool:
    """Verify API token against stored hash."""
    try:
        return check_password_hash(token_hash, token)
    except Exception:
        return False


# ============================================================================
# Rate Limiting
# ============================================================================

def check_rate_limit(ip: str) -> bool:
    """Check if IP has exceeded login attempt rate limit.

    Returns True if the attempt is allowed, False if rate-limited.
    Does NOT record the attempt — call record_failed_attempt() on failure.
    """
    now = time.time()
    if ip not in _login_attempts:
        _login_attempts[ip] = []

    # Remove expired attempts for this IP
    _login_attempts[ip] = [t for t in _login_attempts[ip] if now - t < RATE_LIMIT_WINDOW]

    # Periodic sweep: remove stale IPs with no recent attempts (prevents unbounded growth)
    if len(_login_attempts) > 100:
        stale = [k for k, v in _login_attempts.items() if not v or now - v[-1] > RATE_LIMIT_WINDOW]
        for k in stale:
            del _login_attempts[k]

    if len(_login_attempts[ip]) >= RATE_LIMIT_ATTEMPTS:
        return False

    return True


def record_failed_attempt(ip: str) -> None:
    """Record a failed login attempt for rate-limiting purposes."""
    now = time.time()
    if ip not in _login_attempts:
        _login_attempts[ip] = []
    _login_attempts[ip].append(now)


# ============================================================================
# Session Helpers
# ============================================================================

def is_session_valid(session: dict) -> bool:
    """Check if a session is still valid (not expired)."""
    if "user_id" not in session:
        return False
    last_activity = session.get("last_activity", 0)
    timeout = session.get("_timeout", SESSION_TIMEOUT)
    return (time.time() - last_activity) < timeout


def refresh_session(session: dict) -> None:
    """Update session last activity timestamp."""
    session["last_activity"] = time.time()
