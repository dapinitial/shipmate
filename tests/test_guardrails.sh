#!/usr/bin/env bash
# Tests for the structural guardrails: per-project settings (lib/project.sh), the pre-push
# guard (lib/pre-push.hook via install-hooks.sh) and preflight.sh. These decide whether a push
# can reach the wrong remote, carry a secret, or land a change too big to have been meant.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/../skills/deploy/bin"; . "$DIR/../skills/deploy/lib/project.sh"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"; trap 'rm -rf "$TMP"' EXIT
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"   # no doctl: preflight's live check is skipped
export SHIPMATE_ALLOW=

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3] in: $2"; fail=$((fail+1)); fi; }
G() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

echo "settings:"
P="$TMP/proj"; mkdir -p "$P"
ok "default remote"   "$(project_deploy_remote "$P")" origin
ok "default branch"   "$(project_branch "$P")" main
ok "default cap"      "$(project_max_files "$P")" 40
ok "default health"   "$(project_health_url "$P")" ""
cat > "$P/.shipmate.yml" <<'EOF'
# shipmate project settings
deploy_remote: prod   # the deploying remote
branch: "release"
max_files: 3
health_url: https://example.test/
protected:
  - site/case-studies/apple/
  - "*.enc"
  - config/private.json
other_key: x
EOF
ok "remote read + comment stripped" "$(project_deploy_remote "$P")" prod
ok "quoted branch"    "$(project_branch "$P")" release
ok "cap"              "$(project_max_files "$P")" 3
ok "health url"       "$(project_health_url "$P")" "https://example.test/"
ok "list items"       "$(project_list "$P" protected | tr '\n' ' ')" "site/case-studies/apple/ *.enc config/private.json "
ok "protected: dir tree"     "$(project_is_protected "$P" site/case-studies/apple/index.html; echo $?)" 0
ok "protected: basename glob" "$(project_is_protected "$P" assets/x.enc; echo $?)" 0
ok "protected: exact path"   "$(project_is_protected "$P" config/private.json; echo $?)" 0
ok "protected: secrets default" "$(project_is_protected "$P" .env.production; echo $?)" 0
ok "protected: pem default"  "$(project_is_protected "$P" certs/server.pem; echo $?)" 0
ok "not protected"           "$(project_is_protected "$P" src/index.astro; echo $?)" 1
ok "not protected: lookalike" "$(project_is_protected "$P" site/case-studies/apple-notes.md; echo $?)" 1

echo "pre-push guard:"
mkrepo() { # <name> — repo with a bare 'origin' and a bare 'mirror', one commit on main pushed to origin
  local r="$TMP/$1" ; mkdir -p "$r"; git init -q --bare "$TMP/$1-origin.git"; git init -q --bare "$TMP/$1-mirror.git"
  git -C "$r" init -q -b main 2>/dev/null || { git -C "$r" init -q; git -C "$r" checkout -q -b main; }
  G "$r" remote add origin "$TMP/$1-origin.git"; G "$r" remote add mirror "$TMP/$1-mirror.git"
  echo hi > "$r/README.md"; G "$r" add -A; G "$r" commit -q -m init; G "$r" push -q -u origin main 2>/dev/null
  printf '%s' "$r"
}
R="$(mkrepo r1)"
ok "no guard yet"      "$(bash "$BIN/install-hooks.sh" --check "$R" >/dev/null 2>&1; echo $?)" 1
out="$(bash "$BIN/install-hooks.sh" "$R")"; has "installed message" "$out" "pre-push guard installed"
ok "guard detected"    "$(bash "$BIN/install-hooks.sh" --check "$R" >/dev/null 2>&1; echo $?)" 0
bash "$BIN/install-hooks.sh" "$R" >/dev/null; ok "idempotent" "$(grep -c 'shipmate pre-push guard' "$R/.git/hooks/pre-push")" 1
printf '#!/bin/sh\nexit 0\n' > "$R/.git/hooks/pre-push"; bash "$BIN/install-hooks.sh" "$R" >/dev/null
ok "foreign hook kept aside" "$([ -f "$R/.git/hooks/pre-push.pre-shipmate" ] && echo kept)" kept

echo "  normal push passes:"
echo a > "$R/a.txt"; G "$R" add -A; G "$R" commit -q -m a
ok "small push ok"     "$(G "$R" push -q origin main >/dev/null 2>&1; echo $?)" 0
echo "  wrong remote refused:"
echo b > "$R/b.txt"; G "$R" add -A; G "$R" commit -q -m b
out="$(G "$R" push mirror main 2>&1)"; ok "mirror refused" "$?" 1
has "mirror reason"    "$out" "deploys from 'origin'; refusing to push to 'mirror'"
ok "bypass env allows" "$(SHIPMATE_ALLOW=1 G "$R" push -q mirror main >/dev/null 2>&1; echo $?)" 0
G "$R" push -q origin main >/dev/null 2>&1
echo "  protected path refused:"
echo secret > "$R/.env"; G "$R" add -f .env; G "$R" commit -q -m env
out="$(G "$R" push origin main 2>&1)"; ok "secret refused" "$?" 1
has "secret reason"    "$out" "'.env' is a protected path"
G "$R" reset -q --hard origin/main
echo "  file cap:"
printf 'max_files: 3\n' > "$R/.shipmate.yml"
for i in 1 2 3 4; do echo $i > "$R/f$i.txt"; done; G "$R" add -A; G "$R" commit -q -m many
out="$(G "$R" push origin main 2>&1)"; ok "over cap refused" "$?" 1
has "cap reason"       "$out" "would change 5 files; this project's cap is 3"
G "$R" reset -q --hard origin/main
printf 'max_files: 3\n' > "$R/.shipmate.yml"; echo x > "$R/x.txt"; G "$R" add -A; G "$R" commit -q -m two
ok "under cap ok"      "$(G "$R" push -q origin main >/dev/null 2>&1; echo $?)" 0
echo "  project-defined remote:"
printf 'deploy_remote: mirror\n' > "$R/.shipmate.yml"; G "$R" add -A; G "$R" commit -q -m cfg
out="$(G "$R" push origin main 2>&1)"; ok "origin refused when mirror is the deploy remote" "$?" 1
ok "mirror allowed"    "$(G "$R" push -q mirror main >/dev/null 2>&1; echo $?)" 0

echo "preflight:"
R2="$(mkrepo r2)"; bash "$BIN/install-hooks.sh" "$R2" >/dev/null
ok "clean repo OK"     "$(bash "$BIN/preflight.sh" "$R2")" OK
G "$R2" checkout -q -b feature
has "wrong branch"     "$(bash "$BIN/preflight.sh" "$R2")" "is on branch 'feature', not 'main'"
G "$R2" checkout -q main
echo s > "$R2/.env"; has "protected in tree" "$(bash "$BIN/preflight.sh" "$R2")" "protected path '.env' is modified"
rm "$R2/.env"
rm "$R2/.git/hooks/pre-push"; has "missing guard" "$(bash "$BIN/preflight.sh" "$R2")" "pre-push guard is not installed"
bash "$BIN/install-hooks.sh" "$R2" >/dev/null
# fall behind: another clone pushes to origin
C="$TMP/r2-clone"; git clone -q "$TMP/r2-origin.git" "$C"; echo z > "$C/z.txt"; G "$C" add -A; G "$C" commit -q -m z; G "$C" push -q origin main 2>/dev/null
G "$R2" fetch -q origin
has "behind remote"    "$(bash "$BIN/preflight.sh" "$R2")" "1 commit(s) behind origin/main"
ok "preflight exit 1"  "$(bash "$BIN/preflight.sh" "$R2" >/dev/null; echo $?)" 1
G "$R2" pull -q --ff-only origin main 2>/dev/null
ok "OK again after pull" "$(bash "$BIN/preflight.sh" "$R2")" OK

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
