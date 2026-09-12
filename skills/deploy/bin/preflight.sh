#!/usr/bin/env bash
# preflight.sh — deterministic checks before an execute turn is allowed to change production.
# Runs in seconds, no model, and refuses with a spoken-ready reason. The bridge runs it before
# it consumes the plan grant, so a failed preflight keeps the plan armed: fix, then "ship it".
#
# Usage: preflight.sh <project-dir>        → "OK" (exit 0) or one reason per line (exit 1)
# Checks:
#   · a git repo, on the production branch (.shipmate.yml branch, default main)
#   · not behind the deploy remote (a push would be rejected)
#   · the deploy remote exists and, when a DigitalOcean spec names an app, that app is live
#     and deploys from that remote (deploy-card.sh --check)
#   · no protected path is modified or untracked in the working tree
#   · the pre-push guard is installed
#   · doctl is authenticated when the project has a DigitalOcean spec
set -uo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,15p' "$0"; exit 0;; esac
DIR="${1%/}"; BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$BIN/../lib/project.sh"
bad=0; say() { echo "$1"; bad=1; }

[ -d "$DIR/.git" ] || { echo "$(basename "$DIR") is not a git repository."; exit 1; }
branch="$(project_branch "$DIR")"; remote="$(project_deploy_remote "$DIR")"
cur="$(git -C "$DIR" branch --show-current 2>/dev/null)"
[ "$cur" = "$branch" ] || say "$(basename "$DIR") is on branch '$cur', not '$branch' — switch first."
git -C "$DIR" remote get-url "$remote" >/dev/null 2>&1 || say "no '$remote' remote in $(basename "$DIR")."
if git -C "$DIR" rev-parse --verify -q "$remote/$branch" >/dev/null 2>&1; then
  behind="$(git -C "$DIR" rev-list --count "$branch..$remote/$branch" 2>/dev/null || echo 0)"
  [ "$behind" -eq 0 ] || say "$(basename "$DIR") is $behind commit(s) behind $remote/$branch — pull first or the push will be rejected."
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  project_is_protected "$DIR" "$f" && say "protected path '$f' is modified in the working tree — it must not ship."
done <<EOF
$(git -C "$DIR" status --porcelain 2>/dev/null | cut -c4- | sed 's/^.* -> //')
EOF
bash "$BIN/install-hooks.sh" --check "$DIR" >/dev/null 2>&1 || say "the pre-push guard is not installed in $(basename "$DIR") (install-hooks.sh)."
if [ -f "$DIR/.do/app.yaml" ]; then
  if command -v doctl >/dev/null 2>&1 && doctl account get >/dev/null 2>&1; then
    out="$(bash "$BIN/deploy-card.sh" "$DIR" --check 2>&1)" || say "$(printf '%s' "$out" | sed -E 's/^ *✗ *//' | head -1)"
  else
    say "doctl is not authenticated, so the deploy can't be watched — run doctl auth init."
  fi
fi
[ "$bad" -eq 0 ] && echo "OK"
exit $bad
