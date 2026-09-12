#!/usr/bin/env bash
# Tests for skills/deploy/bin/deploy-card.sh — the block a session reads before it pushes, and
# the drift check that catches a stale app name or a push aimed at the wrong remote.
# Runs against throwaway git repos and a stub doctl on PATH; touches no real provider.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARD="$DIR/../skills/deploy/bin/deploy-card.sh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3] in:"; printf '%s\n' "$2" | sed 's/^/      /'; fail=$((fail+1)); fi; }
lacks() { if printf '%s' "$2" | grep -q -F -- "$3"; then echo "  ✗ $1: unexpected [$3]"; fail=$((fail+1)); else pass=$((pass+1)); fi; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"
trap 'rm -rf "$TMP"' EXIT

# --- stub doctl: two live apps; "good-app" deploys from acme/good, "moved-app" from acme/elsewhere
mkdir -p "$TMP/bin"
cat > "$TMP/bin/doctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "account get") exit 0 ;;
  "apps list --format ID,Spec.Name,DefaultIngress --no-header")
    printf '%s\n' "id-1 good-app https://good-app.ondigitalocean.app" "id-2 moved-app https://moved-app.ondigitalocean.app" ;;
  "apps spec get id-1") printf '%s\n' "name: good-app" "services:" "  - github:" "      repo: acme/good" "      branch: main" "      deploy_on_push: true" ;;
  "apps spec get id-2") printf '%s\n' "name: moved-app" "services:" "  - github:" "      repo: acme/elsewhere" "      deploy_on_push: true" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/doctl"
export PATH="$TMP/bin:$PATH"

mkrepo() { # <name> <origin-url> [app-name] [app-repo]
  local d="$TMP/sites/$1"; mkdir -p "$d"
  git -C "$d" init -q -b main 2>/dev/null || { git -C "$d" init -q; git -C "$d" checkout -q -b main; }
  git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$d" remote add origin "$2"
  if [ -n "${3:-}" ]; then mkdir -p "$d/.do"; printf 'name: %s\nservices:\n  - github:\n      repo: %s\n      branch: main\n' "$3" "${4:-$(printf '%s' "$2" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')}" > "$d/.do/app.yaml"; fi
  printf '%s' "$d"
}

echo "card content:"
G="$(mkrepo good git@github.com:acme/good.git good-app)"
out="$(bash "$CARD" "$G")"
has "opens with marker"      "$out" "shipmate:deploy-card"
has "branch + slug"          "$out" 'push to `main` on `origin` (`acme/good`)'
has "deploy_on_push noted"   "$out" "a push publishes"
has "live app + url"         "$out" 'DigitalOcean app: `good-app` · https://good-app.ondigitalocean.app'
has "voice rollback phrase"  "$out" '"roll back good, confirm"'
lacks "no mirror line"       "$out" "read-only mirrors"

echo "slug parsing:"
A="$(mkrepo alias git@github.com-work:acme/good.git good-app)"
has "ssh alias host"   "$(bash "$CARD" "$A")" '(`acme/good`)'
H="$(mkrepo https https://github.com/acme/good good-app)"
has "https no .git"    "$(bash "$CARD" "$H")" '(`acme/good`)'

echo "drift check:"
ok "consistent repo passes" "$(bash "$CARD" "$G" --check >/dev/null 2>&1; echo $?)" 0
S="$(mkrepo stale git@github.com:acme/stale.git ghost-app)"
out="$(bash "$CARD" "$S" --check 2>&1)"; ok "stale name fails" "$?" 1
has "stale name reason"  "$out" "no DigitalOcean app has that name"
has "stale name in card" "$(bash "$CARD" "$S")" "no live app by that name"
M="$(mkrepo moved git@github.com:acme/moved.git moved-app acme/moved)"
out="$(bash "$CARD" "$M" --check 2>&1)"; ok "wrong deploy repo fails" "$?" 1
has "wrong deploy repo reason" "$out" "deploys from 'acme/elsewhere' but origin is 'acme/moved'"
W="$(mkrepo wrongyaml git@github.com:acme/wrongyaml.git good-app acme/other)"
out="$(bash "$CARD" "$W" --check 2>&1)"
has "yaml repo mismatch" "$out" "github.repo is 'acme/other' but origin is 'acme/wrongyaml'"

echo "multiple remotes:"
T="$(mkrepo two git@github.com:acme/good.git good-app)"
git -C "$T" remote add mirror git@github.com:me/two.git
out="$(bash "$CARD" "$T" --check 2>&1)"; ok "two remotes, no pushDefault fails" "$?" 1
has "ambiguous push reason" "$out" "no remote.pushDefault"
git -C "$T" config remote.pushDefault origin
ok "pushDefault set passes" "$(bash "$CARD" "$T" --check >/dev/null 2>&1; echo $?)" 0
has "mirror named read-only" "$(bash "$CARD" "$T")" 'Other remotes (`mirror`) are read-only mirrors'

echo "no spec:"
N="$(mkrepo nospec git@github.com:acme/nospec.git)"
has "no spec line" "$(bash "$CARD" "$N")" 'No `.do/app.yaml`'
ok  "no spec still passes check" "$(bash "$CARD" "$N" --check >/dev/null 2>&1; echo $?)" 0

echo "--write upsert:"
printf '# good\n\nSome notes.\n' > "$G/CLAUDE.md"
bash "$CARD" "$G" --write >/dev/null
ok "existing notes kept"   "$(head -1 "$G/CLAUDE.md")" "# good"
ok "one card"              "$(grep -c '<!-- shipmate:deploy-card' "$G/CLAUDE.md")" 1
bash "$CARD" "$G" --write >/dev/null
ok "idempotent (still one)" "$(grep -c '<!-- shipmate:deploy-card' "$G/CLAUDE.md")" 1
ok "close marker once"     "$(grep -c '/shipmate:deploy-card' "$G/CLAUDE.md")" 1
rm "$G/CLAUDE.md"; bash "$CARD" "$G" --write >/dev/null
ok "creates when missing"  "$(grep -c '## Deploy (shipmate)' "$G/CLAUDE.md")" 1
printf '# after\n' >> "$G/CLAUDE.md"; bash "$CARD" "$G" --write >/dev/null
ok "text after card survives refresh" "$(tail -1 "$G/CLAUDE.md")" "# after"

echo "--check-all:"
out="$(bash "$CARD" --check-all "$TMP/sites" 2>&1)"; rc=$?
ok  "fleet check fails when any drift" "$rc" 1
has "fleet summary line" "$out" "with a DigitalOcean spec"
has "good repo listed ok" "$out" "good → good-app"

echo "degrades without doctl:"
out="$(PATH="/usr/bin:/bin" bash "$CARD" "$G")"
has "unknown live state noted" "$out" "live state not checked"
ok  "check passes without doctl" "$(PATH="/usr/bin:/bin" bash "$CARD" "$G" --check >/dev/null 2>&1; echo $?)" 0

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
