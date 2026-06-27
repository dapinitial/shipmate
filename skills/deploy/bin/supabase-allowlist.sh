#!/usr/bin/env bash
# Allow-list a deployed URL in a Supabase project's auth config via the Management API.
# Smart per-project: auto-derives the ref; portable token (env → macOS keychain → Linux libsecret);
# JSON via python3 OR jq. NON-DESTRUCTIVE merge (preserves existing entries like localhost).
# The token is passed to curl through a 0600 header file — never in argv/ps/history/logs.
#
# Usage: supabase-allowlist.sh <project-dir> <app-url> [project-ref] [keychain-service]
set -euo pipefail
umask 077
case "${1:-}" in -h|--help) sed -n '2,8p' "$0"; exit 0;; esac

DIR="${1:?project dir required (try --help)}"; URL="${2:?app url required}"; URL="${URL%/}"
REF="${3:-}"; SVC="${4:-}"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib"
. "$LIB/secrets.sh"
. "$LIB/json.sh"

# derive the Supabase project ref: linked-project file → .env.local URL
if [ -z "$REF" ]; then
  if [ -f "$DIR/supabase/.temp/project-ref" ]; then
    REF="$(cat "$DIR/supabase/.temp/project-ref")"
  elif [ -f "$DIR/.env.local" ]; then
    REF="$(grep -hE '^(NEXT_PUBLIC_)?SUPABASE_URL=' "$DIR/.env.local" 2>/dev/null | head -1 \
           | sed -E 's#.*://([a-z0-9]+)\.supabase\.co.*#\1#')"
  fi
fi
[ -z "$REF" ] && { echo "✗ couldn't derive the Supabase project ref — pass it as arg 3"; exit 1; }

[ -z "$SVC" ] && SVC="$(basename "$DIR")-supabase"
TOKEN="$(resolve_token SUPABASE_ACCESS_TOKEN "$SVC" || true)"
[ -z "$TOKEN" ] && {
  echo "✗ no Supabase access token. Provide it any of these ways:"
  echo "    env:    export SUPABASE_ACCESS_TOKEN=sbp_..."
  echo "    macOS:  security add-generic-password -s '$SVC' -a \"\$USER\" -w 'sbp_...'"
  echo "    Linux:  secret-tool store --label shipmate service '$SVC'"
  exit 1
}

API="https://api.supabase.com/v1/projects/$REF/config/auth"
HDR="$(mktemp "${TMPDIR:-/tmp}/sb-hdr.XXXXXX")"; trap 'rm -f "$HDR"' EXIT INT TERM
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HDR"

cur_list="$(curl -fsS -H @"$HDR" "$API" | json_get uri_allow_list)"
want="$URL/**"
if printf '%s' "$cur_list" | tr ',' '\n' | grep -qxF "$want"; then
  echo "✓ already allow-listed: $want"; merged="$cur_list"
else
  merged="${cur_list:+$cur_list,}$want"
fi
body="$(json_obj site_url "$URL" uri_allow_list "$merged")"
curl -fsS -X PATCH -H @"$HDR" -H "Content-Type: application/json" -d "$body" "$API" >/dev/null
echo "✓ Supabase auth wired (project $REF): site_url=$URL · allow-listed $want (existing preserved)"
