#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# log_tail.sh — Stream AVA Doorbell service logs from Pi
#
# Usage:
#   bash log_tail.sh                   # all services
#   bash log_tail.sh ava-admin         # single service
#   bash log_tail.sh ava-talk          # talk relay only
#   PI_HOST=100.x.y.z bash log_tail.sh # via Tailscale
#
# Environment variables:
#   PI_HOST     Pi IP address (default: 10.10.10.167)
#   SSH_USER    SSH username (default: pi)
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

PI_HOST="${PI_HOST:-10.10.10.167}"
SSH_USER="${SSH_USER:-pi}"
SERVICE="${1:-}"

ALL_UNITS="-u go2rtc -u alarm-scanner -u ava-talk -u ava-admin -u mosquitto"

if [ -n "$SERVICE" ]; then
    case "$SERVICE" in
        go2rtc|alarm-scanner|ava-talk|ava-admin|mosquitto|smbd)
            ALL_UNITS="-u $SERVICE"
            ;;
        *)
            echo "Unknown service: $SERVICE"
            echo "Valid: go2rtc, alarm-scanner, ava-talk, ava-admin, mosquitto, smbd"
            exit 1
            ;;
    esac
fi

echo "Streaming logs from ${SSH_USER}@${PI_HOST} (${SERVICE:-all services})..."
echo "Press Ctrl+C to stop"
echo ""

ssh "${SSH_USER}@${PI_HOST}" "sudo journalctl ${ALL_UNITS} -f --output=short-iso --no-hostname"
