#!/usr/bin/env bash
# sentinel.sh — the state machine behind "shipmate speaks first".
#
# bin/sentinel.sh probes every live project on a timer (site answers, latest deploy, TLS cert)
# and feeds each result through sentinel_step. A problem has to be seen on CONFIRM checks in a
# row before it is announced, it is announced once, and the recovery is announced once — so a
# flaky probe never becomes a stream of pushes. The sentinel only observes: nothing here
# changes a project, and any fix it suggests goes through the same gate as everything else.
#
# State: one file per <project>.<check> under ~/.shipmate/sentinel (SHIPMATE_SENTINEL_DIR):
#   state|bad-count|since-epoch|short label|detail
# Transitions are appended to ~/.shipmate/sentinel.jsonl (SHIPMATE_SENTINEL_LOG). That file is
# separate from the decision ledger on purpose: the ledger counts what the gates decided; this
# counts what the world did.
#
#   sentinel_step <key> <ok|bad|skip> [short] [detail] [confirm=2]
#     prints "open" when a problem is confirmed, "clear <seconds it lasted>" when it ends,
#     nothing otherwise. skip = no verdict this round (a deploy still building): state is kept.
#   sentinel_open — one line per open problem: key|since|short|detail
SENTINEL_DIR="${SHIPMATE_SENTINEL_DIR:-$HOME/.shipmate/sentinel}"
SENTINEL_LOG="${SHIPMATE_SENTINEL_LOG:-$HOME/.shipmate/sentinel.jsonl}"

sentinel_now() { printf '%s' "${SENTINEL_NOW:-$(date +%s)}"; }

sentinel_clean() { printf '%s' "${1:-}" | tr '|\t\n\r' '/   ' | cut -c1-200; }

sentinel_str() { printf '"%s"' "$(printf '%s' "${1:-}" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | cut -c1-300)"; }

sentinel_log() { # <key> <open|clear> <detail>
  mkdir -p "$(dirname "$SENTINEL_LOG")" 2>/dev/null || return 0
  printf '{"ts":"%s","type":"observation","project":%s,"check":%s,"outcome":"%s","detail":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sentinel_str "${1%.*}")" "$(sentinel_str "${1##*.}")" "$2" "$(sentinel_str "$3")" >> "$SENTINEL_LOG" 2>/dev/null || true
  chmod 600 "$SENTINEL_LOG" 2>/dev/null || true
}

sentinel_step() {
  local key="$1" verdict="$2" short dtl confirm="${5:-2}" file state=ok count=0 since=0 oshort="" odtl="" now
  short="$(sentinel_clean "${3:-}")"; dtl="$(sentinel_clean "${4:-}")"
  case "$key" in ''|*/*|.*) return 1 ;; esac
  mkdir -p "$SENTINEL_DIR" 2>/dev/null || return 0
  file="$SENTINEL_DIR/$key"; now="$(sentinel_now)"
  if [ -f "$file" ]; then IFS='|' read -r state count since oshort odtl < "$file" || true; fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  case "$verdict" in
    skip) return 0 ;;
    ok)
      if [ "$state" = open ]; then
        printf 'ok|0|%s||\n' "$now" > "$file"; sentinel_log "$key" clear "$odtl"
        printf 'clear %s\n' "$((now - since))"
      elif [ "$count" != 0 ] || [ ! -f "$file" ]; then printf 'ok|0|%s||\n' "$now" > "$file"; fi ;;
    bad)
      if [ "$state" = open ]; then  # still down: keep the original start, refresh what we saw
        printf 'open|%s|%s|%s|%s\n' "$((count + 1))" "$since" "$short" "$dtl" > "$file"; return 0
      fi
      [ "$count" = 0 ] && since="$now"   # the first bad sighting is when it started
      count=$((count + 1))
      if [ "$count" -ge "$confirm" ]; then
        printf 'open|%s|%s|%s|%s\n' "$count" "$since" "$short" "$dtl" > "$file"; sentinel_log "$key" open "$dtl"
        printf 'open\n'
      else printf 'ok|%s|%s|%s|%s\n' "$count" "$since" "$short" "$dtl" > "$file"; fi ;;
    *) return 1 ;;
  esac
}

sentinel_open() {
  local f state count since short dtl
  for f in "$SENTINEL_DIR"/*; do
    [ -f "$f" ] || continue
    IFS='|' read -r state count since short dtl < "$f" || true
    [ "$state" = open ] && printf '%s|%s|%s|%s\n' "$(basename "$f")" "$since" "$short" "$dtl"
  done
  return 0
}

sentinel_ago() { # <seconds> → "4 min" / "2 h" / "3 days"
  local s="${1:-0}"
  if [ "$s" -lt 90 ]; then printf '1 min'
  elif [ "$s" -lt 5400 ]; then printf '%s min' "$(( (s + 30) / 60 ))"
  elif [ "$s" -lt 129600 ]; then printf '%s h' "$(( (s + 1800) / 3600 ))"
  else printf '%s days' "$(( (s + 43200) / 86400 ))"; fi
}
