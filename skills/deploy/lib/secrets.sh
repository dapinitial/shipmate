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
  return 1
}
