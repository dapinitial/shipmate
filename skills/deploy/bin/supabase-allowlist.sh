#!/usr/bin/env bash
# Allow-list a deployed URL in a Supabase project's auth config (so magic-link sign-in
# works in prod), via the Supabase Management API. NON-DESTRUCTIVE: it GETs the current
# config and MERGES, preserving existing entries (e.g. localhost).
#
# Security: the access token is read from the macOS keychain and passed to curl via a
# 0600 header file (never in argv / `ps` / shell history / logs), shredded on exit.
#
# Usage: supabase-allowlist.sh <project-ref> <app-url> <keychain-service>
#   e.g. supabase-allowlist.sh moepkkdpsimwpshgvwlt https://panogram-x.ondigitalocean.app panogram-supabase
set -euo pipefail
umask 077

REF="${1:?project-ref required}"
URL="${2:?app-url required}"; URL="${URL%/}"
SVC="${3:?keychain-service required (e.g. panogram-supabase)}"

TOKEN="$(security find-generic-password -s "$SVC" -a "${USER}" -w 2>/dev/null || true)"
[ -z "${TOKEN:-}" ] && { echo "✗ no Supabase token in keychain service '$SVC'"; exit 1; }

API="https://api.supabase.com/v1/projects/$REF/config/auth"
HDR="$(mktemp "${TMPDIR:-/tmp}/sb-hdr.XXXXXX")"
trap 'rm -f "$HDR"' EXIT INT TERM
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HDR"   # token never enters argv

# current allow-list
cur="$(curl -fsS -H @"$HDR" "$API")"
cur_list="$(printf '%s' "$cur" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uri_allow_list','') or '')")"

want="$URL/**"
if printf '%s' "$cur_list" | tr ',' '\n' | grep -qxF "$want"; then
  echo "✓ already allow-listed: $want"
  merged="$cur_list"
else
  merged="${cur_list:+$cur_list,}$want"
fi

# PATCH site_url + merged allow-list (JSON built by python so values are escaped safely)
body="$(python3 -c "import json,sys; print(json.dumps({'site_url': sys.argv[1], 'uri_allow_list': sys.argv[2]}))" "$URL" "$merged")"
curl -fsS -X PATCH -H @"$HDR" -H "Content-Type: application/json" -d "$body" "$API" >/dev/null

echo "✓ Supabase auth wired for project $REF:"
echo "    site_url      = $URL"
echo "    allow-listed  = $want  (existing entries preserved)"
