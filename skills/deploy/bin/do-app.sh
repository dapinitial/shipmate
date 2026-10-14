#!/usr/bin/env bash
# do-app.sh — lifecycle verbs for a DigitalOcean App Platform app (resolved by name from .do/app.yaml).
#
# Usage: do-app.sh <status|url|phase <sha>|check|logs|redeploy|rollback|roll-forward|destroy> <project-dir> [--yes]
#   status    deployment phase + URL
#   phase     the deployment built from <sha>: PENDING|BUILDING|LIVE|SUPERSEDED|FAILED|UNKNOWN
#   check     drift: the spec names a live app that deploys from origin (deploy-card.sh --check)
#   url       just the live URL
#   logs      recent run logs
#   redeploy  trigger a fresh deployment of current main (cost-neutral)
#   rollback  revert to the previous successful deployment via the DO API (needs --yes)
#   destroy   DELETE the app (irreversible) — needs --yes
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,13p' "$0"; exit 0;; esac

VERB="$1"; DIR="${2:?project dir required}"; ARG="${3:-}"; YES=""
for a in "${@:3}"; do [ "$a" = "--yes" ] && YES="--yes"; done
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib"; . "$LIB/secrets.sh"
NAME="$(sed -nE 's/^name:[[:space:]]*//p' "$DIR/.do/app.yaml" 2>/dev/null | head -1)"
[ -z "$NAME" ] && { echo "✗ no app name in $DIR/.do/app.yaml"; exit 1; }
ID="$(doctl apps list --format ID,Spec.Name --no-header 2>/dev/null | awk -v n="$NAME" '$2==n{print $1}')"
[ -z "$ID" ] && { echo "✗ no DO app named '$NAME' (not deployed yet?)"; exit 1; }

case "$VERB" in
  phase)
    [ -n "$ARG" ] || { echo "usage: do-app.sh phase <dir> <sha>"; exit 1; }
    # match on the commit the deployment built (a retried or manual deploy has another "cause")
    doctl apps list-deployments "$ID" -o json 2>/dev/null | python3 -c '
import sys, json
sha = sys.argv[1]
try: ds = json.load(sys.stdin)
except Exception: ds = []
for d in ds:
    hs = [s.get("source_commit_hash", "") for s in (d.get("services") or []) + (d.get("static_sites") or [])]
    if any(h.startswith(sha) for h in hs):
        p = d.get("phase", "")
        print({"ACTIVE": "LIVE", "SUPERSEDED": "SUPERSEDED", "ERROR": "FAILED", "CANCELED": "FAILED",
               "PENDING_BUILD": "PENDING", "PENDING_DEPLOY": "PENDING", "QUEUED": "PENDING"}.get(p, "BUILDING"))
        break
else:
    print("UNKNOWN")
' "$ARG" ;;
  check) bash "$(dirname "${BASH_SOURCE[0]}")/deploy-card.sh" "$DIR" --check >/dev/null || { bash "$(dirname "${BASH_SOURCE[0]}")/deploy-card.sh" "$DIR" --check | grep '✗'; exit 1; } ;;
  roll-forward) echo "✓ DigitalOcean keeps deploying new pushes after a rollback — nothing to roll forward; push again or redeploy." ;;
  url)    doctl apps get "$ID" --format DefaultIngress --no-header ;;
  status)
    echo "app:    $NAME ($ID)"
    echo "url:    $(doctl apps get "$ID" --format DefaultIngress --no-header)"
    echo "deploy: $(doctl apps list-deployments "$ID" --format Phase,Progress,Created --no-header 2>/dev/null | head -1)" ;;
  logs)   doctl apps logs "$ID" --type run 2>/dev/null | tail -40 ;;
  redeploy)
    echo "→ redeploying $NAME (cost-neutral — same instance)…"
    doctl apps create-deployment "$ID" --format ID,Phase ;;
  rollback)
    # newest-first; line 1 is the current (ACTIVE), line 2 is the previous successful (SUPERSEDED)
    prev="$(doctl apps list-deployments "$ID" --format ID,Phase --no-header 2>/dev/null | awk '$2=="ACTIVE"||$2=="SUPERSEDED"{print $1}' | sed -n '2p')"
    [ -z "$prev" ] && { echo "✗ no prior successful deployment to roll back to"; exit 1; }
    [ "$YES" = "--yes" ] || { echo "Would roll $NAME back to its previous successful deployment (cost-neutral). New pushes keep deploying afterwards."; exit 0; }
    TOKEN="$(do_token)" || { echo "✗ no DO token (set DIGITALOCEAN_ACCESS_TOKEN)"; exit 1; }
    HDR="$(mktemp "${TMPDIR:-/tmp}/do-hdr.XXXXXX")"; trap 'rm -f "$HDR"' EXIT INT TERM
    printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HDR"
    echo "→ rolling back $NAME to deployment $prev…"
    curl -fsS -X POST -H @"$HDR" -H "Content-Type: application/json" \
      -d "{\"deployment_id\":\"$prev\"}" "https://api.digitalocean.com/v2/apps/$ID/rollback" >/dev/null \
      && echo "✓ rollback to $prev initiated — 'do-app.sh status $DIR' to watch." ;;
  destroy)
    [ "$YES" = "--yes" ] || { echo "✗ refusing to delete '$NAME' without --yes (this is irreversible)"; exit 1; }
    echo "→ DELETING app '$NAME' ($ID)…"
    doctl apps delete "$ID" --force && echo "✓ deleted" ;;
  *) echo "✗ unknown verb '$VERB' (status|url|logs|redeploy|rollback|destroy)"; exit 1 ;;
esac
