#!/usr/bin/env bash
# shipmate — provision a DigitalOcean App Platform app from .do/app.yaml + .env.local,
# injecting env vars (NEXT_PUBLIC_*/PUBLIC_* as plaintext GENERAL, everything else as
# encrypted SECRET) WITHOUT secrets ever touching git, shell history, logs, or stdout.
#
# SECURITY MODEL
#   • Values are read from the project's ALREADY-LOCAL .env.local — no new exposure.
#   • They are written only to a 0600 temp spec in $TMPDIR, shredded on exit (trap),
#     even on error or interrupt.
#   • doctl sends them to DO over TLS; SECRET-type vars are encrypted at rest.
#   • Nothing is printed but masked confirmation. The caller (and any LLM) never sees values.
#
# The committed .do/app.yaml must contain a marker line where envs go:
#       # shipmate:envs
#
# Usage: do-provision.sh <project-dir> [create|update|auto]
set -euo pipefail
umask 077
case "${1:-}" in -h|--help) sed -n '2,14p' "$0"; exit 0;; esac

DIR="${1:?project dir required}"
ACTION="${2:-auto}"
SPEC_SRC="$DIR/.do/app.yaml"
ENVF="$DIR/.env.local"
ENVP="$DIR/.env.production"   # optional prod overlay — values here override .env.local for deploys

[ -f "$SPEC_SRC" ] || { echo "✗ no .do/app.yaml in $DIR"; exit 1; }
grep -q '# shipmate:envs' "$SPEC_SRC" || { echo "✗ .do/app.yaml missing the '# shipmate:envs' marker"; exit 1; }

# --- env vars: classification + overlay merge live in the unit-tested lib ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/envspec.sh
. "$SCRIPT_DIR/../lib/envspec.sh"
ENVS_BLOCK="$(emit_envs "$ENVF" "$ENVP")"

# --- splice block in place of the marker into a 0600 temp spec, shredded on exit ---
TMP="$(mktemp "${TMPDIR:-/tmp}/shipmate.XXXXXX.yaml")"
trap 'rm -f "$TMP"' EXIT INT TERM
{
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == *"# shipmate:envs"* ]]; then
      [ -n "$ENVS_BLOCK" ] && printf '%s\n' "$ENVS_BLOCK"
    else
      printf '%s\n' "$line"
    fi
  done < "$SPEC_SRC"
} > "$TMP"

# --- dry run: validate the spec + preview it with secret values masked, no deploy ---
if [ "$ACTION" = "dry" ]; then
  echo "→ validating spec (dry run — nothing is deployed, nothing bills)…"
  if doctl apps spec validate "$TMP" >/dev/null 2>&1; then echo "✓ spec is valid"; else
    echo "✗ spec failed validation:"; doctl apps spec validate "$TMP" || true; exit 1; fi
  echo "--- spec preview (all env values masked) ---"
  sed -E "s/(^[[:space:]]*value: ').*('[[:space:]]*$)/\1********\2/" "$TMP"
  exit 0
fi

# --- create vs update ---
name="$(sed -nE 's/^name:[[:space:]]*//p' "$SPEC_SRC" | head -1)"
id="$(doctl apps list --format ID,Spec.Name --no-header 2>/dev/null | awk -v n="$name" '$2==n{print $1}')"

if [ "$ACTION" = "create" ] || { [ "$ACTION" = "auto" ] && [ -z "$id" ]; }; then
  echo "→ creating app '$name'…"
  doctl apps create --spec "$TMP" --format ID,DefaultIngress
else
  echo "→ updating app '$name' ($id)…"
  doctl apps update "$id" --spec "$TMP" --format ID,DefaultIngress
fi

n="$(printf '%s\n' "$ENVS_BLOCK" | grep -c '^[[:space:]]*- key:' || true)"
echo "✓ '$name' provisioned with ${n} env var(s) — secrets encrypted, temp spec shredded."
