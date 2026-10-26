#!/usr/bin/env bash
# sentinel.sh — shipmate speaks first: probe every live project, print one line per change.
#
# Usage: sentinel.sh [--report] [sites-root]
#   (default)  run the checks once; print a ready-to-push sentence for each problem that just
#              opened or just cleared, nothing when nothing changed (the bridge's watchdog timer
#              runs this every 5 minutes and pushes each line)
#   --report   list open problems without probing anything
#
# Checks, for each git repo under sites-root (one or two levels) that has a deploy target:
#   site    the health_url in .shipmate.yml (else the provider's production URL) answers 2xx/3xx,
#           and contains expect_text when the project sets one — confirmed on 2 checks in a row
#   deploy  the newest production deployment did not fail — a building one is no verdict
#   cert    the site's TLS certificate is valid for more than SHIPMATE_CERT_DAYS (default 14)
# SHIPMATE_SENTINEL_CHECKS limits the set ("site deploy cert"). Observes only: it never deploys,
# rolls back or retries anything. A suggested fix is a phrase for the usual gate.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,17p' "$0"; exit 0;; esac
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LIB="$BIN/../lib"
. "$LIB/sentinel.sh"; . "$LIB/project.sh"; . "$LIB/provider.sh"
APPSH="${SHIPMATE_APP_SH:-$BIN/app.sh}"
CHECKS=" ${SHIPMATE_SENTINEL_CHECKS:-site deploy cert security} "
CERT_DAYS="${SHIPMATE_CERT_DAYS:-14}"
SECURITY_CHECK="${SHIPMATE_SECURITY_CHECK:-$HOME/.claude/skills/site-hardening/assets/check.mjs}"

if [ "${1:-}" = --report ]; then
  open="$(sentinel_open)"
  [ -z "$open" ] && { echo "sentinel: nothing open"; exit 0; }
  now="$(sentinel_now)"
  printf '%s\n' "$open" | while IFS='|' read -r key since short dtl; do
    echo "• ${key%.*}: $short for $(sentinel_ago "$((now - since))") — $dtl"
  done
  exit 0
fi
ROOT="${1:-${SHIPMATE_SITES_ROOT:-$HOME/Sites}}"

# One run at a time: a slow provider must not let two timer ticks race on the same state.
LOCK="$SENTINEL_DIR/.lock"; mkdir -p "$SENTINEL_DIR"
if ! mkdir "$LOCK" 2>/dev/null; then
  # a lock older than 15 minutes is a crashed run, not a live one
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

cert_days() { # <host> → days until the certificate expires, or "invalid: <reason>"
  python3 - "$1" <<'EOF' 2>/dev/null || echo "invalid: no answer on 443"
import socket, ssl, sys, time
h = sys.argv[1]
try:
    with socket.create_connection((h, 443), timeout=10) as s:
        with ssl.create_default_context().wrap_socket(s, server_hostname=h) as t:
            end = ssl.cert_time_to_seconds(t.getpeercert()['notAfter'])
    print(int((end - time.time()) // 86400))
except ssl.SSLCertVerificationError as e:
    print('invalid: ' + (e.verify_message or 'verification failed'))
except Exception as e:
    print('invalid: ' + type(e).__name__)
EOF
}

say() { printf '%s\n' "$1"; }

for d in "$ROOT"/*/ "$ROOT"/*/*/; do
  d="${d%/}"; [ -d "$d/.git" ] || continue
  [ "$(provider_of "$d")" != none ] || continue
  name="$(basename "$d")"; host_silent=""
  status="$(bash "$APPSH" status "$d" 2>/dev/null)"
  url="$(project_health_url "$d")"
  [ -n "$url" ] || url="$(printf '%s\n' "$status" | sed -nE 's/^url:[[:space:]]*//p' | head -1)"
  case "$url" in ''|'<nil>') url="" ;; http*) ;; *) url="https://$url" ;; esac

  if [ -n "$url" ] && [ "$CHECKS" != "${CHECKS#* site }" ]; then
    code="$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"; [ -n "$code" ] || code=000
    expect="$(project_expect_text "$d")"; verdict=ok; what=""
    case "$code" in
      2??|3??)
        if [ "$code" = 200 ] && [ -n "$expect" ] && ! curl -s -m 15 "$url" 2>/dev/null | grep -q -F -- "$expect"; then
          verdict=bad; what="answers 200 but without \"$expect\""
        fi ;;
      000) verdict=bad; what="doesn't answer" ;;
      *)   verdict=bad; what="answers HTTP $code" ;;
    esac
    t="$(sentinel_step "$name.site" "$verdict" down "$url $what")"
    case "$t" in
      open)   say "🔴 $name is down: $url $what, two checks in a row. If the last deploy caused it, say 'roll back $name, confirm'." ;;
      clear*) say "🟢 $name is back: $url answers again, after about $(sentinel_ago "${t#clear }")." ;;
    esac
    [ "$code" = 000 ] && host_silent=1
  fi

  if [ "$CHECKS" != "${CHECKS#* deploy }" ] && [ -n "$status" ]; then
    # vercel prints "latest:" (the newest production deployment, which may not be the one
    # serving); for DigitalOcean the "deploy:" line already is the newest.
    line="$(printf '%s\n' "$status" | sed -nE 's/^latest:[[:space:]]*//p' | head -1)"
    [ -n "$line" ] || line="$(printf '%s\n' "$status" | sed -nE 's/^deploy:[[:space:]]*//p' | head -1)"
    phase="$(printf '%s' "$line" | awk '{print $1}')"
    case "$phase" in
      ERROR|FAILED) verdict=bad ;;
      ACTIVE|READY|SUPERSEDED) verdict=ok ;;
      *) verdict=skip ;;                     # building, queued, canceled, unknown: no verdict yet
    esac
    case "$(sentinel_step "$name.deploy" "$verdict" "deploy failed" "$line" 1)" in
      open)   say "❌ $name: the latest deploy failed. Production stays on the previous version until a fix ships." ;;
      clear*) say "✅ $name deploys again: the latest deploy is live." ;;
    esac
  fi

  # security: the site-hardening skill's live check (headers, cross-site guard, dependencies,
  # mail records, embeds). Flags come from .shipmate.yml: security_form, security_resolve,
  # security_mail, security_embed. --limits is never run here: it spends the form's real caps.
  if [ -n "$url" ] && [ -z "$host_silent" ] && [ "$CHECKS" != "${CHECKS#* security }" ] && [ -f "$SECURITY_CHECK" ]; then
    set -- "$url" --json
    v="$(project_setting "$d" security_form "")";    [ -n "$v" ] && set -- "$@" --form "$v"
    v="$(project_setting "$d" security_resolve "")"; [ -n "$v" ] && set -- "$@" --resolve "$v"
    v="$(project_setting "$d" security_mail "")";    [ -n "$v" ] && set -- "$@" --mail "$v"
    v="$(project_setting "$d" security_embed "")";   [ -n "$v" ] && set -- "$@" --embed "$v"
    failing="$(node "$SECURITY_CHECK" "$@" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print("; ".join(r["check"]+" ("+str(r["detail"])[:60]+")" for r in d["results"] if not r["ok"] and not r["skipped"]))' 2>/dev/null)"
    if [ -n "$failing" ]; then verdict=bad; else verdict=ok; fi
    case "$(sentinel_step "$name.security" "$verdict" "security drift" "$failing" 2)" in
      open)   say "🛡️ $name drifted: $failing. Run the site-hardening audit on it." ;;
      clear*) say "🛡️ $name is back to baseline: the security check passes again." ;;
    esac
  fi

  case "$url" in https://*) host="${url#https://}"; host="${host%%/*}"; host="${host%%:*}" ;; *) host="" ;; esac
  # a site that doesn't answer at all is one problem, not also a certificate problem
  if [ -n "$host" ] && [ -z "$host_silent" ] && [ "$CHECKS" != "${CHECKS#* cert }" ]; then
    days="$(cert_days "$host")"
    case "$days" in
      invalid*) verdict=bad; short="cert invalid"; what="$host's certificate is ${days#invalid: }" ;;
      ''|*[!0-9-]*) verdict=skip ;;
      *) if [ "$days" -lt "$CERT_DAYS" ]; then verdict=bad; short="cert ${days}d"; what="$host's certificate expires in $days days"
         else verdict=ok; fi ;;
    esac
    [ "$verdict" = skip ] || case "$(sentinel_step "$name.cert" "$verdict" "${short:-}" "${what:-}" 2)" in
      open)   say "🔒 $name: $what. The host renews it automatically, so renewal may be stuck." ;;
      clear*) say "🔒 $name: $host's certificate is valid again." ;;
    esac
  fi
done
# The heartbeat: a check's own file only changes when its verdict does, so "when did the sentinel
# last look" lives here (the briefing reads it before calling a night quiet).
: > "$SENTINEL_DIR/.last-run"
exit 0
