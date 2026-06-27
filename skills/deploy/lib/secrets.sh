#!/usr/bin/env bash
# secrets.sh — resolve an access token portably, in priority order, without ever echoing it
# in a place it could leak. Callers capture the value into a variable; it's never argv-passed.
#
# resolve_token <ENV_VAR_NAME> <keychain/service-name>
#   1. environment variable (portable, CI-friendly)
#   2. macOS keychain        (security)
#   3. Linux libsecret       (secret-tool)
#   → returns 1 if none found (caller prints an actionable error)
resolve_token() {
  local envname="$1" svc="$2" v
  v="$(printenv "$envname" 2>/dev/null || true)"; [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  if command -v security >/dev/null 2>&1; then          # macOS
    v="$(security find-generic-password -s "$svc" -w 2>/dev/null || true)"; [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  if command -v secret-tool >/dev/null 2>&1; then        # Linux (libsecret)
    v="$(secret-tool lookup service "$svc" 2>/dev/null || true)"; [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  # Windows: set the env var (e.g. $env:SUPABASE_ACCESS_TOKEN) — handled by the env check above.
  return 1
}

# do_token  → the DigitalOcean API token, for endpoints doctl doesn't expose (e.g. rollback):
#   env DIGITALOCEAN_ACCESS_TOKEN → doctl's stored config. Never echoed by callers.
do_token() {
  [ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ] && { printf '%s' "$DIGITALOCEAN_ACCESS_TOKEN"; return 0; }
  local cfg
  for cfg in "$HOME/Library/Application Support/doctl/config.yaml" "$HOME/.config/doctl/config.yaml"; do
    [ -f "$cfg" ] && { grep -E '^access-token:' "$cfg" | head -1 | sed -E 's/^access-token:[[:space:]]*//; s/^"//; s/"$//'; return 0; }
  done
  return 1
}
