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
