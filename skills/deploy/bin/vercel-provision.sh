#!/usr/bin/env bash
# vercel-provision.sh — deploy the current project to Vercel, pushing env vars from
# .env.local + .env.production via STDIN (values never touch argv/ps). Vercel encrypts env at rest.
# BETA: needs `vercel` (npm i -g vercel) + `vercel login`. Verify on your project before trusting.
#
# Usage: vercel-provision.sh <project-dir> [--prod]
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,8p' "$0"; exit 0;; esac

DIR="${1:?project dir required}"; FLAG="${2:---prod}"
command -v vercel >/dev/null 2>&1 || { echo "✗ vercel CLI missing — npm i -g vercel"; exit 1; }
vercel whoami   >/dev/null 2>&1 || { echo "✗ not logged in — vercel login"; exit 1; }

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib"; . "$LIB/envspec.sh"
cd "$DIR"

# link (idempotent) — ties this dir to a Vercel project, writes .vercel/
[ -d .vercel ] || vercel link --yes >/dev/null

# push env vars to production from the merged env files — value via stdin, never argv
emit_pairs "$DIR/.env.local" "$DIR/.env.production" | while IFS="$(printf '\t')" read -r key val; do
  vercel env rm "$key" production --yes >/dev/null 2>&1 || true     # replace if it already exists
  if printf '%s' "$val" | vercel env add "$key" production >/dev/null 2>&1; then
    echo "  ✓ set $key"
  else
    echo "  ✗ failed to set $key"
  fi
done

echo "→ deploying to Vercel ($FLAG)…"
vercel "$FLAG"
