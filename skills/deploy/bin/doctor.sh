#!/usr/bin/env bash
# shipmate doctor — check the tools + auth shipmate needs, and say exactly what's missing.
# Usage: doctor.sh [do|vercel|all]   (default: all)
set -uo pipefail   # intentionally NOT -e: run every check, then summarize.

TARGET="${1:-all}"
ok=0; bad=0
chk() { # chk <label> <test-cmd> <fix-hint>
  if eval "$2" >/dev/null 2>&1; then printf '  \033[32m✓\033[0m %s\n' "$1"; ok=$((ok+1))
  else printf '  \033[31m✗\033[0m %s — %s\n' "$1" "$3"; bad=$((bad+1)); fi
}

echo "shipmate doctor · $(uname -s) · bash ${BASH_VERSION%%(*}"
echo "core:"
chk "git"   "command -v git"   "install git"
chk "curl"  "command -v curl"  "install curl"
chk "awk"   "command -v awk"   "install awk (usually preinstalled)"
chk "JSON tool (python3 or jq)" "command -v python3 || command -v jq" "brew install jq  (or install python3)"

if [ "$TARGET" = do ] || [ "$TARGET" = all ]; then
  echo "digitalocean:"
  chk "doctl"      "command -v doctl"  "brew install doctl"
  chk "doctl auth" "doctl account get" "doctl auth init  ·  token: cloud.digitalocean.com/account/api/tokens"
  chk "gh"         "command -v gh"     "brew install gh"
  chk "gh auth"    "gh auth status"    "gh auth login"
fi

if [ "$TARGET" = vercel ] || [ "$TARGET" = all ]; then
  echo "vercel:"
  chk "vercel"      "command -v vercel" "npm i -g vercel"
  chk "vercel auth" "vercel whoami"     "vercel login"
fi

echo "secrets (optional — only for Supabase auth wiring):"
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  printf '  \033[32m✓\033[0m Supabase token (env)\n'; ok=$((ok+1))
elif command -v security >/dev/null 2>&1; then
  printf '  \033[33m•\033[0m Supabase token: not in env — will try macOS keychain per project\n'
else
  printf '  \033[33m•\033[0m Supabase token: set SUPABASE_ACCESS_TOKEN when you need auth wiring\n'
fi

echo
if [ "$bad" -eq 0 ]; then printf '\033[32m✓ ready — %s checks passed\033[0m\n' "$ok"
else printf '\033[31m✗ %s issue(s)\033[0m, %s ok — fix the ✗ lines above\n' "$bad" "$ok"; fi
exit 0
