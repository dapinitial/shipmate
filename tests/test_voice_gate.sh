#!/usr/bin/env bash
# Tests for voice/lib/gate.sh — the plan→execute grant. A bug here either lets a garbled first
# utterance change production (grant too loose) or makes "ship it" a dead phrase (too tight).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"; trap 'rm -rf "$TMP"' EXIT
export SHIPMATE_PLAN_GRANT="$TMP/state/plan-grant.json"
export SHIPMATE_PLAN_TTL=600
. "$DIR/../voice/lib/gate.sh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }

echo "no plan:"
ok "peek none"      "$(gate_peek unakin)"            none
ok "take fails"     "$(gate_take unakin >/dev/null; echo $?)" 1
ok "take reason"    "$(gate_take unakin)"            none

echo "mint + take:"
n="$(gate_mint unakin)"
ok "nonce is hex"        "$(printf '%s' "$n" | grep -cE '^[0-9a-f]{16,}$')" 1
ok "file mode 600"       "$(stat -f %Lp "$SHIPMATE_PLAN_GRANT" 2>/dev/null || stat -c %a "$SHIPMATE_PLAN_GRANT")" 600
ok "peek ok + nonce"     "$(gate_peek unakin | awk '{print $1, $2}')" "ok $n"
left="$(gate_peek unakin | awk '{print $3}')"
ok "seconds left ≈ ttl"  "$([ "$left" -le 600 ] && [ "$left" -ge 598 ] && echo yes)" yes
ok "other project"       "$(gate_peek panogram)"     "other unakin"
ok "take other fails"    "$(gate_take panogram >/dev/null; echo $?)" 1
ok "grant survives a wrong-project take" "$([ -f "$SHIPMATE_PLAN_GRANT" ] && echo kept)" kept
ok "take same succeeds"  "$(gate_take unakin >/dev/null; echo $?)" 0
ok "single use"          "$(gate_take unakin)"       none

echo "expiry:"
gate_mint unakin >/dev/null
# age the grant: rewrite ts to 11 minutes ago (ms, like the MCP server writes it)
old=$(( ($(date +%s) - 660) * 1000 ))
sed -i.bak -E "s/\"ts\":[0-9]+/\"ts\":$old/" "$SHIPMATE_PLAN_GRANT" && rm -f "$SHIPMATE_PLAN_GRANT.bak"
ok "expired peek"        "$(gate_peek unakin)"       expired
ok "expired take fails"  "$(gate_take unakin >/dev/null; echo $?)" 1
ok "ttl is configurable" "$(SHIPMATE_PLAN_TTL=1200 GATE_TTL=1200 gate_peek unakin | awk '{print $1}')" ok

echo "MCP-format file (no nonce, JSON.stringify spacing):"
printf '{"project":"spacelabstudio","ts":%s}' "$(( $(date +%s) * 1000 ))" > "$SHIPMATE_PLAN_GRANT"
ok "reads mcp grant"     "$(gate_peek spacelabstudio | awk '{print $1}')" ok
ok "no nonce → empty"    "$(gate_peek spacelabstudio | awk '{print NF}')" 2
ok "nonce_valid false"   "$(gate_nonce_valid abc >/dev/null; echo $?)" 1

echo "nonce validation:"
n="$(gate_mint unakin)"
ok "right nonce"   "$(gate_nonce_valid "$n"; echo $?)" 0
ok "wrong nonce"   "$(gate_nonce_valid deadbeefdeadbeefdeadbeef; echo $?)" 1
ok "empty nonce"   "$(gate_nonce_valid ""; echo $?)" 1

echo "spoken reasons:"
ok "none"     "$(gate_reason_spoken none unakin)"          "There's no plan on file for unakin, so that was the plan."
ok "expired"  "$(gate_reason_spoken expired unakin)"       "The last plan for unakin is older than 10 minutes, so I planned again."
ok "other"    "$(gate_reason_spoken 'other panogram' unakin)" "The last plan was for panogram, not unakin, so I planned this instead."

echo "garbage in the file:"
printf 'not json' > "$SHIPMATE_PLAN_GRANT"
ok "garbage → none" "$(gate_peek unakin)" none
printf '{"project":"unakin","ts":"soon"}' > "$SHIPMATE_PLAN_GRANT"
ok "non-numeric ts → none" "$(gate_peek unakin)" none

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
