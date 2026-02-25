"""
AVA Doorbell v4.0 — FastAPI Application Entry Point

Main app setup, middleware, router mounting, startup hooks, and uvicorn launch.
"""

import asyncio
import logging
import os
import secrets
import subprocess
import threading
from contextlib import asynccontextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from . import config as config_module
from .ssl_manager import ensure_ssl_cert
from .routers import (
    auth_routes, public, cameras, services,
    settings, websocket, discovery_routes, smb, backup, setup,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

# Suppress noisy uvicorn access logs
logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


# ============================================================================
# Lifespan (startup / shutdown)
# ============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan — sets setup_mode flag.

    Heavy startup tasks (go2rtc config, camera scanning) run once
    in __main__ before uvicorn starts, not here, to avoid duplicate
    execution from the HTTPS companion server's second lifespan call.
    """
    if not hasattr(app.state, "setup_mode"):
        cfg = config_module.load_config()
        app.state.setup_mode = not cfg.get("admin", {}).get("setup_complete", False)
    yield
    logger.info("Shutting down AVA Admin Server")


def _restart_go2rtc():
    """Restart go2rtc to pick up new config."""
    try:
        result = subprocess.run(
            ["sudo", "systemctl", "restart", "go2rtc"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0:
            logger.info("go2rtc restarted to apply new config")
        else:
            logger.warning(f"Failed to restart go2rtc: {result.stderr}")
    except Exception as e:
        logger.warning(f"go2rtc restart failed: {e}")


# ============================================================================
# App Creation
# ============================================================================

app = FastAPI(
    title="AVA Doorbell",
    version="4.0",
    docs_url=None,  # Disable Swagger UI in production
    redoc_url=None,
    lifespan=lifespan,
)

# Session middleware — secret key persisted to survive restarts
_secret_key_file = config_module.CONFIG_DIR / ".secret_key"
try:
    config_module.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if _secret_key_file.exists():
        _secret_key = _secret_key_file.read_text().strip()
    else:
        _secret_key = secrets.token_hex(32)
        with open(_secret_key_file, "w") as _f:
            _f.write(_secret_key)
            _f.flush()
            os.fsync(_f.fileno())
        _secret_key_file.chmod(0o600)
        logger.info("Generated new session secret key")
except Exception as e:
    logger.warning(f"Could not persist secret key ({e}), using ephemeral key")
    _secret_key = secrets.token_hex(32)

app.add_middleware(SessionMiddleware, secret_key=_secret_key, max_age=86400)


# ============================================================================
# Middleware: Setup Wizard Redirect
# ============================================================================

@app.middleware("http")
async def setup_redirect_middleware(request: Request, call_next):
    """Redirect all non-setup routes to /setup if setup is incomplete."""
    if getattr(app.state, "setup_mode", False):
        path = request.url.path
        allowed = path.startswith(("/setup", "/static", "/api/setup", "/api/health", "/app"))
        if not allowed:
            return RedirectResponse("/setup")

    # Note: No automatic HTTP→HTTPS redirect. The main server runs on HTTP (port 5000)
    # for maximum compatibility. Browsers that need HTTPS (for microphone/push-to-talk)
    # can use https://<ip>:5443 directly. The admin dashboard shows a link to the
    # HTTPS URL when push-to-talk features are needed.

    return await call_next(request)


# ============================================================================
# Mount Routers
# ============================================================================

app.include_router(auth_routes.router)
app.include_router(public.router)
app.include_router(cameras.router)
app.include_router(services.router)
app.include_router(settings.router)
app.include_router(websocket.router)
app.include_router(discovery_routes.router)
app.include_router(smb.router)
app.include_router(backup.router)
app.include_router(setup.router)

# Static files
static_dir = Path(__file__).parent / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


# ============================================================================
# Admin Dashboard Route (auth required)
# ============================================================================

from .dependencies import require_auth
from fastapi import Depends
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

_templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


@app.get("/", response_class=HTMLResponse)
async def admin_dashboard(request: Request, user: str = Depends(require_auth)):
    """Admin dashboard (requires authentication)."""
    return _templates.TemplateResponse("index.html", {"request": request})


# ============================================================================
# Error Handlers
# ============================================================================

@app.exception_handler(404)
async def not_found(request: Request, exc):
    return JSONResponse({"error": "Not found"}, status_code=404)


# ============================================================================
# HTTP -> HTTPS Redirect Server
# ============================================================================

def start_http_redirect_server(https_port: int, http_port: int = 80):
    """Run a minimal HTTP server that 301-redirects to HTTPS."""

    class _RedirectHandler(BaseHTTPRequestHandler):
        def _do_redirect(self):
            host = (self.headers.get("Host") or "").split(":")[0] or "localhost"
            location = f"https://{host}:{https_port}{self.path}"
            self.send_response(301)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _do_redirect

        def log_message(self, format, *args):
            pass

    def _serve(port):
        try:
            server = HTTPServer(("0.0.0.0", port), _RedirectHandler)
            logger.info(f"HTTP→HTTPS redirect: port {port} → {https_port}")
            server.serve_forever()
        except OSError as e:
            logger.warning(f"Could not start HTTP redirect on port {port}: {e}")
            if port < 1024:
                logger.warning(
                    "Ports below 1024 require root. "
                    "Try: sudo setcap cap_net_bind_service=+ep $(which python3)"
                )

    # Redirect from port 80 (browser default)
    threading.Thread(target=_serve, args=(http_port,), daemon=True).start()


def start_https_companion_server(
    app_instance: FastAPI, cert_path: str, key_path: str, https_port: int = 5443
):
    """
    Run the same FastAPI app over HTTPS on a companion port.

    Browsers need HTTPS for microphone access (push-to-talk).
    The main server runs on HTTP (port 5000) so that all clients
    (Android WebView, API calls) work without SSL cert issues.

    Uses the existing app instance (not a string import) to avoid
    re-importing the module and running the lifespan a second time.
    """
    import uvicorn

    config = uvicorn.Config(
        app_instance,
        host="0.0.0.0",
        port=https_port,
        ssl_keyfile=key_path,
        ssl_certfile=cert_path,
        log_level="warning",
    )

    def _serve():
        logger.info(f"HTTPS companion server on https://0.0.0.0:{https_port}")
        server = uvicorn.Server(config)
        server.run()

    threading.Thread(target=_serve, daemon=True).start()


# ============================================================================
# Entry Point
# ============================================================================

if __name__ == "__main__":
    import uvicorn

    startup_config = config_module.load_config()
    port = startup_config.get("server", {}).get("admin_port", 5000)
    https_port = startup_config.get("server", {}).get("https_port", 5443)

    # --- One-time startup tasks (run here, not in lifespan) ---
    setup_complete = startup_config.get("admin", {}).get("setup_complete", False)
    app.state.setup_mode = not setup_complete

    if setup_complete:
        from .discovery import auto_scan_and_add_cameras
        if auto_scan_and_add_cameras(startup_config):
            config_module.save_config(startup_config)
            logger.info("Config updated with auto-scanned cameras")

        result = config_module.generate_go2rtc_config(startup_config)
        if result == "written":
            _restart_go2rtc()
        elif result == "empty":
            logger.warning("No cameras configured — go2rtc.yaml not generated")
    else:
        logger.info("Setup not complete — running in setup mode")

    # Ensure SSL cert (dynamic SAN based on current IP)
    current_ip = config_module.get_current_ip()
    cert_path, key_path = ensure_ssl_cert(config_module.CONFIG_DIR, current_ip)

    if cert_path and key_path:
        # HTTPS companion on port 5443 (browsers need it for microphone/push-to-talk)
        start_https_companion_server(app, cert_path, key_path, https_port)
        logger.info(f"  HTTPS companion: https://0.0.0.0:{https_port}")
    else:
        logger.warning("SSL not available — microphone (push-to-talk) will not work")

    # Main server: always HTTP on port 5000 — works for everything
    logger.info(f"Starting AVA Admin Server on http://0.0.0.0:{port}")
    uvicorn.run(
        "admin.main:app",
        host="0.0.0.0",
        port=port,
        workers=1,
        log_level="warning",
    )
