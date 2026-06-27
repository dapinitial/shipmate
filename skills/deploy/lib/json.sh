#!/usr/bin/env bash
# json.sh — tiny JSON helpers that prefer python3, else jq, else a clear error.
# Keeps shipmate from hard-depending on any one tool.
_json_tool() {
  command -v python3 >/dev/null 2>&1 && { echo python3; return 0; }
  command -v jq      >/dev/null 2>&1 && { echo jq;      return 0; }
  echo "✗ need python3 or jq for JSON (brew install jq)" >&2; return 1
}

# json_get <key>   — reads JSON on stdin, prints the top-level string value (or empty)
json_get() {
  local t; t="$(_json_tool)" || return 1
  case "$t" in
    python3) python3 -c "import sys,json;print(json.load(sys.stdin).get(sys.argv[1],'') or '')" "$1" ;;
    jq)      jq -r --arg k "$1" '.[$k] // ""' ;;
  esac
}

# json_obj <k1> <v1> <k2> <v2> ...  — prints a flat JSON object (values are strings, escaped)
json_obj() {
  local t; t="$(_json_tool)" || return 1
  case "$t" in
    python3) python3 -c 'import json,sys;a=sys.argv[1:];print(json.dumps(dict(zip(a[0::2],a[1::2]))))' "$@" ;;
    jq)      local args=() i=1; while [ $# -ge 2 ]; do args+=(--arg "k$i" "$1" --arg "v$i" "$2"); shift 2; i=$((i+1)); done
             # build {($k1):$v1, ...}
             local expr="{" j=1; while [ $j -lt $i ]; do expr="$expr(\$k$j):\$v$j,"; j=$((j+1)); done; expr="${expr%,}}"
             jq -nc "${args[@]}" "$expr" ;;
  esac
}
