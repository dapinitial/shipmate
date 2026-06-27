#!/usr/bin/env bash
# Allow-list a deployed URL in a Supabase project's auth config, via the Management API.
# SMART PER-PROJECT: auto-derives the project ref from the repo, and resolves the access token
# from the environment first (portable) before the macOS keychain (a per-fleet convenience).
# NON-DESTRUCTIVE: GETs the current config and MERGES (preserves entries like localhost).
#
# Security: the token is passed to curl via a 0600 header file — never in argv/ps/history/logs.
#
# Usage: supabase-allowlist.sh <project-dir> <app-url> [project-ref] [keychain-service]
#   ref + keychain-service are auto-derived if omitted.
set -euo pipefail
umask 077

DIR="${1:?project dir required}"; URL="${2:?app url required}"; URL="${URL%/}"
REF="${3:-}"; SVC="${4:-}"

# --- derive the Supabase project ref: linked-project file → .env.local URL ---
if [ -z "$REF" ]; then
  if [ -f "$DIR/supabase/.temp/project-ref" ]; then
    REF="$(cat "$DIR/supabase/.temp/project-ref")"
  elif [ -f "$DIR/.env.local" ]; then
    REF="$(grep -hE '^(NEXT_PUBLIC_)?SUPABASE_URL=' "$DIR/.env.local" 2>/dev/null | head -1 \
           | sed -E 's#.*://([a-z0-9]+)\.supabase\.co.*#\1#')"
  fi
fi
[ -z "$REF" ] && { echo "✗ couldn't derive the Supabase project ref — pass it as arg 3"; exit 1; }

# --- resolve token: env var (portable) → macOS keychain (convention) → clear error ---
TOKEN="${SUPABASE_ACCESS_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v security >/dev/null 2>&1; then
  [ -z "$SVC" ] && SVC="$(basename "$DIR")-supabase"      # e.g. panogram-supabase
  TOKEN="$(security find-generic-password -s "$SVC" -w 2>/dev/null || true)"
fi
[ -z "$TOKEN" ] && {
  echo "✗ no Supabase access token found."
  echo "  Set SUPABASE_ACCESS_TOKEN, or (macOS) store it: security add-generic-password -s '${SVC:-<project>-supabase}' -a \"\$USER\" -w 'sbp_...'"
  exit 1
}

API="https://api.supabase.com/v1/projects/$REF/config/auth"
HDR="$(mktemp "${TMPDIR:-/tmp}/sb-hdr.XXXXXX")"; trap 'rm -f "$HDR"' EXIT INT TERM
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HDR"

cur="$(curl -fsS -H @"$HDR" "$API")"
cur_list="$(printf '%s' "$cur" | python3 -c "import sys,json;print(json.load(sys.stdin).get('uri_allow_list','') or '')")"
want="$URL/**"
if printf '%s' "$cur_list" | tr ',' '\n' | grep -qxF "$want"; then
  echo "✓ already allow-listed: $want"; merged="$cur_list"
else
  merged="${cur_list:+$cur_list,}$want"
fi
body="$(python3 -c "import json,sys;print(json.dumps({'site_url':sys.argv[1],'uri_allow_list':sys.argv[2]}))" "$URL" "$merged")"
curl -fsS -X PATCH -H @"$HDR" -H "Content-Type: application/json" -d "$body" "$API" >/dev/null
echo "✓ Supabase auth wired (project $REF): site_url=$URL · allow-listed $want (existing preserved)"
