#!/usr/bin/env bash
# phrase.sh — pure parsing for the voice bridge: no filesystem, no network, no claude.
# This decides plan vs execute and which verb runs, so it is tested (tests/test_voice_phrase.sh).
# bash 3.2 safe: no associative arrays, no ${x,,}; BSD and GNU tools only.

# phrase_normalize <phrase> — lowercase, strip dictation punctuation, squeeze whitespace.
# Siri dictation adds commas and a trailing period ("Deploy panogram, confirm."); kill them
# here so every later match sees one canonical form.
phrase_normalize() {
  printf '%s' "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[.,!?;:]+/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# phrase_mode <normalized> — "execute" only when the phrase ENDS with an explicit confirm
# word (a deliberate second utterance), else "plan". A "confirm" mid-sentence does not count.
phrase_mode() {
  case " ${1:-}" in
    *" confirm"|*" do it"|*" send it"|*" ship it") echo execute ;;
    *) echo plan ;;
  esac
}

# phrase_strip_confirm <normalized> — the phrase without its trailing confirm word.
# A phrase that IS only a confirm word strips to empty (the caller treats that as
# "execute what the session just planned").
phrase_strip_confirm() {
  printf '%s' "${1:-}" | sed -E 's/( |^)(confirm|do it|send it|ship it)$//'
}

# phrase_verb <normalized-no-confirm> — one of:
#   status  — "status", "any update", "how's it going", "progress"
#   result  — "result …", "read job …", "what happened …"
#   stop    — "stop/cancel/kill …"
#   new     — "new session/conversation", "start over", "reset"
#   job         — background work: "work on …", "have an agent …", "… in the background"
#   counsel_on / counsel_off — flip multi-model deliberation ("counsel on", "counsel off")
#   counsel     — a deliberation question: "counsel …", "deliberate …", "convene the counsel …"
#   say         — everything else: a conversational turn for the live session
phrase_verb() {
  local p="${1:-}"
  case "$p" in
    status|status\ *|any\ update*|how\ is\ it\ going*|how\'s\ it\ going*|progress|progress\ *)
      echo status; return ;;
    result|result\ *|results|results\ *|read\ job*|what\ happened*)
      echo result; return ;;
    stop|stop\ *|cancel|cancel\ *|kill\ *)
      echo stop; return ;;
    new\ session*|new\ conversation*|start\ over*|reset|reset\ *|fresh\ session*)
      echo new; return ;;
    counsel\ on|deliberate\ on|enable\ the\ counsel)
      echo counsel_on; return ;;
    counsel\ off|deliberate\ off|disable\ the\ counsel)
      echo counsel_off; return ;;
    counsel\ *|deliberate\ *|convene\ the\ counsel*|ask\ the\ counsel*)
      echo counsel; return ;;
    roll\ back*|rollback*|undo\ the\ deploy*|undo\ the\ last\ deploy*|revert\ the\ deploy*)
      echo rollback; return ;;
    roll\ forward*|rollforward*|undo\ the\ rollback*|undo\ rollback*)
      echo rollforward; return ;;
    doctor|health\ check|preflight|pre\ flight|are\ we\ healthy*|how\'s\ the\ system*)
      echo doctor; return ;;
    log\ *|captain\'s\ log\ *)
      echo log; return ;;
    work\ on\ *|have\ an\ agent*|start\ a\ job*|*\ in\ the\ background)
      echo job; return ;;
  esac
  echo say
}

# phrase_counsel_question <normalized> — the question minus its counsel trigger words:
# "counsel on whether we should move to vercel" → "whether we should move to vercel".
phrase_counsel_question() {
  printf '%s' "${1:-}" \
    | sed -E 's/^(convene the counsel|ask the counsel|counsel|deliberate)( on| about|:)? ?//'
}

# phrase_job_id <normalized> — first job number in the phrase ("stop job 3" → 3,
# "result of job two" → 2). Empty when none.
phrase_job_id() {
  local n
  n="$(printf '%s\n' "${1:-}" | grep -oE '[0-9]+' | head -n1 || true)"
  if [ -n "$n" ]; then printf '%s\n' "$n"; return 0; fi
  printf '%s\n' "${1:-}" | awk '{
    split("one two three four five six seven eight nine ten", w, " ")
    for (i = 1; i <= NF; i++) for (j = 1; j <= 10; j++) if ($i == w[j]) { print j; exit }
  }'
}

# phrase_task <normalized-no-confirm> — the job phrase minus its trigger words:
# "work on adding dark mode in the background" → "adding dark mode".
phrase_task() {
  printf '%s' "${1:-}" \
    | sed -E 's/^(work on|have an agent( to)?|start a job( to)?) //; s/ in the background$//'
}

# phrase_log_body <normalized-no-confirm> — the entry minus its trigger words. Any leading
# "to <project>" is left in place; the bridge (which can see the filesystem) peels it off.
phrase_log_body() {
  printf '%s' "${1:-}" | sed -E "s/^(captain's log|log)( that)? //"
}

# phrase_route <normalized> — "<alias> <rest>" when the phrase starts with a routing prefix:
# "at home deploy x" → "home deploy x"; "on the laptop status" → "laptop status". Empty when
# there's no prefix. The bridge only actually routes when the alias exists in its hosts file,
# so "on the other hand…" safely falls through to normal handling.
phrase_route() {
  case "${1:-}" in
    at\ home\ *) printf 'home %s' "${1#at home }" ;;
    on\ the\ *)  printf '%s' "${1#on the }" ;;
    *) printf '' ;;
  esac
}

# ---- project resolution --------------------------------------------------------------------
# Dictation is the weakest link: "unakin" arrives as "anakin", "davidpuerto.com" can never match
# a directory called davidpuerto.com-portfolio. So a phrase resolves to a project two ways,
# alias first (explicit intent wins over a folder of the same name):
#   1. a word (or two adjacent words joined — "shotgun detour" → shotgundetour) that names a
#      directory under $SITES_ROOT, case-insensitive;
#   2. an alias from $SHIPMATE_ALIASES (default ~/.shipmate/aliases): one "alias|target" per
#      line, target relative to $SITES_ROOT or absolute, "#" comments. Alias keys are compared
#      lowercase with spaces and punctuation removed, so "you know kin|unakin" catches the
#      dictation "you know kin". An alias whose target directory is missing is ignored.
#   3. failing both, how the word SOUNDS: every project name and every dictated word is reduced
#      to a consonant skeleton (phrase_phonetic_key), so "anakin" finds unakin without anyone
#      having written that alias down. Exact always beats sound, and when two projects sound
#      the same nothing resolves — an ambiguous name is where a guess costs the most.
# Returns the resolved directory (no trailing slash) or empty when the phrase names nothing.
# resolve_project_why() reports WHICH of the three answered, for callers that want to read the
# project back before acting, or record the miss.
phrase_alias_key() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

resolve_alias() { # <key> — directory for an alias key, else empty
  local f="${SHIPMATE_ALIASES:-$HOME/.shipmate/aliases}" a d
  [ -f "$f" ] || return 0
  while IFS='|' read -r a d || [ -n "$a" ]; do
    case "$a" in ''|\#*) continue ;; esac
    [ "$(phrase_alias_key "$a")" = "$1" ] || continue
    d="$(printf '%s' "$d" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$d" in /*) ;; *) d="${SITES_ROOT:-$HOME/Sites}/$d" ;; esac
    if [ -d "$d" ]; then printf '%s' "${d%/}"; fi
    return 0
  done < "$f"
}

_resolve_exact() { # <normalized phrase> — pass 1: aliases and literal directory names
  local root="${SITES_ROOT:-$HOME/Sites}" w prev="" prev2="" d base hit
  for w in $1; do
    # An alias is the owner's explicit intent, so it beats a folder of the same name
    # ("rillet" → rillet/rillet-case-study, not the ~/Sites/rillet group folder). Aliases may
    # span up to three adjacent dictated words ("you know kin").
    hit="$(resolve_alias "$(phrase_alias_key "$w")")"
    [ -n "$hit" ] || { [ -n "$prev" ] && hit="$(resolve_alias "$(phrase_alias_key "$prev$w")")"; }
    [ -n "$hit" ] || { [ -n "$prev2" ] && hit="$(resolve_alias "$(phrase_alias_key "$prev2$prev$w")")"; }
    if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      base="$(basename "$d" | tr '[:upper:]' '[:lower:]')"
      if [ "$base" = "$w" ] || { [ -n "$prev" ] && [ "$base" = "$prev$w" ]; }; then
        printf '%s' "${d%/}"; return 0
      fi
    done
    prev2="$prev"; prev="$w"
  done
  printf ''
}

# phrase_phonetic_key <word> — a word's consonant skeleton, so words that SOUND alike collapse
# to one key: "unakin", "anakin" and "unnakin" are all NKN. Soundex-style classes, with the two
# rules that matter — a doubled consonant codes once ("anna" → N), and a vowel between two
# same-class consonants separates them ("nan" → NN) while h, w and y do not.
# Pure awk, using substr rather than split($0,a,"") so it runs on BSD awk / macOS bash 3.2.
phrase_phonetic_key() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z' | awk '{
    out = ""; last = ""
    for (i = 1; i <= length($0); i++) {
      ch = substr($0, i, 1); k = ""
      if (ch ~ /^[bpfv]$/)          k = "B"
      else if (ch ~ /^[cgjkqsxz]$/) k = "K"
      else if (ch ~ /^[dt]$/)       k = "T"
      else if (ch == "l")           k = "L"
      else if (ch ~ /^[mn]$/)       k = "N"
      else if (ch == "r")           k = "R"
      if (k != "") { if (k != last) out = out k; last = k }
      else if (ch ~ /^[aeiou]$/) last = ""
    }
    print out
  }'
}

# Keys shorter than this may not match a project: one- and two-class keys are the filler of
# ordinary speech ("on" → N, "it" → T, "the" → T) and would match far too much.
PHONETIC_MIN_KEY=3

_resolve_phonetic() { # <normalized phrase> → "<dir>", or "?|<name>,<name>" when it is ambiguous
  local root="${SITES_ROOT:-$HOME/Sites}" w prev="" key d base hit names n
  for w in $1 ''; do
    if [ -z "$prev" ]; then prev="$w"; continue; fi
    # the word alone, then joined to the one before it ("shotgun detour" → shotgundetour)
    for key in "$(phrase_phonetic_key "$prev")" "$(phrase_phonetic_key "$prev$w")"; do
      [ "${#key}" -ge "$PHONETIC_MIN_KEY" ] || continue
      hit=''; names=''; n=0
      for d in "$root"/*/; do
        [ -d "$d" ] || continue
        base="$(basename "$d")"
        [ "$(phrase_phonetic_key "$base")" = "$key" ] || continue
        n=$((n + 1)); hit="${d%/}"; names="${names:+$names,}$base"
      done
      [ "$n" -eq 1 ] && { printf '%s' "$hit"; return 0; }
      # Two projects that sound alike is exactly when guessing costs most: say so instead.
      [ "$n" -gt 1 ] && { printf '?|%s' "$names"; return 0; }
    done
    prev="$w"
  done
  printf ''
}

# resolve_project_why <normalized phrase> — how the phrase resolved, for callers that want to
# read the project back or record a miss:
#   exact|<dir>      an alias or a literal directory name
#   phonetic|<dir>   it only SOUNDED like that project — a plan turn should say which one
#   ambiguous|<a,b>  more than one project sounds like it: resolve nothing, ask
#   (empty)          the phrase names no project we know
resolve_project_why() {
  local hit
  hit="$(_resolve_exact "$1")"
  [ -n "$hit" ] && { printf 'exact|%s' "$hit"; return 0; }
  hit="$(_resolve_phonetic "$1")"
  case "$hit" in
    '')    printf '' ;;
    '?|'*) printf 'ambiguous|%s' "${hit#?|}" ;;
    *)     printf 'phonetic|%s' "$hit" ;;
  esac
}

# resolve_project <normalized phrase> — the resolved directory, or empty. An exact match always
# beats one that merely sounds right, and an ambiguous sound resolves to nothing, never a guess.
resolve_project() {
  local why
  why="$(resolve_project_why "$1")"
  case "$why" in
    exact\|*|phonetic\|*) printf '%s' "${why#*|}" ;;
    *) printf '' ;;
  esac
}

