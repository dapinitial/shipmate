#!/usr/bin/env bash
# do-app.sh — lifecycle verbs for a DigitalOcean App Platform app (resolved by name from .do/app.yaml).
#
# Usage: do-app.sh <status|url|logs|redeploy|destroy> <project-dir> [--yes]
#   status    deployment phase + URL
#   url       just the live URL
#   logs      recent run logs
#   redeploy  trigger a fresh deployment (cost-neutral). NOTE: true point-in-time rollback is
#             dashboard/API only — doctl can't redeploy a prior spec; this rebuilds current main.
#   destroy   DELETE the app (irreversible) — requires --yes
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,12p' "$0"; exit 0;; esac

VERB="$1"; DIR="${2:?project dir required}"; YES="${3:-}"
NAME="$(sed -nE 's/^name:[[:space:]]*//p' "$DIR/.do/app.yaml" 2>/dev/null | head -1)"
[ -z "$NAME" ] && { echo "✗ no app name in $DIR/.do/app.yaml"; exit 1; }
ID="$(doctl apps list --format ID,Spec.Name --no-header 2>/dev/null | awk -v n="$NAME" '$2==n{print $1}')"
[ -z "$ID" ] && { echo "✗ no DO app named '$NAME' (not deployed yet?)"; exit 1; }

case "$VERB" in
  url)    doctl apps get "$ID" --format DefaultIngress --no-header ;;
  status)
    echo "app:    $NAME ($ID)"
    echo "url:    $(doctl apps get "$ID" --format DefaultIngress --no-header)"
    echo "deploy: $(doctl apps list-deployments "$ID" --format Phase,Progress,Created --no-header 2>/dev/null | head -1)" ;;
  logs)   doctl apps logs "$ID" --type run 2>/dev/null | tail -40 ;;
  redeploy)
    echo "→ redeploying $NAME (cost-neutral — same instance)…"
    doctl apps create-deployment "$ID" --format ID,Phase ;;
  destroy)
    [ "$YES" = "--yes" ] || { echo "✗ refusing to delete '$NAME' without --yes (this is irreversible)"; exit 1; }
    echo "→ DELETING app '$NAME' ($ID)…"
    doctl apps delete "$ID" --force && echo "✓ deleted" ;;
  *) echo "✗ unknown verb '$VERB' (status|url|logs|redeploy|destroy)"; exit 1 ;;
esac
