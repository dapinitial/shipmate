#!/usr/bin/env bash
# vercel-app.sh — lifecycle verbs for a Vercel project (resolved from <dir>/.vercel/project.json),
# the same shape as do-app.sh so the bridge, preflight and the live check stay provider-neutral.
#
# Usage: vercel-app.sh <verb> <project-dir> [arg] [--yes]
#   status            current production deployment: phase, commit, URL
#   url               the production URL (first custom domain, else the project's vercel.app)
#   phase <sha>       the deployment built from that commit: PENDING|BUILDING|LIVE|SUPERSEDED|FAILED|UNKNOWN
#   check             drift: linked project exists, deploys from origin's repo and branch
#   rollback [--yes]  point production at the previous ready production deployment
#                     (without --yes: describe only). NOTE: after a rollback Vercel stops
#                     promoting new pushes until you roll forward.
#   roll-forward [--yes]  promote the newest ready production deployment and resume auto-promotion
#
# Credentials (never echoed, never in argv): VERCEL_TOKEN → the Vercel CLI's own login
# (auth.json) → clear error. Reads go to the REST API; writes go through the vercel CLI.
# SHIPMATE_VERCEL_API overrides the API base (tests point it at a local stub).
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,17p' "$0"; exit 0;; esac
VERB="$1"; DIR="${2:?project dir required}"; ARG="${3:-}"; YES=""
for a in "${@:3}"; do [ "$a" = "--yes" ] && YES=1; done
command -v python3 >/dev/null 2>&1 || { echo "✗ vercel-app.sh needs python3"; exit 1; }
[ -f "$DIR/.vercel/project.json" ] || { echo "✗ $DIR is not linked to a Vercel project (no .vercel/project.json) — run 'vercel link' there"; exit 1; }

api() { # <verb> [arg] — every Vercel REST read, in one place
  python3 - "$DIR" "$@" <<'EOF'
import json, os, sys, urllib.request, urllib.error
d, verb, arg = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else '')
link = json.load(open(os.path.join(d, '.vercel', 'project.json')))
pid, team = link['projectId'], link.get('orgId', '')
def token():
    t = os.environ.get('VERCEL_TOKEN')
    if t: return t
    for p in ('~/Library/Application Support/com.vercel.cli/auth.json', '~/.local/share/com.vercel.cli/auth.json',
              '~/.config/com.vercel.cli/auth.json'):
        try: return json.load(open(os.path.expanduser(p)))['token']
        except Exception: pass
    print('✗ no Vercel credentials: set VERCEL_TOKEN or run `vercel login`'); sys.exit(2)
BASE = os.environ.get('SHIPMATE_VERCEL_API', 'https://api.vercel.com').rstrip('/')
def get(path):
    sep = '&' if '?' in path else '?'
    url = BASE + path + (sep + 'teamId=' + team if team.startswith('team_') else '')
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token()})
    try: return json.load(urllib.request.urlopen(req, timeout=20))
    except urllib.error.HTTPError as e:
        print(f'✗ Vercel API {e.code} for {path.split("?")[0]}'); sys.exit(3)
    except Exception as e:
        print(f'✗ Vercel API unreachable: {e}'); sys.exit(3)
proj = get(f'/v9/projects/{pid}')
current = ((proj.get('targets') or {}).get('production') or {})
def prod_url():
    al = [a for a in (current.get('alias') or []) if isinstance(a, str)]
    custom = [a for a in al if not a.endswith('.vercel.app')]
    return 'https://' + (custom[0] if custom else (al[0] if al else f"{proj['name']}.vercel.app"))
def deployments(n=20):
    return get(f'/v6/deployments?projectId={pid}&target=production&limit={n}').get('deployments', [])
def sha_of(x): return ((x.get('meta') or {}).get('githubCommitSha') or '')
def state_of(x): return x.get('state') or x.get('readyState') or ''
if verb == 'url':
    print(prod_url())
elif verb == 'status':
    print(f"app:    {proj['name']} (vercel, {pid})")
    print(f"url:    {prod_url()}")
    print(f"deploy: {current.get('readyState') or 'NONE'} {sha_of(current)[:7]}")
    # the newest production deployment, which a failed build never replaces "deploy:" with
    newest = (deployments(1) or [{}])[0]
    if newest.get('uid'): print(f"latest: {state_of(newest) or 'UNKNOWN'} {sha_of(newest)[:7]}")
elif verb == 'phase':
    for x in deployments(30):
        if sha_of(x).startswith(arg):
            s = state_of(x)
            if s == 'READY': print('LIVE' if x.get('uid') == current.get('id') else 'SUPERSEDED')
            elif s in ('ERROR',): print('FAILED')
            elif s == 'CANCELED': print('FAILED')
            elif s in ('QUEUED', 'INITIALIZING'): print('PENDING')
            else: print('BUILDING')
            break
    else: print('UNKNOWN')
elif verb == 'check':
    gl = proj.get('link') or {}
    repo = f"{gl.get('org', '')}/{gl.get('repo', '')}" if gl.get('repo') else ''
    print(f"repo={repo} branch={gl.get('productionBranch', '')} name={proj['name']}")
elif verb == 'candidates':  # the ready production deployments, newest first: "<uid> <sha> <current?>"
    for x in deployments(20):
        if state_of(x) == 'READY':
            print(x['uid'], sha_of(x)[:7] or '-', 'current' if x['uid'] == current.get('id') else '-')
EOF
}

case "$VERB" in
  url|status) api "$VERB" ;;
  phase) [ -n "$ARG" ] || { echo "usage: vercel-app.sh phase <dir> <sha>"; exit 1; }; api phase "$ARG" ;;
  check)
    out="$(api check)" || { echo "$out"; exit 1; }
    repo="$(printf '%s' "$out" | sed -nE 's/.*repo=([^ ]*).*/\1/p')"; branch="$(printf '%s' "$out" | sed -nE 's/.*branch=([^ ]*).*/\1/p')"
    origin="$(git -C "$DIR" remote get-url origin 2>/dev/null | sed -E 's#/*$##; s#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')"
    bad=0
    [ -n "$repo" ] || { echo "  ✗ Vercel project has no git connection — pushes won't deploy"; bad=1; }
    [ -z "$repo" ] || [ "$repo" = "$origin" ] || { echo "  ✗ Vercel deploys from '$repo' but origin is '$origin'"; bad=1; }
    want="$(git -C "$DIR" branch --show-current 2>/dev/null)"
    [ -z "$branch" ] || [ -z "$want" ] || [ "$branch" = "$want" ] || [ -f "$DIR/.shipmate.yml" ] || { echo "  ✗ Vercel's production branch is '$branch'"; bad=1; }
    exit $bad ;;
  rollback|roll-forward)
    cands="$(api candidates)" || { echo "$cands"; exit 1; }
    cur="$(printf '%s\n' "$cands" | awk '$3=="current"{print $1, $2; exit}')"
    newest="$(printf '%s\n' "$cands" | sed -n 1p)"
    if [ "$VERB" = rollback ]; then
      # the ready deployment just older than the one serving now
      target="$(printf '%s\n' "$cands" | awk 'f && NF {print $1, $2; exit} $3=="current"{f=1}')"
      [ -n "$target" ] || { echo "✗ no earlier ready production deployment to roll back to"; exit 1; }
      what="roll production back from ${cur#* } to ${target#* }"
      after="After this, Vercel stops promoting new pushes until you roll forward."
    else
      target="$(printf '%s' "$newest" | awk '{print $1, $2}')"
      [ "${target%% *}" != "${cur%% *}" ] || { echo "✓ already serving the newest deployment (${cur#* }) — nothing to roll forward"; exit 0; }
      what="roll production forward from ${cur#* } to ${target#* }"
      after="New pushes go live automatically again."
    fi
    if [ -z "$YES" ]; then echo "Would $what (cost-neutral). $after"; exit 0; fi
    command -v vercel >/dev/null 2>&1 || { echo "✗ vercel CLI missing — brew install vercel-cli"; exit 1; }
    echo "→ $what…"
    if [ "$VERB" = rollback ]; then vercel rollback "${target%% *}" --yes --cwd "$DIR" >/dev/null 2>&1
    else vercel promote "${target%% *}" --yes --cwd "$DIR" >/dev/null 2>&1; fi \
      && echo "✓ done. $after" || { echo "✗ vercel CLI refused — run it by hand: vercel ${VERB/roll-forward/promote} ${target%% *}"; exit 1; } ;;
  redeploy) echo "✗ Vercel redeploys on push; to redo the current one: vercel redeploy <url> (not wired to voice)"; exit 1 ;;
  destroy)  echo "✗ shipmate never deletes Vercel projects; use the dashboard"; exit 1 ;;
  *) echo "✗ unknown verb '$VERB' (status|url|phase|check|rollback|roll-forward)"; exit 1 ;;
esac
