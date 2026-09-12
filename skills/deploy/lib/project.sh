#!/usr/bin/env bash
# project.sh — per-project shipmate settings, read from <project>/.shipmate.yml.
#
# The file is deliberately flat so bash 3.2 + sed can read it without a YAML parser:
#
#   deploy_remote: origin          # the only remote a push may target (default origin)
#   branch: main                   # the production branch (default main)
#   max_files: 40                  # a single push may change at most this many files (default 40)
#   health_url: https://unakin.com # what "is it live" fetches after a ship (default: app's primary domain)
#   expect_text: unakin            # optional: the live page must contain this text
#   protected:                     # paths a push may never touch (globs; dir/ = whole tree)
#     - .env
#     - .env.*
#     - site/case-studies/apple/
#
# Every reader takes the project dir, tolerates a missing file, and returns the default.
# Sourced by preflight.sh, the pre-push hook and the bridge; tested in tests/test_guardrails.sh.

project_file() { printf '%s/.shipmate.yml' "${1%/}"; }

project_setting() { # <dir> <key> [default] — a scalar; strips quotes and trailing comments
  local f v; f="$(project_file "$1")"
  v="$([ -f "$f" ] && sed -nE "s/^$2:[[:space:]]*//p" "$f" | head -1 | sed -E 's/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]+$//')"
  printf '%s' "${v:-${3:-}}"
}

project_list() { # <dir> <key> — the "- item" lines under a list key, one per line
  local f; f="$(project_file "$1")"
  [ -f "$f" ] || return 0
  awk -v k="$2" '
    $0 ~ "^"k":[[:space:]]*$" { inlist=1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); sub(/[[:space:]]+$/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); if (length) print; next }
    inlist && /^[^[:space:]]/ { inlist=0 }
  ' "$f"
}

project_deploy_remote() { project_setting "$1" deploy_remote origin; }
project_branch()        { project_setting "$1" branch main; }
project_max_files()     { project_setting "$1" max_files 40; }
project_health_url()    { project_setting "$1" health_url ""; }
project_expect_text()   { project_setting "$1" expect_text ""; }

# Paths no push may touch unless the project says otherwise. Secrets first; a project adds
# its own (NDA folders, generated artifacts) under "protected:".
PROJECT_DEFAULT_PROTECTED='.env
.env.*
*.pem
*.key
*.p12
*.pfx
id_rsa
id_ed25519'

project_protected() { # <dir> — every protected pattern, defaults + the project's own
  printf '%s\n' "$PROJECT_DEFAULT_PROTECTED"
  project_list "$1" protected
}

project_is_protected() { # <dir> <path> — exit 0 when <path> matches a protected pattern
  local pat base
  base="$(basename "$2")"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in
      */) case "$2" in "$pat"*|*"/$pat"*) return 0 ;; esac ;;          # directory: whole tree
      */*) case "$2" in $pat) return 0 ;; esac ;;                          # path glob
      *)  case "$base" in $pat) return 0 ;; esac ;;                        # basename glob
    esac
  done <<EOF
$(project_protected "$1")
EOF
  return 1
}
