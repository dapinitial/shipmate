#!/usr/bin/env bash
# Install shipmate's skills into Claude Code (~/.claude/skills) by symlinking, so
# edits in this repo are live immediately. Re-run anytime to add new skills.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/skills"
mkdir -p "$DEST"

for skill in "$REPO"/skills/*/; do
  name="$(basename "$skill")"
  target="$DEST/$name"
  # Replace a real directory with the symlink (the source of truth lives in this repo).
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    rm -rf "$target"
  fi
  ln -sfn "${skill%/}" "$target"
  echo "✓ linked $name → $target"
done

echo
echo "Done. In Claude Code, run the skill from any project (e.g. /deploy)."
