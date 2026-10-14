#!/usr/bin/env bash
# app.sh — one set of lifecycle verbs for every provider. Picks do-app.sh or vercel-app.sh by
# the project's provider (lib/provider.sh) and passes the rest through unchanged.
#
# Usage: app.sh <status|url|phase <sha>|check|rollback [--yes]|roll-forward [--yes]> <project-dir> …
#        app.sh provider <project-dir>     → do | vercel | none
# phase prints PENDING|BUILDING|LIVE|SUPERSEDED|FAILED|UNKNOWN for both providers.
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,8p' "$0"; exit 0;; esac
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$BIN/../lib/provider.sh"
VERB="$1"; DIR="${2:?project dir required}"; shift 2
P="$(provider_of "$DIR")"
[ "$VERB" = provider ] && { echo "$P"; exit 0; }
case "$P" in
  do)     exec bash "$BIN/do-app.sh" "$VERB" "$DIR" "$@" ;;
  vercel) exec bash "$BIN/vercel-app.sh" "$VERB" "$DIR" "$@" ;;
  *) echo "✗ $(basename "$DIR") has no deploy target shipmate knows (.do/app.yaml, .vercel/, or provider: in .shipmate.yml)"; exit 1 ;;
esac
