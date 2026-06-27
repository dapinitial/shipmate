#!/usr/bin/env bash
# envspec.sh — the security-critical core, isolated so it can be unit-tested.
#
# emit_envs <env-file>...   merges env files (LATER files override earlier keys) and prints a
# DigitalOcean app-spec `envs:` block. Classification (safe-by-default):
#   NEXT_PUBLIC_* / PUBLIC_*  → GENERAL (plaintext, build-time)
#   everything else           → SECRET  (encrypted at rest)
# Empty values and comments are skipped; inline " # …" comments and surrounding quotes stripped.
# Pure stdout; never reads outside the given files; no bash-4 features (macOS bash 3.2 safe).
emit_envs() {
  local body
  body="$( for f in "$@"; do [ -f "$f" ] && { cat "$f"; printf '\n'; }; done \
    | awk -F= '/^[[:space:]]*#/||/^[[:space:]]*$/{next}{k=$1;gsub(/[[:space:]]/,"",k);last[k]=$0}END{for(k in last)print last[k]}' \
    | while IFS= read -r line; do
        key="${line%%=*}"; [ "$key" = "$line" ] && continue
        val="${line#*=}"
        val="${val%%[[:space:]]\#*}"
        val="$(printf '%s' "$val" | sed -E "s/^[[:space:]]+//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//")"
        [ -z "$val" ] && continue
        case "$key" in NEXT_PUBLIC_*|PUBLIC_*) t=GENERAL;; *) t=SECRET;; esac
        esc="$(printf '%s' "$val" | sed "s/'/''/g")"
        printf "      - key: %s\n        scope: RUN_AND_BUILD_TIME\n        type: %s\n        value: '%s'\n" "$key" "$t" "$esc"
      done )"
  [ -z "$body" ] && return 0
  printf '    envs:\n%s\n' "$body"
}
