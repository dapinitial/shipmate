#!/usr/bin/env bash
# Tests for the security-critical env classification + overlay merge (skills/deploy/lib/envspec.sh).
# A bug here could ship a secret as plaintext — so this is the most important test in the repo.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../skills/deploy/lib/envspec.sh"

pass=0; fail=0
# type of a given key in the emitted block
type_of() { printf '%s' "$1" | awk -v k="$2" '$0 ~ ("- key: " k "$"){f=1} f&&/type:/{print $2; exit}'; }
val_of()  { printf '%s' "$1" | awk -v k="$2" '$0 ~ ("- key: " k "$"){f=1} f&&/value:/{sub(/^[[:space:]]*value: /,""); print; exit}'; }
ok()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3]"; fail=$((fail+1)); fi; }
hasnt(){ if printf '%s' "$2" | grep -qF "$3"; then echo "  ✗ $1: should not contain [$3]"; fail=$((fail+1)); else pass=$((pass+1)); fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/.env.local" <<'EOF'
# a comment line
NEXT_PUBLIC_URL=https://x.supabase.co
PUBLIC_THING=okay
SUPABASE_SECRET_KEY=sb_secret_abc123
RESEND_API_KEY=re_def456
EMPTY_VAR=
WITH_COMMENT=keepme # drop this
QUOTED="quoted value"
SITE=https://dev.example.com
EOF
cat > "$tmp/.env.production" <<'EOF'
SITE=https://prod.example.com
EOF

out="$(emit_envs "$tmp/.env.local" "$tmp/.env.production")"

echo "classification (safe-by-default):"
ok "NEXT_PUBLIC_URL is GENERAL"   "$(type_of "$out" NEXT_PUBLIC_URL)"     GENERAL
ok "PUBLIC_THING is GENERAL"      "$(type_of "$out" PUBLIC_THING)"        GENERAL
ok "SUPABASE_SECRET_KEY is SECRET" "$(type_of "$out" SUPABASE_SECRET_KEY)" SECRET
ok "RESEND_API_KEY is SECRET"     "$(type_of "$out" RESEND_API_KEY)"      SECRET

echo "hygiene:"
hasnt "empty values skipped" "$out" "EMPTY_VAR"
has   "inline comment stripped" "$(val_of "$out" WITH_COMMENT)" "keepme"
hasnt "inline comment stripped (no 'drop')" "$(val_of "$out" WITH_COMMENT)" "drop"
has   "quotes stripped" "$(val_of "$out" QUOTED)" "quoted value"

echo "overlay (.env.production overrides .env.local):"
has "SITE = prod value" "$(val_of "$out" SITE)" "prod.example.com"
hasnt "SITE not the dev value" "$(val_of "$out" SITE)" "dev.example.com"

echo "empty input → empty block (no bare 'envs:'):"
ok "no env files → nothing" "$(emit_envs "$tmp/nope1" "$tmp/nope2")" ""

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
