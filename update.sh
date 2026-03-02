#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# update.sh — Pull latest AVA Doorbell from GitHub and deploy
#
# Run on the Pi to pull the latest code from GitHub and update the
# installed services. Requires a git clone with deploy key access.
#
# One-time setup:
#   ssh-keygen -t ed25519 -C "ava-pi-deploy" -f ~/.ssh/ava_deploy -N ""
#   # Add ~/.ssh/ava_deploy.pub as a deploy key in GitHub repo settings
#   GIT_SSH_COMMAND="ssh -i ~/.ssh/ava_deploy" \
#     git clone git@github.com:superfeldy/ava-doorbell.git ~/ava-doorbell-repo
#   # Configure repo to always use deploy key:
#   git -C ~/ava-doorbell-repo config core.sshCommand "ssh -i ~/.ssh/ava_deploy"
#
# Usage:
#   bash ~/ava-doorbell-repo/update.sh
#   bash ~/ava-doorbell-repo/update.sh --force    # skip up-to-date check
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_DIR="${HOME}/ava-doorbell-repo"
INSTALL_DIR="${HOME}/ava-doorbell"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
    esac
    shift
done

# ─── Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[update]${NC} $*"; }
warn()  { echo -e "${YELLOW}[update]${NC} $*"; }
error() { echo -e "${RED}[update]${NC} $*" >&2; }

# ─── Validate ───────────────────────────────────────────────────────
if [ ! -d "$REPO_DIR/.git" ]; then
    error "No git repo at $REPO_DIR"
    error "Run one-time setup first (see script header)"
    exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
    error "Install directory not found: $INSTALL_DIR"
    exit 1
fi

# ─── Pull latest ────────────────────────────────────────────────────
cd "$REPO_DIR"
info "Fetching origin/main..."
git fetch origin main

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ] && [ "$FORCE" -eq 0 ]; then
    info "Already up to date ($(echo "$LOCAL" | cut -c1-7))"
    exit 0
fi

OLD_REV=$(echo "$LOCAL" | cut -c1-7)
git pull origin main
NEW_REV=$(git rev-parse HEAD | cut -c1-7)
info "Updated: ${OLD_REV} → ${NEW_REV}"

# Show what changed
echo ""
git log --oneline "${LOCAL}..HEAD"
echo ""

# ─── Copy services to install dir ───────────────────────────────────
info "Syncing services to ${INSTALL_DIR}/services/"
rsync -av --exclude='__pycache__' --exclude='*.pyc' \
    services/ "${INSTALL_DIR}/services/"

rsync -av config/config.default.json "${INSTALL_DIR}/config/config.default.json"

# ─── Update Python dependencies ─────────────────────────────────────
if [ -f "${INSTALL_DIR}/venv/bin/pip" ]; then
    info "Checking Python dependencies..."
    "${INSTALL_DIR}/venv/bin/pip" install -r services/requirements.txt --quiet 2>/dev/null || true
fi

# ─── Restart services ───────────────────────────────────────────────
info "Restarting services..."
sudo systemctl restart alarm-scanner ava-talk ava-admin
sleep 3

# Verify
ALL_OK=1
for svc in alarm-scanner ava-talk ava-admin go2rtc mosquitto; do
    STATE=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    if [ "$STATE" != "active" ]; then
        error "$svc: $STATE"
        ALL_OK=0
    fi
done

if [ "$ALL_OK" -eq 1 ]; then
    info "All services active"
else
    error "Some services failed — check: journalctl -u <service> -n 50"
    exit 1
fi

# ─── Health check ───────────────────────────────────────────────────
info "Health check..."
HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" "http://localhost:5000/api/health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    info "Health check passed"
else
    warn "Health check returned HTTP ${HTTP_CODE}"
fi

info "Update complete: $(git log --oneline -1)"
