#!/usr/bin/env bash
# install-hooks.sh — put shipmate's pre-push guard into a repo's .git/hooks (per clone; hooks
# are never committed). The guard refuses pushes to the wrong remote, to protected paths, or
# beyond the project's file cap — see lib/pre-push.hook and lib/project.sh.
#
# Usage: install-hooks.sh <project-dir>        install (idempotent; keeps a foreign hook aside)
#        install-hooks.sh --check <project-dir> exit 0 if the shipmate guard is installed
#        install-hooks.sh --all [sites-root]    install into every repo under the root that has
#                                               a .shipmate.yml or a .do/app.yaml
#        install-hooks.sh --check-all [sites-root]
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,12p' "$0"; exit 0;; esac
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
MARK='shipmate pre-push guard'

hook_path() { # absolute path to the repo's pre-push hook (git-dir is relative to the repo, not to us)
  local gd; gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" \
    || gd="$(cd "$1" && cd "$(git rev-parse --git-dir)" && pwd)"
  printf '%s/hooks/pre-push' "$gd"
}
installed() { local h; h="$(hook_path "$1" 2>/dev/null)" && [ -f "$h" ] && grep -q -F "$MARK" "$h"; }

install_one() { # <dir>
  local d="$1" h
  [ -d "$d/.git" ] || { echo "✗ not a git repo: $d"; return 1; }
  h="$(hook_path "$d")"; mkdir -p "$(dirname "$h")"
  if [ -f "$h" ] && ! grep -q -F "$MARK" "$h"; then
    mv "$h" "$h.pre-shipmate"; echo "• existing pre-push hook kept as $(basename "$h").pre-shipmate"
  fi
  sed "s#__SHIPMATE_LIB__#$LIB#" "$LIB/pre-push.hook" > "$h" && chmod +x "$h"
  echo "✓ $(basename "$d") — pre-push guard installed"
}

case "$1" in
  --check) installed "${2:?project dir}" && { echo "✓ guard installed"; exit 0; } || { echo "✗ no shipmate pre-push guard in ${2}"; exit 1; } ;;
  --all|--check-all)
    root="${2:-${SHIPMATE_SITES_ROOT:-$HOME/Sites}}"; n=0; bad=0
    for d in "$root"/*/; do
      [ -d "$d/.git" ] || continue
      [ -f "$d/.shipmate.yml" ] || [ -f "$d/.do/app.yaml" ] || continue
      n=$((n+1))
      if [ "$1" = "--all" ]; then install_one "${d%/}"
      elif installed "${d%/}"; then printf '  \033[32m✓\033[0m %s — guard installed\n' "$(basename "$d")"
      else printf '  \033[31m✗\033[0m %s — no pre-push guard (install-hooks.sh --all)\n' "$(basename "$d")"; bad=$((bad+1)); fi
    done
    [ "$1" = "--check-all" ] && echo "$n deployable repo(s), $bad without the guard"
    [ "$bad" -eq 0 ] ;;
  *) install_one "${1%/}" ;;
esac
