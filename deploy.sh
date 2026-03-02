#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# deploy.sh — Push AVA Doorbell updates from Mac to Pi
#
# Syncs service files, config templates, and optionally builds/deploys
# the Android APK. Restarts affected services and runs a health check.
#
# Usage:
#   bash deploy.sh                     # sync services + restart
#   bash deploy.sh --build-apk         # also build and deploy APK
#   bash deploy.sh --skip-restart      # sync only, no restart
#   bash deploy.sh --dry-run           # show what would change
#
# Environment variables:
#   PI_HOST     Pi IP address (default: 10.10.10.167)
#   SSH_USER    SSH username (default: pi)
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

PI_HOST="${PI_HOST:-10.10.10.167}"
SSH_USER="${SSH_USER:-pi}"
INSTALL_DIR="/home/${SSH_USER}/ava-doorbell"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DRY_RUN=0
BUILD_APK=0
SKIP_RESTART=0

# ─── Parse args ─────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --build-apk) BUILD_APK=1 ;;
        --skip-restart) SKIP_RESTART=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --host) shift; PI_HOST="${1:-$PI_HOST}" ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

# ─── Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()    { echo -e "${YELLOW}[deploy]${NC} $*"; }
error()   { echo -e "${RED}[deploy]${NC} $*" >&2; }

ssh_cmd() { ssh -o ConnectTimeout=5 "${SSH_USER}@${PI_HOST}" "$@"; }

# ─── Pre-flight ─────────────────────────────────────────────────────
info "Target: ${SSH_USER}@${PI_HOST}:${INSTALL_DIR}"

# Check git status
if [ -d "${SCRIPT_DIR}/.git" ]; then
    DIRTY=$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DIRTY" -gt 0 ]; then
        warn "Working tree has $DIRTY uncommitted change(s)"
    fi
fi

# Ping Pi
if ! ping -c 1 -W 2 "$PI_HOST" >/dev/null 2>&1; then
    error "Cannot reach ${PI_HOST}"
    exit 1
fi
info "Pi reachable"

# Verify SSH
if ! ssh_cmd "true" 2>/dev/null; then
    error "SSH connection failed"
    exit 1
fi
info "SSH OK"

RSYNC_FLAGS="-avz --exclude=__pycache__ --exclude=.DS_Store --exclude=*.pyc"
if [ "$DRY_RUN" -eq 1 ]; then
    RSYNC_FLAGS="${RSYNC_FLAGS} -n"
    info "DRY RUN — no changes will be made"
fi

# ─── Sync services ──────────────────────────────────────────────────
info "Syncing services/"
rsync $RSYNC_FLAGS \
    "${SCRIPT_DIR}/services/" "${SSH_USER}@${PI_HOST}:${INSTALL_DIR}/services/"

# ─── Sync config template (never overwrite live config.json) ────────
info "Syncing config template"
rsync $RSYNC_FLAGS \
    "${SCRIPT_DIR}/config/config.default.json" \
    "${SSH_USER}@${PI_HOST}:${INSTALL_DIR}/config/config.default.json"

# ─── Build and deploy APK ───────────────────────────────────────────
if [ "$BUILD_APK" -eq 1 ]; then
    info "Building APK..."
    (cd "${SCRIPT_DIR}/android-app" && ./gradlew assembleDebug --quiet)
    APK_SRC="${SCRIPT_DIR}/android-app/app/build/outputs/apk/debug/app-debug.apk"
    if [ ! -f "$APK_SRC" ]; then
        error "APK build failed — file not found"
        exit 1
    fi
    mkdir -p "${SCRIPT_DIR}/apk"
    cp "$APK_SRC" "${SCRIPT_DIR}/apk/ava-doorbell.apk"

    if [ "$DRY_RUN" -eq 0 ]; then
        info "Deploying APK to Pi"
        scp "$APK_SRC" "${SSH_USER}@${PI_HOST}:${INSTALL_DIR}/apk/ava-doorbell.apk"
    else
        info "DRY RUN: would scp APK to ${INSTALL_DIR}/apk/"
    fi
fi

# ─── Restart services ───────────────────────────────────────────────
if [ "$SKIP_RESTART" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    info "Restarting services..."
    ssh_cmd "sudo systemctl restart alarm-scanner ava-talk ava-admin"
    sleep 3

    # Verify
    STATES=$(ssh_cmd "systemctl is-active alarm-scanner ava-talk ava-admin go2rtc mosquitto" 2>/dev/null || true)
    FAILED=0
    while IFS= read -r state; do
        if [ "$state" != "active" ]; then
            FAILED=1
        fi
    done <<< "$STATES"

    if [ "$FAILED" -eq 1 ]; then
        error "Some services not active after restart:"
        echo "$STATES"
        exit 1
    fi
    info "All services active"
elif [ "$DRY_RUN" -eq 1 ]; then
    info "DRY RUN: would restart alarm-scanner ava-talk ava-admin"
fi

# ─── Health check ───────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 0 ]; then
    info "Health check..."
    HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" "http://${PI_HOST}:5000/api/health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        info "Health check passed (HTTP 200)"
    else
        warn "Health check returned HTTP ${HTTP_CODE}"
    fi
fi

info "Deploy complete"
