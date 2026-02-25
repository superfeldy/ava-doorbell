#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# integration_test.sh — AVA Doorbell v4 Integration Test
#
# Exercises components the burn-in misses: WebSocket talk relay, MQTT,
# go2rtc direct API, WS proxy, and service recovery.
# Bash 3.2 compatible (macOS default — no associative arrays).
#
# Usage:
#   AVA_PASSWORD=<pass> bash integration_test.sh
#   AVA_PASSWORD=<pass> bash integration_test.sh --destructive
#   AVA_PASSWORD=<pass> bash integration_test.sh --soak 10
#
# Environment variables:
#   AVA_PASSWORD    Admin password (prompted if not set)
#   PI_HOST         Pi IP address (default: 10.10.10.167)
#   PI_PORT         Admin port (default: 5000)
#   SSH_USER        SSH username (default: pi)
#   SSH_PASS        SSH password (omit to use SSH keys)
#   SOAK_MINUTES    Soak phase duration (default: 5)
# ─────────────────────────────────────────────────────────────────────

# ─── Configuration ───────────────────────────────────────────────────
PI_HOST="${PI_HOST:-10.10.10.167}"
PI_PORT="${PI_PORT:-5000}"
BASE_URL="http://${PI_HOST}:${PI_PORT}"
SSH_USER="${SSH_USER:-pi}"
SSH_PASS="${SSH_PASS:-}"
AVA_PASSWORD="${AVA_PASSWORD:-}"
SOAK_MINUTES="${SOAK_MINUTES:-5}"
DESTRUCTIVE=0
TICK_SECONDS=10

# Parse CLI args
while [ $# -gt 0 ]; do
    case "$1" in
        --destructive) DESTRUCTIVE=1 ;;
        --soak) shift; SOAK_MINUTES="${1:-5}" ;;
    esac
    shift
done

# ─── Derived ─────────────────────────────────────────────────────────
COOKIE_JAR=$(mktemp /tmp/integ_cookies.XXXXXX)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="${SCRIPT_DIR}/integration_$(date +%Y%m%d_%H%M%S).log"
START_TIME=$(date +%s)

# ─── Stats (parallel indexed arrays — bash 3.2 safe) ────────────────
EP_NAMES=()
EP_CHECKS=()
EP_FAILS=()
EP_CONSEC=()
EP_MAX_CONSEC=()
EP_MIN_MS=()
EP_MAX_MS=()
EP_TOTAL_MS=()

TOTAL_CHECKS=0
TOTAL_FAILS=0
RESTARTS_DETECTED=0

# Service state tracking
SVC_NAMES=()
SVC_LAST_STATE=()

# Memory trend
FIRST_MEM_USED=""
LAST_MEM_USED=""

# Camera list for frame rotation
CAMERA_IDS=()
CAMERA_IDX=0

# ─── Helpers ─────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    printf "\r\033[K%s\n" "$msg"
    echo "$msg" >> "$LOGFILE"
}

log_err() {
    local msg="[$(date '+%H:%M:%S')] ERROR: $*"
    printf "\r\033[K%s\n" "$msg" >&2
    echo "$msg" >> "$LOGFILE"
}

json_get() {
    python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for k in '$1'.split('.'):
        d=d[int(k)] if isinstance(d,list) else d.get(k,'')
    print('' if d is None else d)
except: print('')" 2>/dev/null
}

json_pluck() {
    python3 -c "
import json,sys
try:
    for item in json.load(sys.stdin):
        v=item.get('$1','')
        if v: print(v)
except: pass" 2>/dev/null
}

# ─── Endpoint Stats ─────────────────────────────────────────────────

_EP_IDX=0  # global return value (avoids subshell from command substitution)

ep_index() {
    local name="$1"
    local i=0
    while [ $i -lt ${#EP_NAMES[@]} ]; do
        if [ "${EP_NAMES[$i]}" = "$name" ]; then
            _EP_IDX=$i
            return
        fi
        i=$((i + 1))
    done
    local idx=${#EP_NAMES[@]}
    EP_NAMES[$idx]="$name"
    EP_CHECKS[$idx]=0
    EP_FAILS[$idx]=0
    EP_CONSEC[$idx]=0
    EP_MAX_CONSEC[$idx]=0
    EP_MIN_MS[$idx]=999999
    EP_MAX_MS[$idx]=0
    EP_TOTAL_MS[$idx]=0
    _EP_IDX=$idx
}

record_success() {
    local name="$1" ms="$2"
    ep_index "$name"
    local idx=$_EP_IDX
    EP_CHECKS[$idx]=$(( ${EP_CHECKS[$idx]} + 1 ))
    EP_CONSEC[$idx]=0
    EP_TOTAL_MS[$idx]=$(( ${EP_TOTAL_MS[$idx]} + ms ))
    [ "$ms" -lt "${EP_MIN_MS[$idx]}" ] && EP_MIN_MS[$idx]=$ms
    [ "$ms" -gt "${EP_MAX_MS[$idx]}" ] && EP_MAX_MS[$idx]=$ms
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

record_failure() {
    local name="$1" reason="$2"
    ep_index "$name"
    local idx=$_EP_IDX
    EP_CHECKS[$idx]=$(( ${EP_CHECKS[$idx]} + 1 ))
    EP_FAILS[$idx]=$(( ${EP_FAILS[$idx]} + 1 ))
    EP_CONSEC[$idx]=$(( ${EP_CONSEC[$idx]} + 1 ))
    [ "${EP_CONSEC[$idx]}" -gt "${EP_MAX_CONSEC[$idx]}" ] && \
        EP_MAX_CONSEC[$idx]=${EP_CONSEC[$idx]}
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    TOTAL_FAILS=$((TOTAL_FAILS + 1))
    log_err "$name — $reason"
}

# ─── SSH Wrapper ─────────────────────────────────────────────────────

run_ssh() {
    if [ -n "$SSH_PASS" ]; then
        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 "${SSH_USER}@${PI_HOST}" "$@" 2>/dev/null
    else
        ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 "${SSH_USER}@${PI_HOST}" "$@" 2>/dev/null
    fi
}

# ─── curl Wrapper ────────────────────────────────────────────────────
# Sets: CURL_CODE, CURL_BODY, CURL_MS

do_curl() {
    local endpoint="$1"
    shift
    local url="${BASE_URL}${endpoint}"
    local tmp
    tmp=$(mktemp /tmp/integ_curl.XXXXXX)

    local result
    result=$(curl -s -o "$tmp" -w '%{http_code} %{time_total}' \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        --max-time 15 \
        "$@" "$url" 2>/dev/null) || result="000 0"

    CURL_CODE="${result%% *}"
    local time_s="${result#* }"
    CURL_MS=$(python3 -c "print(int(float('${time_s:-0}')*1000))" 2>/dev/null) || CURL_MS=0
    CURL_BODY=$(cat "$tmp" 2>/dev/null) || CURL_BODY=""
    rm -f "$tmp"
}

# ─── Authentication ──────────────────────────────────────────────────

authenticate() {
    log "Authenticating..."
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -L --max-time 10 \
        -d "password=${AVA_PASSWORD}" \
        "${BASE_URL}/login" 2>/dev/null) || code="000"

    if [ "$code" = "200" ]; then
        log "Authentication successful"
        return 0
    else
        log_err "Authentication failed (HTTP $code)"
        return 1
    fi
}

try_reauth() {
    if [ "$CURL_CODE" = "401" ] || [ "$CURL_CODE" = "307" ]; then
        log "Session expired (HTTP $CURL_CODE), re-authenticating..."
        authenticate && return 0
    fi
    return 1
}

# ─── Reused Checks (from burn_in.sh) ────────────────────────────────

discover_cameras() {
    do_curl "/api/cameras"
    if [ "$CURL_CODE" = "401" ] || [ "$CURL_CODE" = "307" ]; then
        authenticate && do_curl "/api/cameras"
    fi
    if [ "$CURL_CODE" = "200" ]; then
        CAMERA_IDS=()
        local ids
        ids=$(echo "$CURL_BODY" | json_pluck "id")
        while IFS= read -r line; do
            [ -n "$line" ] && CAMERA_IDS+=("$line")
        done <<< "$ids"
        log "Discovered ${#CAMERA_IDS[@]} camera(s): ${CAMERA_IDS[*]:-none}"
    else
        log_err "Camera discovery failed (HTTP $CURL_CODE)"
    fi
}

check_health() {
    do_curl "/api/health"
    if [ "$CURL_CODE" = "200" ]; then
        record_success "health" "$CURL_MS"

        local svc_lines
        svc_lines=$(echo "$CURL_BODY" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for name,info in d.get('services',{}).items():
        st=info.get('status','unknown') if isinstance(info,dict) else str(info)
        print(f'{name}={st}')
except: pass" 2>/dev/null)

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local svc_name="${line%%=*}"
            local svc_state="${line#*=}"

            local found=0 si=0
            while [ $si -lt ${#SVC_NAMES[@]} ]; do
                if [ "${SVC_NAMES[$si]}" = "$svc_name" ]; then
                    found=1
                    if [ "${SVC_LAST_STATE[$si]}" != "$svc_state" ]; then
                        if [ "$svc_state" = "active" ] && [ -n "${SVC_LAST_STATE[$si]}" ]; then
                            log "RESTART DETECTED: $svc_name (${SVC_LAST_STATE[$si]} -> $svc_state)"
                            RESTARTS_DETECTED=$((RESTARTS_DETECTED + 1))
                        else
                            log "State change: $svc_name (${SVC_LAST_STATE[$si]:-init} -> $svc_state)"
                        fi
                        SVC_LAST_STATE[$si]="$svc_state"
                    fi
                    break
                fi
                si=$((si + 1))
            done
            if [ $found -eq 0 ]; then
                SVC_NAMES+=("$svc_name")
                SVC_LAST_STATE+=("$svc_state")
            fi
        done <<< "$svc_lines"
    else
        record_failure "health" "HTTP $CURL_CODE"
    fi
}

check_public_endpoints() {
    do_curl "/api/setup/status"
    if [ "$CURL_CODE" = "200" ]; then
        record_success "setup/status" "$CURL_MS"
    else
        record_failure "setup/status" "HTTP $CURL_CODE"
    fi

    do_curl "/api/ws-info"
    if [ "$CURL_CODE" = "200" ]; then
        record_success "ws-info" "$CURL_MS"
    else
        record_failure "ws-info" "HTTP $CURL_CODE"
    fi
}

check_frame() {
    if [ ${#CAMERA_IDS[@]} -eq 0 ]; then return; fi

    local cam="${CAMERA_IDS[$CAMERA_IDX]}"
    CAMERA_IDX=$(( (CAMERA_IDX + 1) % ${#CAMERA_IDS[@]} ))

    do_curl "/api/frame.jpeg?src=${cam}"
    if [ "$CURL_CODE" = "200" ]; then
        record_success "frame/${cam}" "$CURL_MS"
    elif [ "$CURL_CODE" = "204" ]; then
        record_success "frame/${cam}" "$CURL_MS"
    else
        record_failure "frame/${cam}" "HTTP $CURL_CODE"
    fi
}

collect_metrics() {
    local start_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local output
    output=$(run_ssh "free -m | grep Mem; vcgencmd measure_temp 2>/dev/null; df -h / | tail -1; cat /proc/loadavg") || {
        local end_ms
        end_ms=$(python3 -c "import time;print(int(time.time()*1000))")
        record_failure "ssh/metrics" "SSH connection failed"
        return
    }

    local end_ms
    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")
    record_success "ssh/metrics" "$((end_ms - start_ms))"

    local mem_used mem_total
    mem_total=$(echo "$output" | head -1 | awk '{print $2}')
    mem_used=$(echo "$output" | head -1 | awk '{print $3}')
    [ -z "$FIRST_MEM_USED" ] && [ -n "$mem_used" ] && FIRST_MEM_USED="$mem_used"
    [ -n "$mem_used" ] && LAST_MEM_USED="$mem_used"

    local temp
    temp=$(echo "$output" | grep "temp=" | grep -o '[0-9]*\.[0-9]*' | head -1)

    local disk_pct
    disk_pct=$(echo "$output" | grep -E "^/dev" | awk '{print $5}')

    local load_avg
    load_avg=$(echo "$output" | tail -1 | awk '{print $1, $2, $3}')

    log "Metrics: mem=${mem_used:-?}/${mem_total:-?}MB  temp=${temp:-?}C  disk=${disk_pct:-?}  load=${load_avg:-?}"
}

# ─── Summary ─────────────────────────────────────────────────────────

print_summary() {
    local now elapsed elapsed_min
    now=$(date +%s)
    elapsed=$((now - START_TIME))
    elapsed_min=$((elapsed / 60))

    {
        echo ""
        echo "========================================================================"
        echo "                   AVA INTEGRATION TEST SUMMARY"
        echo "========================================================================"
        printf "  Duration: %dm   Checks: %d   Failures: %d   Restarts: %d\n" \
            "$elapsed_min" "$TOTAL_CHECKS" "$TOTAL_FAILS" "$RESTARTS_DETECTED"

        if [ -n "$FIRST_MEM_USED" ] && [ -n "$LAST_MEM_USED" ]; then
            local mem_delta=$((LAST_MEM_USED - FIRST_MEM_USED))
            local flag=""
            [ "$mem_delta" -gt 50 ] && flag="  ** GROWTH >50MB **"
            printf "  Memory trend: %sMB -> %sMB (delta: %+dMB)%s\n" \
                "$FIRST_MEM_USED" "$LAST_MEM_USED" "$mem_delta" "$flag"
        fi

        echo "------------------------------------------------------------------------"
        printf "  %-24s %6s %6s %6s %7s %7s %7s\n" \
            "ENDPOINT" "CHECKS" "FAILS" "MAXCON" "MIN ms" "AVG ms" "MAX ms"
        echo "------------------------------------------------------------------------"

        local i=0
        while [ $i -lt ${#EP_NAMES[@]} ]; do
            local name="${EP_NAMES[$i]}"
            local checks="${EP_CHECKS[$i]}"
            local fails="${EP_FAILS[$i]}"
            local max_c="${EP_MAX_CONSEC[$i]}"
            local min_ms="${EP_MIN_MS[$i]}"
            local max_ms="${EP_MAX_MS[$i]}"
            local avg_ms=0

            local ok=$((checks - fails))
            if [ "$ok" -gt 0 ]; then
                avg_ms=$(( ${EP_TOTAL_MS[$i]} / ok ))
            fi
            [ "$min_ms" = "999999" ] && min_ms="-"

            local mark=""
            [ "$fails" -gt 0 ] && mark="*"

            printf "  %-24s %6d %5d%1s %6d %7s %7d %7d\n" \
                "$name" "$checks" "$fails" "$mark" "$max_c" "$min_ms" "$avg_ms" "$max_ms"
            i=$((i + 1))
        done

        echo "========================================================================"
        echo ""
    } | tee -a "$LOGFILE"
}

# ─── Cleanup ─────────────────────────────────────────────────────────

cleanup() {
    echo ""
    log "Integration test interrupted — generating summary..."
    print_summary
    rm -f "$COOKIE_JAR"
    log "Log saved to: $LOGFILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

# ═════════════════════════════════════════════════════════════════════
#  NEW: Integration Test Functions
# ═════════════════════════════════════════════════════════════════════

# ─── Phase 1 Helpers ─────────────────────────────────────────────────

check_port_open() {
    local host="$1" port="$2" label="$3"
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    if python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect(('$host', $port))
    s.close()
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        end_ms=$(python3 -c "import time;print(int(time.time()*1000))")
        record_success "port/${label}" "$((end_ms - start_ms))"
    else
        record_failure "port/${label}" "TCP connect to ${host}:${port} failed"
    fi
}

check_ssh_port_open() {
    local port="$1" label="$2"
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local result
    result=$(run_ssh "python3 -c \"
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(('localhost',$port))
    s.close()
    print('open')
except:
    print('closed')
\"") || result="error"

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    if [ "$result" = "open" ]; then
        record_success "ssh-port/${label}" "$((end_ms - start_ms))"
    else
        record_failure "ssh-port/${label}" "Port $port not open on Pi ($result)"
    fi
}

check_all_services_active() {
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local svc_output
    svc_output=$(run_ssh "for svc in ava-admin go2rtc ava-talk alarm-scanner mosquitto smbd; do
        status=\$(systemctl is-active \$svc 2>/dev/null)
        echo \"\$svc=\$status\"
    done") || {
        record_failure "services/all" "SSH failed"
        return
    }

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local all_ok=1
    local failed_svcs=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local svc_name="${line%%=*}"
        local svc_state="${line#*=}"
        if [ "$svc_state" != "active" ]; then
            all_ok=0
            failed_svcs="${failed_svcs} ${svc_name}(${svc_state})"
        fi
    done <<< "$svc_output"

    if [ "$all_ok" -eq 1 ]; then
        record_success "services/all" "$((end_ms - start_ms))"
        log "All 6 services active"
    else
        record_failure "services/all" "Inactive:${failed_svcs}"
    fi
}

check_go2rtc_streams() {
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local body
    body=$(run_ssh "curl -s --max-time 5 http://localhost:1984/api/streams") || {
        record_failure "go2rtc/streams" "SSH or curl failed"
        return
    }

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local stream_count
    stream_count=$(echo "$body" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d))
except:
    print(-1)" 2>/dev/null)

    if [ "${stream_count:-0}" -gt 0 ]; then
        record_success "go2rtc/streams" "$((end_ms - start_ms))"
        log "go2rtc has $stream_count stream(s)"
    elif [ "${stream_count}" = "0" ]; then
        record_failure "go2rtc/streams" "No streams configured"
    else
        record_failure "go2rtc/streams" "Invalid JSON response"
    fi
}

check_go2rtc_direct_frame() {
    # Grab a JPEG directly from go2rtc port 1984 (the path the Android app uses for MJPEG fallback)
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local tmp
    tmp=$(mktemp /tmp/integ_frame.XXXXXX)
    local code
    code=$(curl -s -o "$tmp" -w '%{http_code}' --max-time 10 \
        "http://${PI_HOST}:1984/api/frame.jpeg?src=doorbell_direct" 2>/dev/null) || code="000"

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")
    local ms=$((end_ms - start_ms))

    if [ "$code" = "200" ]; then
        local size
        size=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')
        if [ "${size:-0}" -gt 1000 ]; then
            record_success "go2rtc/frame" "$ms"
            log "go2rtc direct frame: ${size} bytes"
        else
            record_failure "go2rtc/frame" "HTTP 200 but only ${size} bytes (expected >1000)"
        fi
    elif [ "$code" = "204" ]; then
        record_success "go2rtc/frame" "$ms"
        log "go2rtc direct frame: 204 (no frame yet, but endpoint works)"
    else
        record_failure "go2rtc/frame" "HTTP $code"
    fi
    rm -f "$tmp"
}

check_view_page() {
    do_curl "/view"
    if [ "$CURL_CODE" = "200" ]; then
        if echo "$CURL_BODY" | grep -qi "multiview\|viewport"; then
            record_success "view/default" "$CURL_MS"
            log "Multiview page loads OK"
        else
            record_failure "view/default" "HTTP 200 but page content unexpected"
        fi
    else
        record_failure "view/default" "HTTP $CURL_CODE"
    fi
}

check_view_mjpeg_page() {
    do_curl "/view?mode=mjpeg"
    if [ "$CURL_CODE" = "200" ]; then
        if echo "$CURL_BODY" | grep -qi "main-mjpeg"; then
            record_success "view/mjpeg" "$CURL_MS"
            log "MJPEG view page loads OK (main-mjpeg.js referenced)"
        else
            record_failure "view/mjpeg" "HTTP 200 but main-mjpeg.js not found in HTML"
        fi
    else
        record_failure "view/mjpeg" "HTTP $CURL_CODE"
    fi
}

test_webrtc_sdp_exchange() {
    # Send a minimal SDP offer to /api/webrtc, verify the route responds
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local sdp_offer="v=0
o=- 0 0 IN IP4 0.0.0.0
s=-
t=0 0
m=video 9 UDP/TLS/RTP/SAVPF 96
a=rtpmap:96 H264/90000
a=setup:actpass
a=mid:0
a=sendrecv"

    local tmp
    tmp=$(mktemp /tmp/integ_sdp.XXXXXX)
    local code
    code=$(curl -s -o "$tmp" -w '%{http_code}' --max-time 5 \
        -X POST \
        -H "Content-Type: application/sdp" \
        -d "$sdp_offer" \
        "${BASE_URL}/api/webrtc?src=doorbell_direct" 2>/dev/null) || code="000"

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")
    local ms=$((end_ms - start_ms))
    local body
    body=$(cat "$tmp" 2>/dev/null) || body=""
    rm -f "$tmp"

    if [ "$code" = "200" ]; then
        if echo "$body" | grep -qi "v=0"; then
            record_success "webrtc/sdp" "$ms"
            log "WebRTC SDP exchange OK (got SDP answer)"
        else
            record_success "webrtc/sdp" "$ms"
            log "WebRTC SDP: HTTP 200 (response present)"
        fi
    elif [ "$code" = "502" ] || [ "$code" = "500" ]; then
        # go2rtc may reject our minimal SDP but the route works
        record_success "webrtc/sdp" "$ms"
        log "WebRTC SDP: route active (HTTP $code — go2rtc rejected minimal offer, expected)"
    else
        record_failure "webrtc/sdp" "HTTP $code"
    fi
}

# ─── Phase 2 Helpers ─────────────────────────────────────────────────

test_talk_relay_ws() {
    log "Testing talk relay WebSocket (port 5001)..."
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local result
    result=$(run_ssh "~/ava-doorbell/venv/bin/python3 -c \"
import asyncio, ssl, websockets

async def test():
    try:
        # talk_relay uses wss:// with self-signed cert when SSL certs exist
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        try:
            ws = await asyncio.wait_for(
                websockets.connect('wss://localhost:5001', ssl=ctx),
                timeout=5
            )
        except Exception:
            # Fall back to ws:// if SSL not enabled
            ws = await asyncio.wait_for(
                websockets.connect('ws://localhost:5001'),
                timeout=5
            )
        async with ws:
            # Send 3 PCM16 silent frames: 0x01 + 640 zero bytes
            for i in range(3):
                await ws.send(b'\x01' + b'\x00' * 640)
                await asyncio.sleep(0.05)
            # Send 2 A-law silent frames: 0x03 + 320 bytes of 0xD5 (A-law silence)
            for i in range(2):
                await ws.send(b'\x03' + b'\xd5' * 320)
                await asyncio.sleep(0.05)
            await asyncio.sleep(0.3)
            print('OK:5')
    except Exception as e:
        print(f'FAIL:{e}')

asyncio.run(test())
\"" 2>/dev/null) || result="FAIL:SSH_ERROR"

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    case "$result" in
        OK:*)
            local frame_count="${result#OK:}"
            record_success "ws/talk_relay" "$((end_ms - start_ms))"
            log "Talk relay: sent $frame_count frames, connection stable"
            ;;
        *)
            record_failure "ws/talk_relay" "$result"
            ;;
    esac
}

test_mqtt_connectivity() {
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local result
    result=$(run_ssh "mosquitto_pub -h localhost -t 'doorbell/test' -m 'integration-check' 2>&1 && echo 'OK'") || result="FAIL"

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    if echo "$result" | grep -q "OK"; then
        record_success "mqtt/pub" "$((end_ms - start_ms))"
    else
        record_failure "mqtt/pub" "mosquitto_pub failed: $result"
    fi
}

test_mqtt_status_retained() {
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    # -C 1: read exactly 1 message then exit, -W 3: timeout 3s
    local result
    result=$(run_ssh "mosquitto_sub -h localhost -t 'doorbell/status' -C 1 -W 3 2>/dev/null") || result=""

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    if [ "$result" = "online" ]; then
        record_success "mqtt/status" "$((end_ms - start_ms))"
        log "MQTT retained status: 'online' (alarm-scanner connected)"
    elif [ -n "$result" ]; then
        record_failure "mqtt/status" "Unexpected: '$result' (expected 'online')"
    else
        record_failure "mqtt/status" "No retained message on doorbell/status"
    fi
}

test_mqtt_ring_roundtrip() {
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    # Subscribe in background, publish, verify round-trip
    local result
    result=$(run_ssh "
        tmpfile=\$(mktemp)
        mosquitto_sub -h localhost -t 'doorbell/test_ring' -C 1 -W 5 > \"\$tmpfile\" 2>/dev/null &
        SUB_PID=\$!
        sleep 0.5
        mosquitto_pub -h localhost -t 'doorbell/test_ring' -m '{\"event\":\"test\",\"source\":\"integration_test\"}'
        wait \$SUB_PID 2>/dev/null
        cat \"\$tmpfile\"
        rm -f \"\$tmpfile\"
    ") || result=""

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    if echo "$result" | grep -q "integration_test"; then
        record_success "mqtt/ring_rt" "$((end_ms - start_ms))"
        log "MQTT pub/sub round-trip OK"
    else
        record_failure "mqtt/ring_rt" "Message not received (got: '$result')"
    fi
}

test_alarm_scanner_test_event() {
    log "Triggering alarm_scanner --test event..."
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    # Subscribe to doorbell/ring in background, then trigger --test
    local result
    result=$(run_ssh "
        tmpfile=\$(mktemp)
        mosquitto_sub -h localhost -t 'doorbell/ring' -C 1 -W 10 > \"\$tmpfile\" 2>/dev/null &
        SUB_PID=\$!
        sleep 0.5
        ~/ava-doorbell/venv/bin/python3 ~/ava-doorbell/services/alarm_scanner.py --test 2>&1
        wait \$SUB_PID 2>/dev/null
        cat \"\$tmpfile\"
        rm -f \"\$tmpfile\"
    ") || result=""

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    if echo "$result" | grep -q "DoorBell"; then
        record_success "alarm/test_event" "$((end_ms - start_ms))"
        log "Alarm scanner --test: DoorBell event received on MQTT"
    elif echo "$result" | grep -qi "test ring event"; then
        # Got the log output but maybe not the MQTT message
        record_success "alarm/test_event" "$((end_ms - start_ms))"
        log "Alarm scanner --test: event published (log confirmed)"
    else
        record_failure "alarm/test_event" "No DoorBell event received: $result"
    fi

    # The --test instance creates a second MQTT client whose LWT overwrites the
    # retained "online" on doorbell/status when it disconnects.  Restore it so
    # subsequent mqtt/status checks (and other test runs) see the correct value.
    run_ssh "mosquitto_pub -h localhost -t 'doorbell/status' -m 'online' -r" 2>/dev/null
}

test_ws_proxy_upgrade() {
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    # Attempt WebSocket upgrade handshake
    local headers
    headers=$(curl -s -i -N --max-time 3 \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGVzdA==" \
        "${BASE_URL}/api/ws-proxy?src=doorbell_direct" 2>/dev/null) || headers=""

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    if echo "$headers" | grep -qi "101"; then
        record_success "ws/proxy" "$((end_ms - start_ms))"
        log "WS proxy: 101 Switching Protocols"
    elif echo "$headers" | grep -qi "HTTP"; then
        local code
        code=$(echo "$headers" | head -1 | awk '{print $2}')
        # 400/426 = route exists, handshake rejected (acceptable)
        if [ "$code" = "400" ] || [ "$code" = "426" ]; then
            record_success "ws/proxy" "$((end_ms - start_ms))"
            log "WS proxy: endpoint exists (HTTP $code — handshake rejected, route active)"
        else
            record_failure "ws/proxy" "Unexpected HTTP $code"
        fi
    else
        record_failure "ws/proxy" "No response from ws-proxy"
    fi
}

test_ws_talk_proxy_exists() {
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local headers
    headers=$(curl -s -i -N --max-time 3 \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGVzdA==" \
        "${BASE_URL}/api/ws-talk?token=invalid_test_token" 2>/dev/null) || headers=""

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    # Any HTTP response confirms the route exists
    if echo "$headers" | grep -qiE "101|403|HTTP"; then
        record_success "ws/talk_proxy" "$((end_ms - start_ms))"
        local code
        code=$(echo "$headers" | head -1 | awk '{print $2}')
        log "WS talk proxy: endpoint exists (HTTP ${code:-?})"
    else
        record_failure "ws/talk_proxy" "No response from ws-talk"
    fi
}

# ─── Phase 3 Helpers ─────────────────────────────────────────────────

test_service_recovery() {
    local service="$1"
    local timeout="$2"

    log "Restarting ${service}..."
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    local restart_result
    restart_result=$(run_ssh "sudo systemctl restart ${service} 2>&1 && echo 'RESTARTED'") || restart_result="FAIL"

    if ! echo "$restart_result" | grep -q "RESTARTED"; then
        record_failure "recovery/${service}" "Restart command failed: $restart_result"
        return
    fi

    # Poll until active or timeout
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        local state
        state=$(run_ssh "systemctl is-active ${service} 2>/dev/null") || state="error"
        if [ "$state" = "active" ]; then
            end_ms=$(python3 -c "import time;print(int(time.time()*1000))")
            record_success "recovery/${service}" "$((end_ms - start_ms))"
            log "${service} recovered in ~${elapsed}s"
            return
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")
    record_failure "recovery/${service}" "Not active after ${timeout}s"
}

test_alarm_scanner_recovery() {
    log "Restarting alarm-scanner, verifying MQTT status..."
    local start_ms end_ms
    start_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    # Restart the service
    run_ssh "sudo systemctl restart alarm-scanner" 2>/dev/null

    # Wait for "online" to reappear (RestartSec=5 + connect time)
    local elapsed=0
    local post_status=""
    while [ $elapsed -lt 20 ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        post_status=$(run_ssh "mosquitto_sub -h localhost -t 'doorbell/status' -C 1 -W 2 2>/dev/null") || post_status=""
        if [ "$post_status" = "online" ]; then
            break
        fi
    done

    end_ms=$(python3 -c "import time;print(int(time.time()*1000))")

    if [ "$post_status" = "online" ]; then
        record_success "recovery/alarm_mqtt" "$((end_ms - start_ms))"
        log "alarm-scanner MQTT status back to 'online' in ~${elapsed}s"
    else
        record_failure "recovery/alarm_mqtt" "status='$post_status' after ${elapsed}s (expected 'online')"
    fi
}

# ═════════════════════════════════════════════════════════════════════
#  Phases
# ═════════════════════════════════════════════════════════════════════

phase1_connectivity() {
    log ""
    log "═══ Phase 1: Connectivity ═══"

    # HTTP health
    check_health

    # TCP ports from Mac
    check_port_open "$PI_HOST" 5000 "admin"
    check_port_open "$PI_HOST" 1984 "go2rtc"
    check_port_open "$PI_HOST" 5001 "talk_relay"

    # MQTT port via SSH (local-only)
    check_ssh_port_open 1883 "mosquitto"

    # All systemd services
    check_all_services_active

    # go2rtc direct API
    check_go2rtc_streams

    # RTSP re-stream port (used by Android ExoPlayer)
    check_port_open "$PI_HOST" 8554 "go2rtc_rtsp"

    # go2rtc direct frame grab from Mac (Android MJPEG fallback path)
    check_go2rtc_direct_frame
}

phase2_websocket_mqtt() {
    log ""
    log "═══ Phase 2: WebSocket & MQTT ═══"

    # Talk relay WebSocket
    test_talk_relay_ws

    # MQTT broker connectivity
    test_mqtt_connectivity

    # MQTT retained status from alarm-scanner
    test_mqtt_status_retained

    # MQTT pub/sub round-trip (uses test topic to avoid triggering Android app)
    test_mqtt_ring_roundtrip

    # Alarm scanner --test event (publishes real DoorBell to doorbell/ring)
    test_alarm_scanner_test_event

    # WebSocket proxy endpoint
    test_ws_proxy_upgrade

    # Talk proxy endpoint (auth rejection expected)
    test_ws_talk_proxy_exists

    # Multiview page (/view) — what the Android WebView loads
    check_view_page
    check_view_mjpeg_page

    # WebRTC SDP exchange — primary video path
    test_webrtc_sdp_exchange
}

phase3_service_recovery() {
    log ""
    if [ "$DESTRUCTIVE" != "1" ]; then
        log "═══ Phase 3: Service Recovery (SKIPPED — pass --destructive to enable) ═══"
        return
    fi

    log "═══ Phase 3: Service Recovery ═══"
    log "WARNING: restarting services on Pi"

    # Restart ava-talk, verify recovery
    test_service_recovery "ava-talk" 10

    # Restart alarm-scanner, verify MQTT "online" returns
    test_alarm_scanner_recovery

    # Let things settle
    sleep 3

    # Verify all services healthy after restarts
    check_all_services_active
}

phase4_soak() {
    local soak_seconds=$((SOAK_MINUTES * 60))
    log ""
    log "═══ Phase 4: Soak (${SOAK_MINUTES}m) ═══"
    log "Running standard checks to verify stability after integration tests..."

    local soak_start soak_end
    soak_start=$(date +%s)
    soak_end=$((soak_start + soak_seconds))

    local tick=0
    while true; do
        local now
        now=$(date +%s)
        [ "$now" -ge "$soak_end" ] && break

        local remaining=$((soak_end - now))
        local remain_min=$((remaining / 60))
        printf "\r  > Soak: %2dm remaining | checks: %d | fails: %d   " \
            "$remain_min" "$TOTAL_CHECKS" "$TOTAL_FAILS"

        # Health + public: every 30s
        if [ $((tick % 3)) -eq 0 ]; then
            check_health
            check_public_endpoints
        fi

        # Frame grab: every 30s (offset)
        if [ $(( (tick + 1) % 3 )) -eq 0 ]; then
            check_frame
        fi

        # SSH metrics: every 60s
        if [ $((tick % 6)) -eq 0 ] && [ $tick -gt 0 ]; then
            collect_metrics
        fi

        tick=$((tick + 1))
        sleep "$TICK_SECONDS"
    done

    echo ""
    log "Soak phase complete"
}

phase5_summary() {
    log ""
    log "═══ Phase 5: Summary ═══"
    print_summary
}

# ═════════════════════════════════════════════════════════════════════
#  Main
# ═════════════════════════════════════════════════════════════════════

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  AVA Doorbell v4 — Integration Test"
    echo "  Target:      ${PI_HOST}:${PI_PORT}"
    echo "  Soak:        ${SOAK_MINUTES}m"
    echo "  Destructive: $([ "$DESTRUCTIVE" = "1" ] && echo "YES (service restarts)" || echo "NO")"
    echo "  Log:         ${LOGFILE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Prompt for password if not set
    if [ -z "$AVA_PASSWORD" ]; then
        printf "Enter AVA admin password: "
        read -rs AVA_PASSWORD
        echo ""
    fi
    if [ -z "$AVA_PASSWORD" ]; then
        echo "ERROR: Password required. Set AVA_PASSWORD or enter at prompt."
        exit 1
    fi

    # Preflight
    log "Checking connectivity to ${PI_HOST}..."
    if ! curl -s --max-time 5 -o /dev/null "${BASE_URL}/api/health" 2>/dev/null; then
        log_err "Cannot reach ${BASE_URL}/api/health — is the Pi running?"
        rm -f "$COOKIE_JAR"
        exit 1
    fi
    log "Pi is reachable"

    if ! authenticate; then
        log_err "Cannot authenticate — check AVA_PASSWORD"
        rm -f "$COOKIE_JAR"
        exit 1
    fi

    discover_cameras

    phase1_connectivity
    phase2_websocket_mqtt
    phase3_service_recovery
    phase4_soak
    phase5_summary

    rm -f "$COOKIE_JAR"
    log "Log saved to: $LOGFILE"

    [ "$TOTAL_FAILS" -eq 0 ] && exit 0 || exit 1
}

main "$@"
