#!/usr/bin/env bash
# gate.sh — the plan→execute grant, shared by every mouth (Siri bridge, MCP server, terminal).
#
# A plan turn mints a single-use grant for one project; an execute turn may only proceed by
# consuming a grant for the same project that is younger than the TTL. Without one, the
# bridge downgrades the turn to a plan, reads it back, and mints a grant — so the sentence that
# actually changes production is always the second one ("ship it"), never a first, possibly
# garbled, utterance. Authority lives in this file, not in the conversation.
#
# File format is the MCP server's: {"project":"<name>","ts":<ms>} plus an optional
# "nonce" the Ship-it push button carries. Pure bash 3.2 + sed; no JSON tool needed.
GATE_FILE="${SHIPMATE_PLAN_GRANT:-$HOME/.shipmate/mcp/plan-grant.json}"
GATE_TTL="${SHIPMATE_PLAN_TTL:-600}"   # seconds

gate_field() { # <key> — a string or number field from the grant file, else empty
  sed -nE "s/.*\"$1\":[[:space:]]*\"?([^\",}]*)\"?.*/\1/p" "$GATE_FILE" 2>/dev/null | head -1
}

gate_mint() { # <project-name> — write a fresh grant (overwrites any older one); prints the nonce
  local nonce
  nonce="$(openssl rand -hex 12 2>/dev/null || printf '%s%s' "$(date +%s)" "$$")"
  mkdir -p "$(dirname "$GATE_FILE")"
  printf '{"project":"%s","ts":%s000,"nonce":"%s"}\n' "$1" "$(date +%s)" "$nonce" > "$GATE_FILE"
  chmod 600 "$GATE_FILE" 2>/dev/null || true
  printf '%s' "$nonce"
}

gate_peek() { # <project-name> — prints "ok <nonce> <seconds-left>" (exit 0) or a reason (exit 1):
              #   none | expired | other <project>      — never consumes the grant
  local p ts now age
  [ -f "$GATE_FILE" ] || { printf 'none'; return 1; }
  p="$(gate_field project)"; ts="$(gate_field ts)"
  case "$ts" in ''|*[!0-9]*) printf 'none'; return 1 ;; esac
  now="$(date +%s)"; age=$(( now - ts / 1000 ))
  if [ "$age" -gt "$GATE_TTL" ] || [ "$age" -lt 0 ]; then printf 'expired'; return 1; fi
  if [ "${p:--}" != "${1:--}" ]; then printf 'other %s' "$p"; return 1; fi
  printf 'ok %s %s' "$(gate_field nonce)" $(( GATE_TTL - age ))
}

gate_take() { # <project-name> — consume a valid grant (exit 0) or print the reason (exit 1)
  local r
  if r="$(gate_peek "$1")"; then rm -f "$GATE_FILE"; return 0; fi
  printf '%s' "$r"; return 1
}

gate_nonce_valid() { # <nonce> — exit 0 when the grant exists, is unexpired and carries this nonce
  local r
  r="$(gate_peek "$(gate_field project)")" || return 1
  [ -n "$1" ] && [ "$(gate_field nonce)" = "$1" ]
}

gate_reason_spoken() { # <reason from gate_peek/take> <project-name> — one spoken sentence
  case "$1" in
    none)     printf "There's no plan on file for %s, so that was the plan." "$2" ;;
    expired)  printf "The last plan for %s is older than %s minutes, so I planned again." "$2" $(( GATE_TTL / 60 )) ;;
    other\ *) printf "The last plan was for %s, not %s, so I planned this instead." "${1#other }" "$2" ;;
    *)        printf "No live plan, so that was the plan." ;;
  esac
}
