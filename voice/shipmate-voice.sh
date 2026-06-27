#!/usr/bin/env bash
# shipmate voice bridge — turn a spoken phrase into a shipmate action via Claude Code headless.
#
# Wire to an Apple Shortcut (see apple-shortcut.md): the Shortcut SSHes into this Mac and runs:
#   bash ~/Sites/shipmate/voice/shipmate-voice.sh "<the dictated phrase>"
#
# SAFETY: voice runs in PLAN mode by default — it says what it WOULD do (and the cost) and
# executes NOTHING that bills or publishes. To actually run, the phrase must END with "confirm"
# (or "do it" / "send it") — a deliberate second utterance. Even then, irreversible steps the
# skill flags still pause.
set -euo pipefail

PHRASE="${*:-}"
[ -z "$PHRASE" ] && { echo "shipmate: tell me what to ship."; exit 1; }

MODE="plan"
if [[ "$PHRASE" =~ [[:space:]](confirm|do[[:space:]]it|send[[:space:]]it)$ ]]; then
  MODE="execute"
  PHRASE="$(printf '%s' "$PHRASE" | sed -E 's/[[:space:]]+(confirm|do[[:space:]]it|send[[:space:]]it)$//')"
fi

# Resolve a project named in the phrase (e.g. "deploy panogram" → ~/Sites/panogram), else Sites root.
PROJECT="${SHIPMATE_PROJECT_DIR:-$HOME/Sites}"
for word in $PHRASE; do
  if [ -d "$HOME/Sites/$word" ]; then PROJECT="$HOME/Sites/$word"; break; fi
done
cd "$PROJECT"

PROMPT="Use the shipmate /deploy skill to handle this spoken request: \"$PHRASE\".
Mode=$MODE. If Mode=plan, output ONLY the plan and the cost — create, charge, or publish NOTHING.
If Mode=execute, you may proceed, but still pause on any step the skill flags as irreversible.
Keep the reply short enough to be read aloud."

# Claude Code headless; --print returns text for the Shortcut to speak back.
exec claude --print "$PROMPT"
