#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# burn_in.sh — AVA Doorbell v4 Multi-Hour Burn-In Test
#
# Exercises all Pi services from the Mac via HTTP and SSH.
# Read-only: never modifies Pi state.
# Bash 3.2 compatible (macOS default — no associative arrays).
#
# Usage:
#   AVA_PASSWORD=<pass> bash burn_in.sh
#
# Environment variables:
#   AVA_PASSWORD    Admin password (prompted if not set)
#   DURATION_HOURS  Test duration in hours (default: 2)
#   PI_HOST         Pi IP address (default: 10.10.10.167)
#   PI_PORT         Admin port (default: 5000)
#   SSH_USER        SSH username (default: pi)
#   SSH_PASS        SSH password (omit to use SSH keys)
# ─────────────────────────────────────────────────────────────────────

# ─── Configuration ───────────────────────────────────────────────────
PI_HOST="${PI_HOST:-10.10.10.167}"
PI_PORT="${PI_PORT:-5000}"
BASE_URL="http://${PI_HOST}:${PI_PORT}"
DURATION_HOURS="${DURATION_HOURS:-2}"
SSH_USER="${SSH_USER:-pi}"
SSH_PASS="${SSH_PASS:-}"
AVA_PASSWORD="${AVA_PASSWORD:-}"
TICK_SECONDS=10

# ─── Derived ─────────────────────────────────────────────────────────
DURATION_SECONDS=$(python3 -c "print(int(${DURATION_HOURS} * 3600))")
COOKIE_JAR=$(mktemp /tmp/burn_in_cookies.XXXXXX)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="${SCRIPT_DIR}/burn_in_$(date +%Y%m%d_%H%M%S).log"
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SECONDS))

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

# Extract a dotted key path from JSON on stdin
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

# Extract a field from each element of a JSON array on stdin
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
    tmp=$(mktemp /tmp/burn_curl.XXXXXX)

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

# Try re-auth on 401/307; returns 0 if re-authed (caller should retry)
try_reauth() {
    if [ "$CURL_CODE" = "401" ] || [ "$CURL_CODE" = "307" ]; then
        log "Session expired (HTTP $CURL_CODE), re-authenticating..."
        authenticate && return 0
    fi
    return 1
}

# ─── Checks ──────────────────────────────────────────────────────────

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

        # Parse service statuses, detect state transitions
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
        # No frame available yet — not an error
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

    # Memory (free -m: Mem: total used free shared buff/cache available)
    local mem_used mem_total
    mem_total=$(echo "$output" | head -1 | awk '{print $2}')
    mem_used=$(echo "$output" | head -1 | awk '{print $3}')
    [ -z "$FIRST_MEM_USED" ] && [ -n "$mem_used" ] && FIRST_MEM_USED="$mem_used"
    [ -n "$mem_used" ] && LAST_MEM_USED="$mem_used"

    # Temperature
    local temp
    temp=$(echo "$output" | grep "temp=" | grep -o '[0-9]*\.[0-9]*' | head -1)

    # Disk
    local disk_pct
    disk_pct=$(echo "$output" | grep -E "^/dev" | awk '{print $5}')

    # Load average
    local load_avg
    load_avg=$(echo "$output" | tail -1 | awk '{print $1, $2, $3}')

    log "Metrics: mem=${mem_used:-?}/${mem_total:-?}MB  temp=${temp:-?}C  disk=${disk_pct:-?}  load=${load_avg:-?}"
}

check_auth_endpoints() {
    local ep ep_name
    for ep in "/api/services" "/api/config/full" "/api/cameras" "/api/smb/status" "/api/logs?service=all&lines=10"; do
        ep_name=$(echo "$ep" | sed 's|/api/||;s|?.*||')

        do_curl "$ep"

        # Re-auth on session expiry, then retry once
        if [ "$CURL_CODE" = "401" ] || [ "$CURL_CODE" = "307" ]; then
            log "Session expired at auth/$ep_name, re-authenticating..."
            authenticate && do_curl "$ep"
        fi

        if [ "$CURL_CODE" = "200" ]; then
            record_success "auth/$ep_name" "$CURL_MS"
        else
            record_failure "auth/$ep_name" "HTTP $CURL_CODE"
        fi
    done
}

scan_logs_for_errors() {
    do_curl "/api/logs?service=all&lines=100"
    if [ "$CURL_CODE" = "401" ] || [ "$CURL_CODE" = "307" ]; then
        authenticate && do_curl "/api/logs?service=all&lines=100"
    fi

    if [ "$CURL_CODE" = "200" ]; then
        record_success "log-scan" "$CURL_MS"

        local err_count
        err_count=$(echo "$CURL_BODY" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    lines=d.get('lines',[]) if isinstance(d,dict) else (d if isinstance(d,list) else [])
    count=0
    for line in lines:
        text=line if isinstance(line,str) else str(line)
        for pat in ['ERROR','CRITICAL','Traceback']:
            if pat in text:
                count+=1; break
    print(count)
except: print(0)" 2>/dev/null)

        if [ "${err_count:-0}" -gt 0 ]; then
            log "Log scan: $err_count error line(s) in recent logs"
        fi
    else
        record_failure "log-scan" "HTTP $CURL_CODE"
    fi
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
        echo "                     AVA BURN-IN TEST SUMMARY"
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
        printf "  %-22s %6s %6s %6s %7s %7s %7s\n" \
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

            printf "  %-22s %6d %5d%1s %6d %7s %7d %7d\n" \
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
    log "Burn-in test interrupted — generating summary..."
    print_summary
    rm -f "$COOKIE_JAR"
    log "Log saved to: $LOGFILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

# ─── Main ────────────────────────────────────────────────────────────

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  AVA Doorbell v4 — Burn-In Test"
    echo "  Target:   ${PI_HOST}:${PI_PORT}"
    echo "  Duration: ${DURATION_HOURS}h (${DURATION_SECONDS}s)"
    echo "  Log:      ${LOGFILE}"
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

    # Preflight: check connectivity
    log "Checking connectivity to ${PI_HOST}..."
    if ! curl -s --max-time 5 -o /dev/null "${BASE_URL}/api/health" 2>/dev/null; then
        log_err "Cannot reach ${BASE_URL}/api/health — is the Pi running?"
        rm -f "$COOKIE_JAR"
        exit 1
    fi
    log "Pi is reachable"

    # Authenticate
    if ! authenticate; then
        log_err "Cannot authenticate — check AVA_PASSWORD"
        rm -f "$COOKIE_JAR"
        exit 1
    fi

    # Discover cameras for frame rotation
    discover_cameras

    # Initial checks
    check_health
    collect_metrics

    log "Entering main loop (${DURATION_HOURS}h, tick=${TICK_SECONDS}s)..."
    echo ""

    local tick=0
    while true; do
        local now
        now=$(date +%s)
        [ "$now" -ge "$END_TIME" ] && break

        local remaining=$((END_TIME - now))
        local remain_min=$((remaining / 60))
        printf "\r  > %3dm remaining | checks: %d | fails: %d   " \
            "$remain_min" "$TOTAL_CHECKS" "$TOTAL_FAILS"

        # Health + public: every 30s (every 3 ticks)
        if [ $((tick % 3)) -eq 0 ]; then
            check_health
            check_public_endpoints
        fi

        # Frame grab: every 30s (offset by 1 tick)
        if [ $(( (tick + 1) % 3 )) -eq 0 ]; then
            check_frame
        fi

        # SSH metrics: every 60s (every 6 ticks)
        if [ $((tick % 6)) -eq 0 ] && [ $tick -gt 0 ]; then
            collect_metrics
        fi

        # Auth endpoints: every 5min (every 30 ticks)
        if [ $((tick % 30)) -eq 0 ] && [ $tick -gt 0 ]; then
            check_auth_endpoints
        fi

        # Log scan: every 5min (offset by 15 ticks)
        if [ $(( (tick + 15) % 30 )) -eq 0 ] && [ $tick -gt 0 ]; then
            scan_logs_for_errors
        fi

        tick=$((tick + 1))
        sleep "$TICK_SECONDS"
    done

    echo ""
    log "Burn-in test completed (${DURATION_HOURS}h)"
    print_summary
    rm -f "$COOKIE_JAR"
    log "Log saved to: $LOGFILE"

    # Exit code: 0 if no failures, 1 otherwise
    [ "$TOTAL_FAILS" -eq 0 ] && exit 0 || exit 1
}

main "$@"
