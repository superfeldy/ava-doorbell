#!/bin/bash
################################################################################
# AVA Doorbell v4.0 — Interactive Setup
#
# Single entry point for technicians. Prompts for site info, validates
# connectivity, runs install.sh, configures cameras via API, and verifies
# the full stack.
#
# Usage:  chmod +x setup.sh && ./setup.sh
################################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/ava-doorbell"
CONFIG_DIR="${INSTALL_DIR}/config"
LOG_FILE="${INSTALL_DIR}/setup.log"
STEP=0
TOTAL_STEPS=7

# Site info — populated by step 1
PI_IP=""
DOORBELL_IP=""
DOORBELL_USER=""
DOORBELL_PASS=""
NVR_IP=""
NVR_USER=""
NVR_PASS=""
ADMIN_PASS=""

################################################################################
# Helpers
################################################################################

step() {
    STEP=$((STEP + 1))
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  STEP ${STEP}/${TOTAL_STEPS}  ${BOLD}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }

# Prompt with default value. Usage: ask "Label" "default"
ask() {
    local label="$1" default="${2:-}"
    local value
    if [[ -n "$default" ]]; then
        read -rp "  $(echo -e "${BOLD}")${label}${NC} [${default}]: " value
        echo "${value:-$default}"
    else
        read -rp "  $(echo -e "${BOLD}")${label}${NC}: " value
        echo "$value"
    fi
}

# Prompt for password (hidden input). Usage: ask_pass "Label"
ask_pass() {
    local label="$1" value
    read -srp "  $(echo -e "${BOLD}")${label}${NC}: " value
    echo ""
    echo "$value"
}

# Yes/no prompt. Returns 0 for yes, 1 for no.
yesno() {
    local prompt="$1" response
    while true; do
        read -rp "  $(echo -e "${BLUE}")${prompt}${NC} (y/n) " response
        case "$response" in
            [yY]*) return 0 ;;
            [nN]*) return 1 ;;
            *) echo "  Please answer y or n" ;;
        esac
    done
}

# Check if host responds to ping (1 packet, 2 second timeout)
can_ping() {
    ping -c 1 -W 2 "$1" &>/dev/null
}

# Check if HTTP port responds
can_http() {
    curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://$1" 2>/dev/null
}

# Wait for a URL to return HTTP 2xx, with retries
wait_for_url() {
    local url="$1" max_tries="${2:-15}" delay="${3:-2}"
    local i http_code
    for ((i=1; i<=max_tries; i++)); do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || echo "000")
        if [[ "$http_code" =~ ^2 ]]; then
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

# Build JSON safely using python3 (handles quotes/backslashes in passwords)
json_kv() {
    python3 -c "
import json, sys
pairs = {}
it = iter(sys.argv[1:])
for k in it:
    pairs[k] = next(it)
print(json.dumps(pairs))
" "$@"
}

################################################################################
# Banner
################################################################################

echo -e "${BLUE}"
cat << 'BANNER'

     █████╗ ██╗   ██╗ █████╗     ██████╗  ██████╗  ██████╗ ██████╗
    ██╔══██╗██║   ██║██╔══██╗    ██╔══██╗██╔═══██╗██╔═══██╗██╔══██╗
    ███████║██║   ██║███████║    ██║  ██║██║   ██║██║   ██║██████╔╝
    ██╔══██║╚██╗ ██╔╝██╔══██║    ██║  ██║██║   ██║██║   ██║██╔══██╗
    ██║  ██║ ╚████╔╝ ██║  ██║    ██████╔╝╚██████╔╝╚██████╔╝██║  ██║
    ╚═╝  ╚═╝  ╚═══╝  ╚═╝  ╚═╝    ╚═════╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝

BANNER
echo -e "    ${BOLD}Interactive Setup  •  v4.0${NC}"
echo ""

mkdir -p "${INSTALL_DIR}"
log "=== Setup started ==="

################################################################################
# STEP 1: Gather Site Info
################################################################################

step "Gather Site Info"

echo ""
echo -e "  ${BOLD}We'll collect the info needed before doing anything.${NC}"
echo -e "  Press Enter to accept the [default] shown in brackets."
echo ""

# --- Pi IP ---
echo -e "  ${CYAN}── Pi Server ──${NC}"
detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
PI_IP=$(ask "Pi IP address" "${detected_ip:-10.10.10.167}")
log "PI_IP=${PI_IP}"

# --- Doorbell ---
echo ""
echo -e "  ${CYAN}── Doorbell (Dahua VTO) ──${NC}"
echo -e "  ${CYAN}   Tip: IP is on the sticker on the back of the unit${NC}"
DOORBELL_IP=$(ask "Doorbell IP" "10.10.10.187")
if [[ -n "$DOORBELL_IP" ]]; then
    DOORBELL_USER=$(ask "Doorbell username" "admin")
    DOORBELL_PASS=$(ask_pass "Doorbell password")
fi
log "DOORBELL_IP=${DOORBELL_IP}"

# --- NVR ---
echo ""
echo -e "  ${CYAN}── NVR (skip if none) ──${NC}"
if yesno "Is there an NVR on this site?"; then
    NVR_IP=$(ask "NVR IP" "10.10.10.195")
    NVR_USER=$(ask "NVR username" "admin")
    NVR_PASS=$(ask_pass "NVR password")
    log "NVR_IP=${NVR_IP}"
else
    info "Skipping NVR"
fi

# --- Admin password ---
echo ""
echo -e "  ${CYAN}── Admin Dashboard ──${NC}"
while true; do
    ADMIN_PASS=$(ask_pass "Choose admin password (min 6 chars)")
    if [[ ${#ADMIN_PASS} -lt 6 ]]; then
        fail "Password must be at least 6 characters"
        continue
    fi
    local_confirm=$(ask_pass "Confirm password")
    if [[ "$ADMIN_PASS" != "$local_confirm" ]]; then
        fail "Passwords don't match"
        continue
    fi
    ok "Password set"
    break
done

# --- Summary ---
echo ""
echo -e "  ${CYAN}── Summary ──${NC}"
echo -e "  Pi IP:          ${BOLD}${PI_IP}${NC}"
echo -e "  Doorbell:       ${BOLD}${DOORBELL_IP:-none}${NC}  (${DOORBELL_USER:-n/a})"
echo -e "  NVR:            ${BOLD}${NVR_IP:-none}${NC}  (${NVR_USER:-n/a})"
echo -e "  Admin password: ${BOLD}$(printf '*%.0s' $(seq 1 ${#ADMIN_PASS}))${NC}"
echo ""

if ! yesno "Does this look correct?"; then
    warn "Run setup.sh again to re-enter"
    exit 0
fi

################################################################################
# STEP 2: Pre-flight Connectivity Checks
################################################################################

step "Pre-flight Checks"

preflight_ok=true

# Internet
if can_ping 8.8.8.8; then
    ok "Internet connectivity"
else
    warn "No internet — install.sh needs it to download packages"
    preflight_ok=false
fi

# Doorbell
if [[ -n "$DOORBELL_IP" ]]; then
    if can_ping "$DOORBELL_IP"; then
        ok "Doorbell reachable at ${DOORBELL_IP}"
        # Test Dahua HTTP API
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
            -u "${DOORBELL_USER}:${DOORBELL_PASS}" \
            "http://${DOORBELL_IP}/cgi-bin/magicBox.cgi?action=getDeviceType" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            ok "Doorbell credentials verified"
        elif [[ "$http_code" == "401" ]]; then
            fail "Doorbell credentials rejected (HTTP 401)"
            preflight_ok=false
        else
            warn "Could not verify doorbell credentials (HTTP ${http_code})"
        fi
    else
        fail "Doorbell not reachable at ${DOORBELL_IP}"
        preflight_ok=false
    fi
fi

# NVR
if [[ -n "$NVR_IP" ]]; then
    if can_ping "$NVR_IP"; then
        ok "NVR reachable at ${NVR_IP}"
    else
        fail "NVR not reachable at ${NVR_IP}"
        preflight_ok=false
    fi
fi

if [[ "$preflight_ok" == false ]]; then
    echo ""
    if ! yesno "Some checks failed. Continue anyway?"; then
        warn "Fix the issues above and re-run setup.sh"
        exit 1
    fi
fi

################################################################################
# STEP 3: Install Software
################################################################################

step "Install Software"

if [[ -f "${SCRIPT_DIR}/install.sh" ]]; then
    info "Running install.sh (this takes a few minutes on first run)..."
    echo ""
    if bash "${SCRIPT_DIR}/install.sh"; then
        ok "Installation completed"
        log "install.sh succeeded"
    else
        fail "install.sh failed — check output above"
        log "install.sh FAILED"
        exit 1
    fi
else
    fail "install.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

################################################################################
# STEP 4: Verify Services
################################################################################

step "Verify Services"

all_ok=true
services=(mosquitto go2rtc alarm-scanner ava-talk ava-admin smbd)

for svc in "${services[@]}"; do
    if sudo systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        ok "${svc} is running"
    else
        fail "${svc} is NOT running"
        info "Check logs: sudo journalctl -u ${svc} -n 30 --no-pager"
        all_ok=false
    fi
done

if [[ "$all_ok" == false ]]; then
    echo ""
    if yesno "Some services failed. Try restarting them?"; then
        for svc in "${services[@]}"; do
            sudo systemctl restart "${svc}.service" 2>/dev/null || true
        done
        sleep 3
        # Re-check
        for svc in "${services[@]}"; do
            if sudo systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
                ok "${svc} is running (after restart)"
            else
                fail "${svc} still not running"
            fi
        done
    fi
fi

################################################################################
# STEP 5: Configure via API
################################################################################

step "Configure System"

ADMIN_URL="http://localhost:5000"

# Check if setup already completed
setup_status=$(curl -s "${ADMIN_URL}/api/setup/status" 2>/dev/null || echo '{}')
if echo "$setup_status" | grep -q '"setup_complete": true'; then
    ok "Setup already completed — skipping configuration"
    info "To reconfigure, edit ${CONFIG_DIR}/config.json or use the admin dashboard"
else
    # Wait for admin server to be ready
    api_ready=true
    info "Waiting for admin server..."
    if wait_for_url "${ADMIN_URL}/api/setup/status" 20 2; then
        ok "Admin server is ready"
    else
        fail "Admin server didn't start within 40 seconds"
        info "Check: sudo journalctl -u ava-admin -n 50 --no-pager"
        info "You can finish setup manually at http://${PI_IP}:5000/setup"
        api_ready=false
    fi

  if [[ "$api_ready" == true ]]; then
    # 5a: Set password
    if [[ -n "$ADMIN_PASS" ]]; then
        info "Setting admin password..."
        resp=$(curl -s -X POST "${ADMIN_URL}/api/setup/password" \
            -H "Content-Type: application/json" \
            -d "$(json_kv password "$ADMIN_PASS")" 2>/dev/null || echo '{"error":"request failed"}')
        if echo "$resp" | grep -q '"status":\s*"ok"'; then
            ok "Admin password set"
            log "Password configured"
        else
            detail=$(echo "$resp" | grep -o '"detail":"[^"]*"' | head -1 || echo "$resp")
            warn "Password setup: ${detail}"
        fi
    fi

    # 5b: Network + SSL
    info "Configuring network and generating SSL certificate..."
    resp=$(curl -s -X POST "${ADMIN_URL}/api/setup/network" \
        -H "Content-Type: application/json" \
        -d "{}" 2>/dev/null || echo '{"error":"request failed"}')
    if echo "$resp" | grep -q '"ssl_ready": true'; then
        ok "Network configured, SSL certificate generated"
    elif echo "$resp" | grep -q '"status":\s*"ok"'; then
        ok "Network configured (SSL not available)"
    else
        warn "Network configuration may have failed"
    fi

    # 5c: Cameras
    camera_args=()
    if [[ -n "$DOORBELL_IP" ]]; then
        camera_args+=(doorbell_ip "$DOORBELL_IP" doorbell_username "$DOORBELL_USER" doorbell_password "$DOORBELL_PASS")
    fi
    if [[ -n "$NVR_IP" ]]; then
        camera_args+=(nvr_ip "$NVR_IP" nvr_username "$NVR_USER" nvr_password "$NVR_PASS")
    fi

    if [[ ${#camera_args[@]} -gt 0 ]]; then
        camera_json=$(json_kv "${camera_args[@]}")
        info "Discovering cameras (this may take 30-60 seconds for NVR scan)..."
        resp=$(curl -s -X POST "${ADMIN_URL}/api/setup/cameras" \
            --max-time 120 \
            -H "Content-Type: application/json" \
            -d "${camera_json}" 2>/dev/null || echo '{"error":"request failed"}')
        if echo "$resp" | grep -q '"status":\s*"ok"'; then
            ok "Cameras configured"
            # Count cameras from the response
            cam_list=$(echo "$resp" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    cams = d.get('cameras', [])
    print(f'  Found {len(cams)} camera(s):')
    for c in cams:
        print(f'    • {c.get(\"name\", c.get(\"id\", \"unknown\"))}')
except: pass
" 2>/dev/null || true)
            [[ -n "$cam_list" ]] && echo -e "${GREEN}${cam_list}${NC}"
        else
            warn "Camera discovery may have failed — configure manually in the dashboard"
        fi
    else
        info "No cameras specified — add them later in the admin dashboard"
    fi

    # 5d: Complete setup
    info "Finalizing setup..."
    resp=$(curl -s -X POST "${ADMIN_URL}/api/setup/complete" \
        -H "Content-Type: application/json" \
        -d "{}" 2>/dev/null || echo '{"error":"request failed"}')
    if echo "$resp" | grep -q '"status":\s*"ok"'; then
        ok "Setup completed"
        log "Setup completed via API"
    else
        warn "Could not finalize — complete manually at http://${PI_IP}:5000/setup"
    fi
  fi  # api_ready
fi

################################################################################
# STEP 6: Final Verification
################################################################################

step "Verify Everything"

echo ""
verify_ok=true

# Admin dashboard
if curl -s -o /dev/null -w "" --max-time 3 "http://localhost:5000" 2>/dev/null; then
    ok "Admin dashboard is responding"
else
    fail "Admin dashboard not responding"
    verify_ok=false
fi

# go2rtc streams
stream_count=$(curl -s "http://localhost:1984/api/streams" --max-time 3 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(len(d))
except: print(0)
" 2>/dev/null || echo "0")
if [[ "$stream_count" -gt 0 ]]; then
    ok "go2rtc has ${stream_count} stream(s) configured"
else
    warn "go2rtc has no streams yet — add cameras in the admin dashboard"
fi

# MQTT
if command -v mosquitto_pub &>/dev/null; then
    if mosquitto_pub -h localhost -t "ava/test" -m "setup-check" 2>/dev/null; then
        ok "MQTT broker accepting messages"
    else
        warn "MQTT publish failed"
    fi
fi

# Doorbell event check (quick)
if [[ -n "$DOORBELL_IP" ]]; then
    if curl -s --max-time 3 -u "${DOORBELL_USER}:${DOORBELL_PASS}" \
        "http://${DOORBELL_IP}/cgi-bin/magicBox.cgi?action=getDeviceType" &>/dev/null; then
        ok "Doorbell API responding"
    else
        warn "Doorbell API not responding — alarm events may not work"
    fi
fi

################################################################################
# STEP 7: Done!
################################################################################

step "Setup Complete"

echo ""
echo -e "  ${GREEN}${BOLD}AVA Doorbell is ready!${NC}"
echo ""
echo -e "  ${CYAN}── Access Points ──${NC}"
echo -e "  Admin Dashboard:  ${BOLD}http://${PI_IP}:5000${NC}"
echo -e "  Live View:        ${BOLD}http://${PI_IP}:5000/view${NC}"
echo -e "  Login password:   ${BOLD}(the password you just set)${NC}"
echo ""
echo -e "  ${CYAN}── Next: Install the Android App ──${NC}"
echo -e "  1. On the tablet's browser, go to:"
echo -e "     ${BOLD}http://${PI_IP}:5000/app/download${NC}"
echo -e "     (or ADB: adb install apk/ava-doorbell.apk)"
echo -e "  2. Long-press (3 sec) anywhere on screen → Settings"
echo -e "  3. Enter these values:"
echo ""
echo -e "     ${BOLD}Server IP${NC}        ${PI_IP}"
echo -e "     ${BOLD}Admin Port${NC}       5000"
echo -e "     ${BOLD}MQTT Port${NC}        1883"
echo -e "     ${BOLD}Talk Port${NC}        5001"
echo -e "     ${BOLD}Default Camera${NC}   doorbell_direct"
echo -e "     ${BOLD}Default Layout${NC}   single"
echo ""
echo -e "  4. For the ${BOLD}API Token${NC}:"
echo -e "     → Log in to http://${PI_IP}:5000"
echo -e "     → Settings → API Token → Generate"
echo -e "     → Copy and paste into the Android app"
echo ""
echo -e "  ${CYAN}── Verify Checklist ──${NC}"
echo -e "  [ ] Admin dashboard loads at http://${PI_IP}:5000"
echo -e "  [ ] Login works with your password"
echo -e "  [ ] Cameras section shows discovered cameras"
echo -e "  [ ] Live View shows video feeds"
echo -e "  [ ] Android app connects and shows video"
echo -e "  [ ] Press doorbell → notification appears on tablet"
echo -e "  [ ] Mic FAB (bottom-right) → two-way audio works"
echo ""
echo -e "  ${CYAN}── Troubleshooting ──${NC}"
echo -e "  Service logs:     sudo journalctl -u ava-admin -f"
echo -e "  All service status: systemctl status ava-*"
echo -e "  go2rtc streams:   curl http://localhost:1984/api/streams"
echo -e "  MQTT listener:    mosquitto_sub -t \"doorbell/#\" -v"
echo -e "  Full reference:   ${BOLD}SETUP.md${NC} in this directory"
echo ""

log "=== Setup completed ==="
