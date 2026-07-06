#!/usr/bin/env bash
# shipmate voice bridge v1 — conversational, async, hands-free.
#
# Wire to an Apple Shortcut (see apple-shortcut.md): the Shortcut SSHes into this Mac, runs
#   bash ~/Sites/shipmate/voice/shipmate-voice.sh "<the dictated phrase>"
# and speaks whatever this prints on stdout.
#
# Spoken verbs (full story in README.md):
#   "deploy panogram"                → plan turn: speaks the plan + cost, changes NOTHING
#   "deploy panogram, confirm"       → execute turn (still pauses on irreversible steps)
#   any follow-up sentence           → continues the same Claude session (it remembers the plan)
#   "work on <task> [for <proj>]"    → background agent job; replies immediately, pings when done
#   "status" · "result [job N]" · "stop job N" · "new session"
#
# SAFETY: plan turns run with --permission-mode plan — read-only enforced by Claude Code, not
# by prompt text. Execute requires the phrase to END with "confirm"/"do it"/"send it"/"ship it".
# Background jobs are build/test only: branch-only, never the default branch, never deploy/bill.
set -euo pipefail

VOICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$VOICE_DIR/$(basename "${BASH_SOURCE[0]}")"
. "$VOICE_DIR/lib/phrase.sh"
. "$VOICE_DIR/../skills/deploy/lib/json.sh"

# Optional config (non-secret): export SHIPMATE_NTFY_TOPIC etc. See README.md.
if [ -f "$HOME/.shipmate/voice.env" ]; then . "$HOME/.shipmate/voice.env"; fi

STATE_DIR="${SHIPMATE_VOICE_STATE:-$HOME/.shipmate/voice}"
SITES_ROOT="${SHIPMATE_SITES_ROOT:-$HOME/Sites}"
JOBS_DIR="$STATE_DIR/jobs"

usage() {
  cat <<'EOF'
Usage: shipmate-voice.sh "<spoken phrase>"

Turns a dictated phrase into a shipmate action via headless Claude Code. Prints a
speech-ready reply on stdout (the Apple Shortcut speaks it).

Verbs it hears (case/punctuation don't matter):
  deploy <project>            plan only: speaks plan + cost, changes nothing
  ... confirm | do it | send it | ship it     (suffix) actually execute
  <any follow-up>             continues the current conversation
  work on <task>              background agent job (also: "have an agent ...",
                              "... in the background"); replies immediately
  status                      running/finished jobs
  result [job N]              speak a job's summary
  stop [job N]                stop a running job
  new session                 forget the current conversation

Environment (put exports in ~/.shipmate/voice.env):
  SHIPMATE_SITES_ROOT    where projects live (default ~/Sites)
  SHIPMATE_PROJECT_DIR   default project when the phrase names none (default: sites root)
  SHIPMATE_VOICE_STATE   state dir (default ~/.shipmate/voice)
  SHIPMATE_NTFY_TOPIC    ntfy.sh topic for job-done pushes (pick a long random name)
  SHIPMATE_NTFY_URL      ntfy server (default https://ntfy.sh)
  SHIPMATE_VOICE_CLAUDE_ARGS   extra args appended to every claude invocation
EOF
}

speak() { printf '%s\n' "$1"; }

# clip [maxchars] — stdin → one speech-ready line, truncated politely.
clip() {
  awk -v n="${1:-1200}" '
    { gsub(/\r/, ""); s = s $0 " " }
    END {
      gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
      if (length(s) > n) s = substr(s, 1, n) " ... that is the short version; the full text is on your Mac."
      print s
    }'
}

# notify <message> — best-effort push (ntfy → phone/CarPlay) + local notification. Never fails.
notify() {
  local msg="$1"
  if [ -n "${SHIPMATE_NTFY_TOPIC:-}" ] && command -v curl >/dev/null 2>&1; then
    curl -fsS -m 10 -H "Title: shipmate" -d "$msg" \
      "${SHIPMATE_NTFY_URL:-https://ntfy.sh}/$SHIPMATE_NTFY_TOPIC" >/dev/null 2>&1 || true
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/}\" with title \"shipmate\"" >/dev/null 2>&1 || true
  fi
}

# resolve_project <normalized phrase> — a word in the phrase that names a dir under the
# sites root wins (case-insensitive); empty when the phrase names nothing.
resolve_project() {
  local w d base
  for w in $1; do
    for d in "$SITES_ROOT"/*/; do
      if [ -d "$d" ]; then
        base="$(basename "$d" | tr '[:upper:]' '[:lower:]')"
        if [ "$base" = "$w" ]; then printf '%s' "${d%/}"; return 0; fi
      fi
    done
  done
  printf ''
}

# project_or_default <resolved-or-empty> — an unnamed project means "the one we're already
# talking about": the live session's project, else the configured default.
project_or_default() {
  local sess=""
  if [ -n "$1" ]; then printf '%s' "$1"; return 0; fi
  if [ -f "$STATE_DIR/session.project" ]; then sess="$(cat "$STATE_DIR/session.project")"; fi
  if [ -n "$sess" ] && [ -d "$sess" ]; then printf '%s' "$sess"; return 0; fi
  printf '%s' "${SHIPMATE_PROJECT_DIR:-$SITES_ROOT}"
}

# ---- conversational turn (synchronous) --------------------------------------------------

turn() { # <phrase> <mode:plan|execute> <project dir>
  local phrase="$1" mode="$2" project="$3"
  local sid="" old_project="" perm prompt out result new_sid err exec_tools=""
  if [ -f "$STATE_DIR/session.id" ]; then sid="$(cat "$STATE_DIR/session.id")"; fi
  if [ -f "$STATE_DIR/session.project" ]; then old_project="$(cat "$STATE_DIR/session.project")"; fi
  # A different project means a different cwd — start a fresh session there.
  if [ -n "$sid" ] && [ "$old_project" != "$project" ]; then sid=""; fi
  cd "$project"

  if [ "$mode" = "execute" ]; then
    perm="acceptEdits"
    # Execute turns may drive the deploy toolchain non-interactively; everything else
    # still needs on-screen approval. Override the list via SHIPMATE_VOICE_EXECUTE_TOOLS.
    exec_tools="${SHIPMATE_VOICE_EXECUTE_TOOLS:-Bash(git:*),Bash(npm:*),Bash(doctl:*),Bash(vercel:*),Bash(gh:*)}"
    prompt="Spoken request (hands-free driver; reply short enough to read aloud, plain prose, no markdown): \"$phrase\". Mode=EXECUTE: the user has explicitly confirmed — act now, don't re-ask. Cost-neutral steps (git merge, build, push, redeploying an existing app) proceed without hesitation; always state the monthly cost in your reply. Stop and describe instead ONLY for: creating new billed resources, raising cost (resize, scale), or deleting resources or user data."
  else
    perm="plan"
    prompt="Spoken request (hands-free driver; reply short enough to read aloud, plain prose, no markdown): \"$phrase\". Mode=PLAN: say what you would do and the exact monthly cost. Create, change, charge, or publish NOTHING."
  fi
  if [ -z "$sid" ]; then
    prompt="You are shipmate, a voice deploy assistant for this project. Use the /deploy skill for deploy, DNS, and provider work. The bridge switches to execute ONLY when the user's phrase ends with 'confirm', 'do it', 'send it', or 'ship it' — when telling the user how to proceed, quote one of those exactly; never invent another trigger word. $prompt"
  fi

  if ! out="$(claude -p --output-format json --permission-mode "$perm" \
      ${exec_tools:+--allowedTools "$exec_tools"} \
      ${sid:+--resume "$sid"} ${SHIPMATE_VOICE_CLAUDE_ARGS:-} "$prompt" 2>"$STATE_DIR/last-turn.err")"; then
    # claude reports some failures on stdout (json) rather than stderr — keep both.
    printf '%s' "$out" > "$STATE_DIR/last-turn.out"
    err="$( { tail -n1 "$STATE_DIR/last-turn.err"; printf '%s' "$out" | json_get result; printf '%s' "$out"; } 2>/dev/null | awk 'NF {print; exit}' )"
    speak "shipmate hit an error talking to Claude: $(printf '%s' "${err:-no detail — check last-turn.err and last-turn.out on the Mac}" | clip 200)"
    return 1
  fi
  result="$(printf '%s' "$out" | json_get result)"
  new_sid="$(printf '%s' "$out" | json_get session_id)"
  if [ -n "$new_sid" ]; then
    printf '%s' "$new_sid" > "$STATE_DIR/session.id"
    printf '%s' "$project" > "$STATE_DIR/session.project"
  fi
  if [ -n "$result" ]; then printf '%s' "$result" | clip 1500
  else speak "Done, but Claude returned no summary. Check the Mac."; fi
}

# ---- background jobs ---------------------------------------------------------------------

dispatch_job() { # <task phrase> <project dir>
  local task="$1" project="$2" id=1 d b jdir
  for d in "$JOBS_DIR"/*/; do
    if [ -d "$d" ]; then
      b="$(basename "$d")"
      if [ "$b" -ge "$id" ] 2>/dev/null; then id=$((b + 1)); fi
    fi
  done
  jdir="$JOBS_DIR/$id"; mkdir -p "$jdir"
  printf '%s' "$task"    > "$jdir/task"
  printf '%s' "$project" > "$jdir/project"
  date +%s               > "$jdir/started"
  printf 'running'       > "$jdir/status"
  nohup bash "$SELF" --job-runner "$jdir" >/dev/null 2>&1 &
  printf '%s' "$!" > "$jdir/pid"
  speak "Job $id started on $(basename "$project"): $(printf '%s' "$task" | clip 100). I'll ping you when it's done, or ask me for status."
}

job_runner() { # <job dir> — runs headless, writes result/status, pushes a notification
  local jdir="$1" task project prompt out result status
  task="$(cat "$jdir/task")"; project="$(cat "$jdir/project")"
  cd "$project"
  prompt="Background agent job; no human is watching, so never ask questions — decide and proceed. Task: \"$task\".
Rules: work on a NEW git branch and never commit to or push the default branch (a push there can trigger a production deploy). Run the project's tests if it has any. NEVER deploy, publish, create infrastructure, or take any action that costs money — if the task needs that, prepare everything and stop. End your reply with 'SUMMARY:' followed by 2-3 plain sentences suitable to be read aloud."
  if out="$(claude -p --output-format json --permission-mode acceptEdits \
      ${SHIPMATE_VOICE_CLAUDE_ARGS:-} "$prompt" 2>"$jdir/err")"; then
    result="$(printf '%s' "$out" | json_get result)"; status="done"
    if [ -z "$result" ]; then result="Finished, but no summary came back."; fi
  else
    result="The job hit an error: $(tail -n1 "$jdir/err" 2>/dev/null | clip 200)"; status="failed"
  fi
  printf '%s' "$result" > "$jdir/result"
  printf '%s' "$status" > "$jdir/status"
  date +%s              > "$jdir/finished"
  notify "Job $(basename "$jdir") $status on $(basename "$project"): $(printf '%s' "$result" | job_summary | clip 300)"
}

# job_summary — stdin → the text after the last SUMMARY: marker, or everything if none.
job_summary() {
  local r; r="$(cat)"
  case "$r" in *SUMMARY:*) r="${r##*SUMMARY:}" ;; esac
  printf '%s' "$r"
}

latest_job() { # [running] — highest job id, optionally only running ones
  local only="${1:-}" d b best=""
  for d in "$JOBS_DIR"/*/; do
    if [ -d "$d" ]; then
      b="$(basename "$d")"
      if [ "$only" = "running" ] && [ "$(cat "$d/status" 2>/dev/null)" != "running" ]; then continue; fi
      if [ -z "$best" ] || [ "$b" -gt "$best" ] 2>/dev/null; then best="$b"; fi
    fi
  done
  printf '%s' "$best"
}

verb_status() {
  local d b st started now mins line="" project
  now="$(date +%s)"
  for d in "$JOBS_DIR"/*/; do
    if [ -d "$d" ]; then
      b="$(basename "$d")"
      st="$(cat "$d/status" 2>/dev/null || echo unknown)"
      project="$(basename "$(cat "$d/project" 2>/dev/null || echo '?')")"
      started="$(cat "$d/started" 2>/dev/null || echo "$now")"
      mins=$(( (now - started) / 60 ))
      if [ "$st" = "running" ]; then line="$line Job $b on $project: running, $mins minutes in."
      else line="$line Job $b on $project: $st."; fi
    fi
  done
  if [ -n "$line" ]; then speak "$(printf '%s' "$line" | clip 1200)"
  else speak "No jobs yet. Say 'work on' something to start one."; fi
}

verb_result() { # <normalized phrase>
  local id st
  id="$(phrase_job_id "$1")"
  if [ -z "$id" ]; then id="$(latest_job)"; fi
  if [ -z "$id" ] || [ ! -d "$JOBS_DIR/$id" ]; then speak "I don't have a job by that number."; return 0; fi
  st="$(cat "$JOBS_DIR/$id/status" 2>/dev/null || echo unknown)"
  if [ "$st" = "running" ]; then speak "Job $id is still running. I'll ping you when it finishes."; return 0; fi
  speak "Job $id $st. $(job_summary < "$JOBS_DIR/$id/result" 2>/dev/null | clip 1200)"
}

verb_stop() { # <normalized phrase>
  local id pid
  id="$(phrase_job_id "$1")"
  if [ -z "$id" ]; then id="$(latest_job running)"; fi
  if [ -z "$id" ] || [ ! -d "$JOBS_DIR/$id" ]; then speak "Nothing is running."; return 0; fi
  if [ "$(cat "$JOBS_DIR/$id/status" 2>/dev/null)" != "running" ]; then speak "Job $id already finished."; return 0; fi
  pid="$(cat "$JOBS_DIR/$id/pid" 2>/dev/null || true)"
  if [ -n "$pid" ]; then pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; fi
  printf 'stopped' > "$JOBS_DIR/$id/status"
  speak "Stopped job $id."
}

# ---- main --------------------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --job-runner) job_runner "$2"; exit 0 ;;
esac

PHRASE="${*:-}"
# No argument? Read stdin — Shortcuts' "Run Script Over SSH" passes its Input that way.
if [ -z "$PHRASE" ] && [ ! -t 0 ]; then PHRASE="$(cat)"; fi
if [ -z "$PHRASE" ]; then speak "shipmate: tell me what to ship."; exit 1; fi
if ! command -v claude >/dev/null 2>&1; then
  speak "The claude command line isn't available on the Mac, so I can't help from here."; exit 1
fi
mkdir -p "$JOBS_DIR"

NORM="$(phrase_normalize "$PHRASE")"
MODE="$(phrase_mode "$NORM")"
CLEAN="$(phrase_strip_confirm "$NORM")"
# A bare "confirm" / "do it" utterance means: execute what the session just planned.
if [ -z "$CLEAN" ] && [ "$MODE" = "execute" ]; then CLEAN="go ahead with what we just discussed"; fi
VERB="$(phrase_verb "$CLEAN")"

case "$VERB" in
  new)    rm -f "$STATE_DIR/session.id" "$STATE_DIR/session.project"; speak "Fresh session." ;;
  status) verb_status ;;
  result) verb_result "$CLEAN" ;;
  stop)   verb_stop "$CLEAN" ;;
  job)    dispatch_job "$(phrase_task "$CLEAN")" "$(project_or_default "$(resolve_project "$CLEAN")")" ;;
  say)    turn "$CLEAN" "$MODE" "$(project_or_default "$(resolve_project "$CLEAN")")" ;;
esac
