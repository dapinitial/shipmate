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
  counsel <question>          deliberate (read-only). Toggle OFF (default): the single
                              default Anthropic model answers. Toggle ON: fans out to
                              SHIPMATE_COUNSEL_MODELS in parallel + a chair synthesis
                              that must name the dissent. "counsel on" / "counsel off".
  status                      running/finished jobs + live deploy phases
  roll back <project> [confirm]   describe, then revert the live deploy (deterministic)
  doctor | preflight          one spoken sentence of system health
  result [job N]              speak a job's summary
  stop [job N]                stop a running job
  new session                 forget the current conversation

On the road: model turns run in the background — answers within SHIPMATE_TURN_BUDGET
seconds (default 25) are spoken; slower ones arrive as a push notification. With no
internet, intents queue and replay on reconnect (a launchd timer + any online utterance
flushes them).

Machine interface (no phrase parsing — used by mcp/shipmate-mcp.js):
  --turn <plan|execute> <project|-> <request…>    one conversational turn
  --dispatch <project|-> <task…>                  start a background job
  --status-report | --result [N] | --stop [N]     job management
  --counsel <project|-> <question…>               deliberate (respects the toggle)
  --counsel-set <on|off>                          flip the counsel toggle
  --rollback <project|-> [--yes] | --doctor       lifecycle + health
  --flush-queue                                   replay queued dead-zone intents

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
  local sid="" old_project="" perm prompt out result new_sid err exec_tools="" approve_sh
  if [ -f "$STATE_DIR/session.id" ]; then sid="$(cat "$STATE_DIR/session.id")"; fi
  if [ -f "$STATE_DIR/session.project" ]; then old_project="$(cat "$STATE_DIR/session.project")"; fi
  # A different project means a different cwd — start a fresh session there.
  if [ -n "$sid" ] && [ "$old_project" != "$project" ]; then sid=""; fi
  cd "$project" 2>/dev/null || { speak "I can't find the project directory for $(basename "$project")."; return 1; }

  if [ "$mode" = "execute" ]; then
    perm="acceptEdits"
    # Execute turns may drive the deploy toolchain non-interactively; everything else
    # still needs on-screen approval. Override the list via SHIPMATE_VOICE_EXECUTE_TOOLS.
    approve_sh="$VOICE_DIR/../skills/deploy/bin/request-approval.sh"
    exec_tools="${SHIPMATE_VOICE_EXECUTE_TOOLS:-Bash(git:*),Bash(npm:*),Bash(doctl:*),Bash(vercel:*),Bash(gh:*)},Bash($approve_sh:*)"
    prompt="Spoken request (hands-free driver; reply short enough to read aloud, plain prose, no markdown): \"$phrase\". Mode=EXECUTE: the user has explicitly confirmed — act now, don't re-ask. Cost-neutral steps (git merge, build, push, redeploying an existing app) proceed without hesitation; always state the monthly cost in your reply. For a step that creates NEW billed resources or raises cost (new app, resize, scale): request an out-of-band tap by running $approve_sh 'one-line description with the exact monthly cost' — proceed only if it prints APPROVED; on DENIED or TIMEOUT, stop and say so. NEVER delete resources or user data from a voice session."
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

# ---- counsel: multi-model deliberation (toggle, default OFF) ------------------------------
# OFF (default): counsel questions go to the single default Anthropic model — fast, cheap,
# and usually all you need. ON: the question fans out to SHIPMATE_COUNSEL_MODELS in parallel
# and a chair synthesizes, REQUIRED to name where the panel disagreed. Always read-only.

counsel_enabled() {
  if [ -n "${SHIPMATE_COUNSEL:-}" ]; then [ "$SHIPMATE_COUNSEL" = "on" ]; return $?; fi
  [ "$(cat "$STATE_DIR/counsel" 2>/dev/null)" = "on" ]
}

counsel_toggle() { # on|off
  printf '%s' "$1" > "$STATE_DIR/counsel"
  if [ "$1" = "on" ]; then
    speak "Counsel enabled — deliberations now convene ${SHIPMATE_COUNSEL_MODELS:-claude-fable-5 claude-opus-4-8 claude-sonnet-5} and report their dissent. Say counsel off to return to a single model."
  else
    speak "Counsel off — back to the single default Anthropic model."
  fi
}

model_label() { printf '%s' "$1" | awk -F- '{print $2}'; }

counsel() { # <question> <project dir>
  local q="$1" project="$2"
  if [ -z "$q" ]; then speak "What should the counsel deliberate on?"; return 1; fi
  if ! counsel_enabled; then turn "$q" plan "$project"; return $?; fi

  local models="${SHIPMATE_COUNSEL_MODELS:-claude-fable-5 claude-opus-4-8 claude-sonnet-5}"
  local tmp m n=0 answers="" chair=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/shipmate-counsel.XXXXXX")"
  cd "$project" 2>/dev/null || { speak "I can't find the project directory for $(basename "$project")."; return 1; }

  for m in $models; do
    claude -p --model "$m" --permission-mode plan \
      "You are one independent voice on a technical counsel for the project in this directory. Question: \"$q\". Give YOUR OWN opinionated recommendation in under 120 words: position, strongest reason, biggest risk. Plain prose." \
      > "$tmp/$m.txt" 2>"$tmp/$m.err" &
  done
  wait

  for m in $models; do
    if [ -s "$tmp/$m.txt" ]; then
      n=$((n + 1))
      answers="$answers

--- $(model_label "$m") says:
$(cat "$tmp/$m.txt")"
    fi
  done
  if [ "$n" -eq 0 ]; then
    cat "$tmp"/*.err > "$STATE_DIR/last-counsel.err" 2>/dev/null || true
    rm -rf "$tmp"
    speak "The counsel failed to convene — no model answered. Check last-counsel dot err on the Mac."
    return 1
  fi

  chair="$(claude -p --permission-mode plan \
    "You chair a technical counsel. $n members answered the question \"$q\" below. Synthesize for a hands-free listener in under 150 words of plain prose: the verdict, where members AGREE, and — required — where they DISAGREE, naming who dissents and why. End with the single next step.$answers" \
    2>>"$STATE_DIR/last-counsel.err")" || chair=""

  { printf 'QUESTION: %s\n' "$q"; printf '%s\n' "$answers"; printf '\n=== CHAIR ===\n%s\n' "$chair"; } \
    > "$STATE_DIR/last-counsel.txt"
  rm -rf "$tmp"

  if [ -n "$chair" ]; then printf '%s' "$chair" | clip 1500
  else speak "The counsel answered but the chair failed to synthesize. $n opinions are in last-counsel dot t x t on the Mac."; fi
}

# ---- intents: budgeted async turns + the offline queue ------------------------------------
# An intent is a tiny dir {verb,mode,project,text} that one runner can execute now (async
# turn), or later (dead-zone queue) — driving means answers must never depend on holding a
# connection open or on continuous coverage.

online() {
  [ -n "${SHIPMATE_FORCE_OFFLINE:-}" ] && return 1
  local code
  code="$(curl -s -m 4 -o /dev/null -w '%{http_code}' "https://api.anthropic.com" 2>/dev/null || echo 000)"
  [ "$code" != "000" ]
}

intent_write() { # <dir> <verb> <mode> <project> <text>
  mkdir -p "$1"
  printf '%s' "$2" > "$1/verb"
  printf '%s' "$3" > "$1/mode"
  printf '%s' "$4" > "$1/project"
  printf '%s' "$5" > "$1/text"
}

intent_run() { # <dir> — execute the stored intent; mark done; push the result if detached
  local d="$1" verb mode project text
  verb="$(cat "$d/verb")"; mode="$(cat "$d/mode")"
  project="$(cat "$d/project")"; text="$(cat "$d/text")"
  case "$verb" in
    say)     turn "$text" "$mode" "$project" > "$d/out" 2>&1 || true ;;
    counsel) counsel "$text" "$project"      > "$d/out" 2>&1 || true ;;
    job)     dispatch_job "$text" "$project" > "$d/out" 2>&1 || true ;;
    *)       printf 'unknown intent verb %s' "$verb" > "$d/out" ;;
  esac
  : > "$d/done"
  if [ -f "$d/detached" ]; then
    notify "shipmate: $(clip 400 < "$d/out")"
  fi
}

# run_or_queue <verb> <mode> <project> <text> — the driving-aware dispatcher.
# Offline → queue (result arrives by push after reconnect). Online → run in the background,
# wait up to SHIPMATE_TURN_BUDGET seconds (default 25); a fast answer is spoken, a slow one
# detaches and lands as a notification — the Shortcut never times out again.
run_or_queue() {
  local verb="$1" mode="$2" project="$3" text="$4" d budget waited=0
  if ! online; then
    d="$STATE_DIR/queue/$(date +%s)-$$"
    intent_write "$d" "$verb" "$mode" "$project" "$text"
    : > "$d/detached"
    speak "Dead zone — I can't reach Claude from here. Queued; I'll run it and ping your phone when we're back online."
    return 0
  fi
  d="$STATE_DIR/turns/$(date +%s)-$$"
  intent_write "$d" "$verb" "$mode" "$project" "$text"
  nohup bash "$SELF" --intent-runner "$d" >/dev/null 2>&1 &
  budget="${SHIPMATE_TURN_BUDGET:-25}"
  while [ "$waited" -lt "$budget" ]; do
    if [ -f "$d/done" ]; then cat "$d/out"; return 0; fi
    sleep 1; waited=$((waited + 1))
  done
  : > "$d/detached"
  if [ -f "$d/done" ]; then rm -f "$d/detached"; cat "$d/out"; return 0; fi
  speak "Still working — I'll ping your phone with the answer."
}

flush_queue() { # replay queued intents FIFO once we're back online (results go by push)
  online || return 0
  local d
  for d in "$STATE_DIR/queue"/*/; do
    [ -d "$d" ] || continue
    intent_run "$d"
    rm -rf "$d"
  done
}

# ---- doctor: one spoken sentence of system health ------------------------------------------

verb_doctor() {
  local line="" ip njobs nq d
  if online; then line="Internet up."; else line="Internet DOWN — I'll queue what you ask."; fi
  ip="$(ifconfig 2>/dev/null | awk '$1=="inet" && $2 ~ /^100\./ {split($2,o,"."); if (o[2]>=64 && o[2]<=127) {print $2; exit}}')"
  if [ -n "$ip" ]; then line="$line Tailnet connected."; else line="$line Tailnet NOT connected."; fi
  if [ -f "$HOME/.shipmate/mcp/http-token" ] && curl -s -m 4 -o /dev/null -X POST \
      "http://127.0.0.1:8788/mcp/$(cat "$HOME/.shipmate/mcp/http-token")" \
      -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' 2>/dev/null; then
    line="$line MCP server up."
  else line="$line MCP server DOWN."; fi
  if command -v doctl >/dev/null 2>&1; then
    if online && doctl account get >/dev/null 2>&1; then line="$line DigitalOcean auth good."
    elif online; then line="$line DigitalOcean auth FAILING."; fi
  fi
  line="$line Disk $(df -h / 2>/dev/null | awk 'NR==2 {print $5}' ) used."
  njobs=0; nq=0
  for d in "$JOBS_DIR"/*/; do
    if [ -d "$d" ] && [ "$(cat "$d/status" 2>/dev/null)" = "running" ]; then njobs=$((njobs+1)); fi
  done
  for d in "$STATE_DIR/queue"/*/; do if [ -d "$d" ]; then nq=$((nq+1)); fi; done
  line="$line $njobs jobs running, $nq intents queued."
  speak "$(printf '%s' "$line" | clip 800)"
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
  cd "$project" 2>/dev/null || { speak "I can't find the project directory for $(basename "$project")."; return 1; }
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
  local d b st started now mins line="" project appsh p plist phase
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
  # Live deploy state for every project in play (session + jobs) — "job done" is not
  # "deployed", and a driver shouldn't have to hold that distinction.
  appsh="$VOICE_DIR/../skills/deploy/bin/do-app.sh"
  plist="$( { if [ -f "$STATE_DIR/session.project" ]; then cat "$STATE_DIR/session.project"; echo; fi
              for d in "$JOBS_DIR"/*/; do
                if [ -d "$d" ]; then cat "$d/project" 2>/dev/null; echo; fi
              done; } | awk 'NF' | sort -u )"
  while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$p/.do/app.yaml" ] || continue
    phase="$(bash "$appsh" status "$p" 2>/dev/null | awk -F': *' '/^deploy:/{print $2}' | awk '{print $1}')"
    [ -n "$phase" ] && line="$line $(basename "$p") production deploy: $phase."
  done <<EOF
$plist
EOF
  if [ -n "$line" ]; then speak "$(printf '%s' "$line" | clip 1200)"
  else speak "No jobs yet. Say 'work on' something to start one."; fi
}

# verb_rollback <project dir> <mode> — deterministic (no model in the loop): a panicked
# "roll back, confirm" is a code path. Plan mode describes; execute reverts via the DO API.
verb_rollback() {
  local project="$1" mode="$2" appsh out pname
  appsh="$VOICE_DIR/../skills/deploy/bin/do-app.sh"
  pname="$(basename "$project")"
  if [ ! -f "$project/.do/app.yaml" ]; then
    speak "Rollback is wired for DigitalOcean apps so far, and $pname doesn't have one. Tell me which project to roll back."
    return 1
  fi
  if [ "$mode" = "execute" ]; then
    if out="$(bash "$appsh" rollback "$project" --yes 2>&1)"; then
      speak "Rolling back $pname to the previous successful deployment now — cost neutral. Ask me for status in a minute to confirm it's active."
    else
      speak "Rollback failed: $(printf '%s' "$out" | tail -n1 | clip 200)"
      return 1
    fi
  else
    out="$(bash "$appsh" status "$project" 2>&1 || true)"
    speak "This would revert $pname to its previous successful deployment — cost neutral, and you can roll forward again by redeploying. Current state: $(printf '%s' "$out" | awk -F': *' '/^deploy:/{print $2}' | clip 120). To do it, say: roll back $pname, confirm."
  fi
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
  --job-runner)    mkdir -p "$JOBS_DIR"; job_runner "$2"; exit 0 ;;
  --intent-runner) mkdir -p "$JOBS_DIR"; intent_run "$2"; exit 0 ;;
  --flush-queue)   mkdir -p "$JOBS_DIR"; flush_queue; exit 0 ;;
esac

if ! command -v claude >/dev/null 2>&1; then
  speak "The claude command line isn't available on the Mac, so I can't help from here."; exit 1
fi
mkdir -p "$JOBS_DIR"

# Machine interface — same engine without phrase parsing, for shipmate-mcp and scripts.
#   --turn <plan|execute> <project|-> <request…>   one conversational turn
#   --dispatch <project|-> <task…>                 start a background job
#   --status-report · --result [N] · --stop [N]    job management
case "${1:-}" in
  --turn)
    MODE="$2"
    if [ "$MODE" != "plan" ] && [ "$MODE" != "execute" ]; then
      speak "usage: --turn <plan|execute> <project|-> <request…>"; exit 1
    fi
    PROJ="$(project_or_default "$(resolve_project "$(phrase_normalize "$3")")")"
    shift 3; turn "$*" "$MODE" "$PROJ"; exit $? ;;
  --dispatch)
    PROJ="$(project_or_default "$(resolve_project "$(phrase_normalize "$2")")")"
    shift 2; dispatch_job "$*" "$PROJ"; exit 0 ;;
  --status-report) verb_status; exit 0 ;;
  --result)        verb_result "job ${2:-}"; exit 0 ;;
  --stop)          verb_stop "job ${2:-}"; exit 0 ;;
  --counsel)
    PROJ="$(project_or_default "$(resolve_project "$(phrase_normalize "$2")")")"
    shift 2; counsel "$*" "$PROJ"; exit $? ;;
  --counsel-set)
    case "${2:-}" in on|off) counsel_toggle "$2"; exit 0 ;; esac
    speak "usage: --counsel-set <on|off>"; exit 1 ;;
  --rollback)
    PROJ="$(project_or_default "$(resolve_project "$(phrase_normalize "${2:-}")")")"
    MODE="plan"; [ "${3:-}" = "--yes" ] && MODE="execute"
    verb_rollback "$PROJ" "$MODE"; exit $? ;;
  --doctor) verb_doctor; exit 0 ;;
esac

# Opportunistic queue flush: any utterance while online drains the dead-zone backlog.
if [ -d "$STATE_DIR/queue" ] && [ -n "$(ls "$STATE_DIR/queue" 2>/dev/null)" ]; then
  nohup bash "$SELF" --flush-queue >/dev/null 2>&1 &
fi

PHRASE="${*:-}"
# No argument? Read stdin — Shortcuts' "Run Script Over SSH" passes its Input that way.
if [ -z "$PHRASE" ] && [ ! -t 0 ]; then PHRASE="$(cat)"; fi
if [ -z "$PHRASE" ]; then speak "shipmate: tell me what to ship."; exit 1; fi

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
  counsel_on)  counsel_toggle on ;;
  counsel_off) counsel_toggle off ;;
  doctor)   verb_doctor ;;
  rollback) verb_rollback "$(project_or_default "$(resolve_project "$CLEAN")")" "$MODE" ;;
  counsel) run_or_queue counsel "$MODE" "$(project_or_default "$(resolve_project "$CLEAN")")" "$(phrase_counsel_question "$CLEAN")" ;;
  job)    run_or_queue job "$MODE" "$(project_or_default "$(resolve_project "$CLEAN")")" "$(phrase_task "$CLEAN")" ;;
  say)    run_or_queue say "$MODE" "$(project_or_default "$(resolve_project "$CLEAN")")" "$CLEAN" ;;
esac
