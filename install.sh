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

# Make helpers executable (in case the clone dropped the bit).
chmod +x "$REPO"/skills/deploy/bin/*.sh "$REPO"/.githooks/pre-commit "$REPO"/voice/*.sh "$REPO"/tests/*.sh 2>/dev/null || true

# Enable the secret-scan pre-commit hook for contributors.
if [ -d "$REPO/.git" ]; then
  git -C "$REPO" config core.hooksPath .githooks && echo "✓ secret-scan pre-commit hook enabled"
fi

echo
echo "Done. Next:"
echo "  • bash skills/deploy/bin/doctor.sh     # check your tools + auth, per provider"
echo "  • In Claude Code, run /deploy from any project."
