#!/usr/bin/env bash
# request-approval.sh — out-of-band tap-to-confirm for billable/irreversible steps.
#
# Usage: request-approval.sh "<one-line description with the monthly cost>" [timeout-seconds]
#
# Sends a push notification (ntfy) with Approve / Deny buttons. The buttons hit the
# tailnet-only onboarding server (port 8790) — so only a device on YOUR tailnet can approve,
# even if someone else can read the notification topic. Blocks until a tap or timeout
# (default 300s) and prints exactly one word on stdout:
#   APPROVED   → proceed
#   DENIED     → stop
#   TIMEOUT    → stop (nobody tapped)
# Exit code is 0 only for APPROVED, so `request-approval.sh "..." && <the billable step>`
# is the natural calling shape.
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,15p' "$0"; exit 0;; esac

DESC="$1"
TIMEOUT="${2:-300}"
APPROVALS="${SHIPMATE_APPROVALS_DIR:-$HOME/.shipmate/approvals}"
PORT="${SHIPMATE_ONBOARD_PORT:-8790}"

# Optional config (ntfy topic lives here)
if [ -f "$HOME/.shipmate/voice.env" ]; then . "$HOME/.shipmate/voice.env"; fi
if [ -z "${SHIPMATE_NTFY_TOPIC:-}" ]; then
  echo "TIMEOUT"
  echo "✗ SHIPMATE_NTFY_TOPIC not set — cannot request approval, treat as not approved." >&2
  exit 1
fi

# The tailnet address the buttons will call — from the interfaces (100.64.0.0/10).
TSIP="$(ifconfig 2>/dev/null | awk '$1=="inet" && $2 ~ /^100\./ {split($2,o,"."); if (o[2]>=64 && o[2]<=127) {print $2; exit}}')"
if [ -z "$TSIP" ]; then
  echo "TIMEOUT"
  echo "✗ no Tailscale address on this host — approval buttons would have nowhere to go." >&2
  exit 1
fi

NONCE="$(openssl rand -hex 12 2>/dev/null || date +%s%N)"
mkdir -p "$APPROVALS"
printf 'pending %s\n%s\n' "$(date +%s)" "$DESC" > "$APPROVALS/$NONCE"
chmod 600 "$APPROVALS/$NONCE"

curl -fsS -m 10 \
  -H "Title: shipmate needs a decision" \
  -H "Priority: high" \
  -H "Actions: http, ✅ Approve, http://$TSIP:$PORT/approve/$NONCE, method=POST, clear=true; http, ❌ Deny, http://$TSIP:$PORT/deny/$NONCE, method=POST, clear=true" \
  -d "$DESC" \
  "${SHIPMATE_NTFY_URL:-https://ntfy.sh}/$SHIPMATE_NTFY_TOPIC" >/dev/null 2>&1 || {
    echo "TIMEOUT"
    echo "✗ could not send the ntfy notification — treat as not approved." >&2
    exit 1
  }

WAITED=0
while [ "$WAITED" -lt "$TIMEOUT" ]; do
  STATE="$(awk 'NR==1{print $1}' "$APPROVALS/$NONCE" 2>/dev/null || echo missing)"
  case "$STATE" in
    approved) echo "APPROVED"; exit 0 ;;
    denied)   echo "DENIED";   exit 1 ;;
  esac
  sleep 5; WAITED=$((WAITED + 5))
done
echo "TIMEOUT"
exit 1
