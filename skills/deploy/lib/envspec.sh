#!/usr/bin/env bash
# envspec.sh — the security-critical env core, isolated so it can be unit-tested.
# macOS bash 3.2 safe (no associative arrays — awk does the merge). Pure stdout.

# _clean_merge <env-file>...  → cleaned `KEY<TAB>VALUE` lines.
# LATER files override earlier keys; comments + empty values dropped; inline " # …" comments and
# surrounding quotes stripped.
_clean_merge() {
  for f in "$@"; do [ -f "$f" ] && { cat "$f"; printf '\n'; }; done \
  | awk -F= '/^[[:space:]]*#/||/^[[:space:]]*$/{next}{k=$1;gsub(/[[:space:]]/,"",k);last[k]=$0}END{for(k in last)print last[k]}' \
  | while IFS= read -r line; do
      key="${line%%=*}"; [ "$key" = "$line" ] && continue
      val="${line#*=}"
      val="${val%%[[:space:]]\#*}"
      val="$(printf '%s' "$val" | sed -E "s/^[[:space:]]+//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//")"
      [ -z "$val" ] && continue
      printf '%s\t%s\n' "$key" "$val"
    done
}

# emit_envs <env-file>...  → DigitalOcean app-spec `envs:` block (safe-by-default classification):
#   NEXT_PUBLIC_* / PUBLIC_* → GENERAL (plaintext, build-time);  everything else → SECRET (encrypted)
emit_envs() {
  local body
  body="$(_clean_merge "$@" | while IFS="$(printf '\t')" read -r key val; do
    case "$key" in NEXT_PUBLIC_*|PUBLIC_*) t=GENERAL;; *) t=SECRET;; esac
    esc="$(printf '%s' "$val" | sed "s/'/''/g")"
    printf "      - key: %s\n        scope: RUN_AND_BUILD_TIME\n        type: %s\n        value: '%s'\n" "$key" "$t" "$esc"
  done)"
  [ -z "$body" ] && return 0
  printf '    envs:\n%s\n' "$body"
}

# emit_pairs <env-file>...  → `KEY<TAB>VALUE` lines, for providers that set env via CLI/stdin (Vercel)
emit_pairs() { _clean_merge "$@"; }
