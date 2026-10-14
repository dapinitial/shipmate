#!/usr/bin/env bash
# ledger.sh — the append-only record of what shipmate's gates decided.
#
# Every decision that stands between a request and production writes one JSON line to
# ~/.shipmate/ledger.jsonl (SHIPMATE_LEDGER overrides): the policy that acted, the outcome,
# the project, what was attempted, the channel it came from, and the facts behind it.
# Allowed actions are recorded too: a count of catches means nothing without the count of
# attempts. The ledger records facts only. Whether a catch prevented real harm is a human
# judgment, added later as a separate "note" line (bin/ledger.sh annotate), never inferred.
#
#   ledger_record <policy> <outcome> <project> <attempted> [detail]
#     policy   plan-grant | preflight | pre-push:<rule> | approval | verify-live | scope | ship
#     outcome  executed | downgraded | refused | approved | denied | timeout | live | failed | warned
#   prints the new record's id
LEDGER_FILE="${SHIPMATE_LEDGER:-$HOME/.shipmate/ledger.jsonl}"

ledger_json_str() { # <text> → a JSON string literal (bash 3.2 + sed; no JSON tool needed)
  printf '"%s"' "$(printf '%s' "${1:-}" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | cut -c1-400)"
}

ledger_channel() { # where the request came from, unless the caller said
  if [ -n "${SHIPMATE_CHANNEL:-}" ]; then printf '%s' "$SHIPMATE_CHANNEL"
  elif [ -n "${SSH_CONNECTION:-}" ]; then printf 'siri'
  else printf 'terminal'; fi
}

ledger_record() {
  local id
  id="$(date +%Y%m%d%H%M%S)-$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null || return 0
  {
    printf '{"id":"%s","ts":"%s","type":"decision",' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '"policy":%s,"outcome":%s,"project":%s,' "$(ledger_json_str "$1")" "$(ledger_json_str "$2")" "$(ledger_json_str "$3")"
    printf '"attempted":%s,"channel":%s,"detail":%s}\n' "$(ledger_json_str "$4")" \
      "$(ledger_json_str "$(ledger_channel)")" "$(ledger_json_str "${5:-}")"
  } >> "$LEDGER_FILE" 2>/dev/null || true
  chmod 600 "$LEDGER_FILE" 2>/dev/null || true
  printf '%s' "$id"
}
