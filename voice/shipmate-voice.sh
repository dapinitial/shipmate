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
. "$VOICE_DIR/lib/gate.sh"
. "$VOICE_DIR/../skills/deploy/lib/project.sh"
. "$VOICE_DIR/../skills/deploy/lib/ledger.sh"
. "$VOICE_DIR/../skills/deploy/lib/provider.sh"
. "$VOICE_DIR/../skills/deploy/lib/json.sh"
. "$VOICE_DIR/../skills/deploy/lib/sentinel.sh"
. "$VOICE_DIR/../skills/deploy/lib/memory.sh"

# Optional config (non-secret): export SHIPMATE_NTFY_TOPIC etc. See README.md.
if [ -f "$HOME/.shipmate/voice.env" ]; then . "$HOME/.shipmate/voice.env"; fi

STATE_DIR="${SHIPMATE_VOICE_STATE:-$HOME/.shipmate/voice}"
SITES_ROOT="${SHIPMATE_SITES_ROOT:-$HOME/Sites}"
JOBS_DIR="$STATE_DIR/jobs"
HOSTS_FILE="${SHIPMATE_HOSTS_FILE:-$HOME/.shipmate/hosts}"

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
  log [to <project>] <entry>  captain's log: append verbatim + commit; "ship it" = push
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
  --watchdog                                      sentinel + fleet hosts; push on transitions
  --briefing [--push]                             say (or push, and start the next window) the briefing
  --remember <fact|reminder> <text> | --forget <text> | --done <text> | --recall    memory
  --verify-live <project-dir> <sha>               push one line when that commit's deploy is live

The gate: execute turns consume a single-use grant minted by a plan for the same project within
SHIPMATE_PLAN_TTL seconds (default 600). Without one the turn runs as a plan, is read back, and
arms the grant — the next "ship it" (spoken, or the 🚀 button on the push) executes it.

Environment (put exports in ~/.shipmate/voice.env):
  SHIPMATE_SITES_ROOT    where projects live (default ~/Sites)
  SHIPMATE_PROJECT_DIR   default project when the phrase names none (default: sites root)
  SHIPMATE_VOICE_STATE   state dir (default ~/.shipmate/voice)
  SHIPMATE_NTFY_TOPIC    ntfy.sh topic for job-done pushes (pick a long random name)
  SHIPMATE_VOICE_JOB_TOOLS   tool allowlist for background jobs (default: git branch/edit/commit,
                         npm/npx/node and friends — no push, no doctl/vercel/gh)
  SHIPMATE_NTFY_URL      ntfy server (default https://ntfy.sh)
  SHIPMATE_SENTINEL      off = the watchdog stops probing projects (default on)
  SHIPMATE_VOICE_CLAUDE_ARGS   extra args appended to every claude invocation
  SHIPMATE_PLAN_GRANT    grant file shared with the MCP server (default ~/.shipmate/mcp/plan-grant.json)
  SHIPMATE_PLAN_TTL      seconds a plan stays armed (default 600)
  SHIPMATE_VERIFY_TIMEOUT  seconds to wait for a deploy to go live before giving up (default 900)
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
notify() { # <message> [ntfy Actions header] — the phone is the channel; no Mac notification
  local msg="$1" actions="${2:-}"
  if [ -n "${SHIPMATE_NTFY_TOPIC:-}" ] && command -v curl >/dev/null 2>&1; then
    curl -fsS -m 10 -H "Title: shipmate" ${actions:+-H "Actions: $actions"} -d "$msg" \
      "${SHIPMATE_NTFY_URL:-https://ntfy.sh}/$SHIPMATE_NTFY_TOPIC" >/dev/null 2>&1 || true
  fi
}

tailnet_ip() { # this host's Tailscale address (100.64.0.0/10), else empty
  ifconfig 2>/dev/null | awk '$1=="inet" && $2 ~ /^100\./ {split($2,o,"."); if (o[2]>=64 && o[2]<=127) {print $2; exit}}'
}

# notify_plan <project-name> <plan text> <nonce> — push the plan with a 🚀 Ship it button that
# hits the tailnet-only server (/ship/<nonce>). Forgot to say "ship it"? Tap it. The grant is
# single-use and expires, so a stale tap does nothing.
notify_plan() {
  local ip actions=""
  ip="$(tailnet_ip)"
  [ -n "$ip" ] && [ -n "$3" ] && actions="http, 🚀 Ship it, http://$ip:${SHIPMATE_ONBOARD_PORT:-8790}/ship/$3, method=POST, clear=true"
  notify "Plan for $1 — $(printf '%s' "$2" | clip 500)" "$actions"
  : > "$STATE_DIR/last-turn.pushed"
}

# resolve_project lives in lib/phrase.sh (tested); it reads SITES_ROOT and the aliases file.

# project_or_default <resolved-or-empty> — an unnamed project means "the one we're already
# talking about": the live session's project, else the configured default.
project_or_default() {
  local sess=""
  if [ -n "$1" ]; then printf '%s' "$1"; return 0; fi
  if [ -f "$STATE_DIR/session.project" ]; then sess="$(cat "$STATE_DIR/session.project")"; fi
  if [ -n "$sess" ] && [ -d "$sess" ]; then printf '%s' "$sess"; return 0; fi
  printf '%s' "${SHIPMATE_PROJECT_DIR:-$SITES_ROOT}"
}

# project_for <normalized phrase> — the project a phrase names, else the session's, else the
# fleet root. Two kinds of miss go on the record, because they are the raw material for the
# dictation dictionary (bin/ledger.sh report --dictation): a name that sounds like more than
# one project, and — only when there is no session project to fall back on, so the phrase
# really did fail to place anything — a name that matched nothing at all. Aliases then get
# written from evidence instead of from memory.
project_for() {
  local phrase="${1:-}" why sess=""
  why="$(resolve_project_why "$phrase")"
  case "$why" in
    exact\|*|phonetic\|*) printf '%s' "${why#*|}"; return 0 ;;
    ambiguous\|*) ledger_record phrase-parser ambiguous '-' "$phrase" "sounds like ${why#*|}; resolved nothing" >/dev/null ;;
  esac
  if [ -f "$STATE_DIR/session.project" ]; then sess="$(cat "$STATE_DIR/session.project")"; fi
  if [ -n "$sess" ] && [ -d "$sess" ]; then printf '%s' "$sess"; return 0; fi
  case "$why" in
    ambiguous\|*) ;;
    *) [ -n "$phrase" ] && ledger_record phrase-parser unresolved '-' "$phrase" "no project matched by name or sound" >/dev/null ;;
  esac
  printf '%s' "${SHIPMATE_PROJECT_DIR:-$SITES_ROOT}"
}

# ---- conversational turn (synchronous) --------------------------------------------------

turn() { # <phrase> <mode:plan|execute> <project dir>
  local phrase="$1" mode="$2" project="$3"
  local sid="" old_project="" perm prompt out result new_sid err exec_tools="" approve_sh
  local pname downgraded="" nonce head_before="" head_after=""
  pname="$(basename "$project")"
  # The gate: an execute turn must consume a live grant minted by a plan for this project.
  # Otherwise it becomes a plan — read back, with the cost — and mints the grant the next
  # "ship it" will consume. Enforced here, so every mouth (Siri, Claude app, terminal) gets it.
  if [ "$mode" = "execute" ]; then
    # Preflight first (deterministic, seconds): wrong branch, behind origin, a protected file
    # in the tree, no guard, stale app spec. It refuses BEFORE the grant is consumed, so the
    # plan stays armed — fix the reason and say "ship it" again.
    local pf
    if ! pf="$(bash "$VOICE_DIR/../skills/deploy/bin/preflight.sh" "$project" 2>&1)"; then
      ledger_record preflight refused "$pname" "$phrase" "$(printf '%s' "$pf" | tr '\n' ' ')" >/dev/null
      speak "Preflight stopped the ship for $pname: $(printf '%s' "$pf" | clip 300) The plan is still armed — fix that and say ship it."
      return 1
    fi
    if ! downgraded="$(gate_take "$pname")"; then
      mode="plan"
      ledger_record plan-grant downgraded "$pname" "$phrase" "execute requested with no valid grant ($downgraded); ran as a plan" >/dev/null
    fi
  else
    downgraded=""
  fi
  if [ -f "$STATE_DIR/session.id" ]; then sid="$(cat "$STATE_DIR/session.id")"; fi
  if [ -f "$STATE_DIR/session.project" ]; then old_project="$(cat "$STATE_DIR/session.project")"; fi
  # A different project means a different cwd — start a fresh session there.
  if [ -n "$sid" ] && [ "$old_project" != "$project" ]; then sid=""; fi
  cd "$project" 2>/dev/null || { speak "I can't find the project directory for $(basename "$project")."; return 1; }
  head_before="$(git rev-parse HEAD 2>/dev/null || true)"

  if [ "$mode" = "execute" ]; then
    perm="acceptEdits"
    # Execute turns may drive the deploy toolchain non-interactively; everything else
    # still needs on-screen approval. Override the list via SHIPMATE_VOICE_EXECUTE_TOOLS.
    approve_sh="$VOICE_DIR/../skills/deploy/bin/request-approval.sh"
    exec_tools="${SHIPMATE_VOICE_EXECUTE_TOOLS:-Bash(git:*),Bash(npm:*),Bash(doctl:*),Bash(vercel:*),Bash(gh:*)},Bash($approve_sh:*)"
    prompt="Spoken request (hands-free driver; reply short enough to read aloud, plain prose, no markdown): \"$phrase\". Mode=EXECUTE: the user has explicitly confirmed — act now, don't re-ask. Cost-neutral steps (git merge, build, push, redeploying an existing app) proceed without hesitation; always state the monthly cost in your reply. For a step that creates NEW billed resources or raises cost (new app, resize, scale): request an out-of-band tap by running $approve_sh 'one-line description with the exact monthly cost' — proceed only if it prints APPROVED; on DENIED or TIMEOUT, stop and say so. NEVER delete resources or user data from a voice session. Push to 'origin' (the remote the app deploys from) unless the project says otherwise. Report only what you verified: after a push run 'git status -sb' and confirm 'ahead' is gone before saying it pushed or deployed; if a push or command fails, say so plainly and what to do next. If the shipmate pre-push guard refuses a push (wrong remote, protected path, too many files), never bypass it (no --no-verify, no SHIPMATE_ALLOW) — report its reason verbatim."
  else
    perm="plan"
    prompt="Spoken request (hands-free driver; reply short enough to read aloud, plain prose, no markdown): \"$phrase\". Mode=PLAN: say what you would do and the exact monthly cost. Create, change, charge, or publish NOTHING."
  fi
  # What it remembers rides along as notes (never permissions); a fresh session also hears the
  # last few exchanges from any channel, so a switch from Siri to the Claude app keeps the thread.
  local memctx
  if [ -z "$sid" ]; then memctx="$(memory_context recent 2>/dev/null)"; else memctx="$(memory_context 2>/dev/null)"; fi
  [ -n "$memctx" ] && prompt="$memctx $prompt"
  if [ -z "$sid" ]; then
    prompt="You are shipmate, a voice deploy assistant for this project. Use the /deploy skill for deploy, DNS, and provider work. The bridge switches to execute ONLY when the user's phrase ends with 'confirm', 'do it', 'send it', or 'ship it' — when telling the user how to proceed, quote one of those exactly; never invent another trigger word. $prompt"
  fi

  # --allowedTools is variadic: it must NOT be the last flag before the prompt, or it swallows
  # the prompt as another tool name (claude then reports "Input must be provided…").
  if ! out="$(claude -p ${exec_tools:+--allowedTools "$exec_tools"} \
      --output-format json --permission-mode "$perm" \
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
  if [ "$mode" = "plan" ]; then
    # Read back, then arm: the next "ship it" (spoken, or tapped on the push) executes this.
    nonce="$(gate_mint "$pname")"
    if [ -n "$downgraded" ]; then
      result="$(gate_reason_spoken "$downgraded" "$pname") $result Say ship it to do it."
    fi
    notify_plan "$pname" "$result" "$nonce"
  else
    # Prove it: a push that reached origin becomes a deployment we can watch. Deterministic —
    # no model in the loop — and delivered as a push when the deploy is actually live.
    head_after="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$head_after" ] && [ "$head_after" != "$head_before" ]; then
      ledger_record ship executed "$pname" "$phrase" "HEAD $(printf '%s' "$head_before" | cut -c1-7) → $(printf '%s' "$head_after" | cut -c1-7); $(git status -sb 2>/dev/null | head -1)" >/dev/null
    else
      ledger_record ship executed "$pname" "$phrase" "no new commit" >/dev/null
    fi
    if [ -n "$head_after" ] && [ "$head_after" != "$head_before" ] && [ "$(provider_of "$project")" != none ] \
       && ! git status -sb 2>/dev/null | head -1 | grep -q 'ahead'; then
      nohup bash "$SELF" --verify-live "$project" "$head_after" >/dev/null 2>&1 &
    fi
  fi
  heard_record "$(ledger_channel)" "$pname" "$phrase" "${result:-no summary}"
  if [ -n "$result" ]; then printf '%s' "$result" | clip 1500
  else speak "Done, but Claude returned no summary. Check the Mac."; fi
}

# verify_live <project dir> <sha> — wait for the deployment of <sha> to go ACTIVE (or fail), then
# push one line: what's live, or what to say to roll back. Never speaks; always pushes.
verify_live() {
  local project="$1" sha="$2" short name url phase waited=0 limit="${SHIPMATE_VERIFY_TIMEOUT:-900}" code expect appsh
  short="$(printf '%s' "$sha" | cut -c1-7)"; name="$(basename "$project")"
  appsh="$VOICE_DIR/../skills/deploy/bin/app.sh"
  [ "$(bash "$appsh" provider "$project")" != none ] || return 0
  while [ "$waited" -lt "$limit" ]; do
    # Each provider reports the deployment built from this commit as one normalized phase.
    phase="$(bash "$appsh" phase "$project" "$sha" 2>/dev/null | tail -1)"
    case "$phase" in
      LIVE|SUPERSEDED)
        # The address people open: health_url in .shipmate.yml, else the provider's production URL.
        url="$(project_health_url "$project")"
        [ -n "$url" ] || url="$(bash "$appsh" url "$project" 2>/dev/null | grep -v '<nil>' | tail -1)"
        code="$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"; [ -n "$code" ] || code=000
        expect="$(project_expect_text "$project")"
        if [ "$phase" = SUPERSEDED ]; then
          ledger_record verify-live live "$name" "deploy $short" "went live, already superseded by a newer deploy; $url $code" >/dev/null
          notify "✅ $name: $short went live and has already been replaced by a newer deploy — $url"
        elif [ "$code" = 200 ] && [ -n "$expect" ] && ! curl -s -m 15 "$url" 2>/dev/null | grep -q -F -- "$expect"; then
          ledger_record verify-live warned "$name" "deploy $short" "live, $url 200 but missing expected text" >/dev/null
          notify "⚠️ $name: deploy $short is live and $url answers 200, but the page doesn't contain \"$expect\" — say 'roll back $name, confirm' if that's wrong."
        elif [ "$code" = 200 ]; then ledger_record verify-live live "$name" "deploy $short" "$url 200" >/dev/null; notify "✅ $name is live: $short — $url"
        else ledger_record verify-live warned "$name" "deploy $short" "live but $url answered HTTP $code" >/dev/null; notify "⚠️ $name: deploy $short is live but $url answered HTTP $code — say 'roll back $name, confirm' if it looks wrong."; fi
        return 0 ;;
      FAILED)
        ledger_record verify-live failed "$name" "deploy $short" "deployment failed" >/dev/null
        notify "❌ $name: deploy of $short failed — the previous version is still live. Fix and ship again."
        return 0 ;;
    esac
    sleep 20; waited=$((waited + 20))
  done
  ledger_record verify-live failed "$name" "deploy $short" "not live after $((limit / 60)) minutes" >/dev/null
  notify "⏳ $name: deploy of $short still not live after $((limit / 60)) minutes — check the dashboard."
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
  if [ -f "$d/detached" ] && ! [ "$STATE_DIR/last-turn.pushed" -nt "$d/verb" ]; then
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
  if [ "${SHIPMATE_FORCE_DETACH:-}" = 1 ]; then : > "$d/detached"; fi   # nobody listening: push the result
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

# ---- fleet: host routing + cross-host watchdog ---------------------------------------------
# ~/.shipmate/hosts registers the fleet, one line per host:  alias|user@tailnet-name[|bridge]
# "at home …" / "on the laptop …" runs the rest of the phrase on that host's bridge over SSH.

host_target() { # <alias> — print "target|bridge" or nothing
  [ -f "$HOSTS_FILE" ] || return 0
  awk -F'|' -v a="$1" '$1==a && $1 !~ /^#/ {print $2 "|" ($3 ? $3 : "~/Sites/shipmate/voice/shipmate-voice.sh"); exit}' "$HOSTS_FILE"
}

route_to_host() { # <alias> <rest of phrase> — 0 if handled remotely, 1 to fall through
  local alias="$1" rest="$2" entry target bridge out
  entry="$(host_target "$alias")"
  [ -z "$entry" ] && return 1
  target="${entry%%|*}"; bridge="${entry#*|}"
  if out="$(printf '%s' "$rest" | ssh -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new "$target" "bash $bridge" 2>/dev/null)"; then
    speak "From $alias: $out"
  else
    speak "I couldn't reach the $alias host — it may be asleep or off the tailnet."
  fi
  return 0
}

verb_watchdog() { # timer: probe fleet hosts, then every live project; push only on transitions
  local alias target rest host state prev sdir="$STATE_DIR/watchdog" line
  # The sentinel speaks first: a site down, a failed deploy, a certificate about to lapse.
  # It only observes; each line it prints is one push. SHIPMATE_SENTINEL=off silences it.
  if [ "${SHIPMATE_SENTINEL:-on}" != off ]; then
    bash "$VOICE_DIR/../skills/deploy/bin/sentinel.sh" "$SITES_ROOT" 2>/dev/null | while IFS= read -r line; do
      [ -n "$line" ] && notify "$line"
    done
  fi
  [ -f "$HOSTS_FILE" ] || return 0
  mkdir -p "$sdir"
  while IFS='|' read -r alias target rest; do
    case "$alias" in ''|\#*) continue ;; esac
    host="${target#*@}"
    if curl -s -m 8 -o /dev/null "http://$host:${SHIPMATE_ONBOARD_PORT:-8790}/api/info" 2>/dev/null; then
      state="up"
    else state="down"; fi
    prev="$(cat "$sdir/$alias" 2>/dev/null || true)"
    printf '%s' "$state" > "$sdir/$alias"
    if [ -n "$prev" ] && [ "$prev" != "$state" ]; then
      if [ "$state" = "down" ]; then notify "watchdog: the $alias host ($host) stopped answering."
      else notify "watchdog: the $alias host ($host) is back."; fi
    fi
  done < "$HOSTS_FILE"
}

# ---- the briefing: what happened since the last one, and what needs you ----------------------
# Deterministic (bin/briefing.sh reads shipmate's own records; no model). Spoken on request
# ("good morning", "what did I miss"); pushed once a day by the com.shipmate.briefing timer,
# which also starts the next window — so asking later in the day covers everything since.
verb_brief() { # [push]
  local b="$VOICE_DIR/../skills/deploy/bin/briefing.sh"
  if [ "${1:-}" = push ]; then notify "$(bash "$b" --mark | clip 1500)"
  else speak "$(bash "$b" | clip 1200)"; fi
}

# ---- memory: what it keeps across channels (skills/deploy/lib/memory.sh) ----------------------
# Deterministic: your words are stored as said, matched by their words, and read back. A learned
# name ("by the site I mean unakin") goes to the aliases file only when it names a real project.

channel_words() { # siri → "on Siri" etc.
  case "$1" in siri) printf 'on Siri' ;; claude-app) printf 'in the Claude app' ;; terminal) printf 'in the terminal' ;;
    ship-button) printf 'from the Ship it button' ;; mcp-stdio) printf 'from Claude Code' ;; *) printf 'on %s' "${1:-an unknown channel}" ;; esac
}
ago_words() { local s=$(( $(date +%s) - ${1:-0} )); if [ "$s" -lt 120 ]; then printf 'just now'; else printf '%s ago' "$(sentinel_ago "$s")"; fi; }

verb_remember() { # <body> [fact|reminder]
  local body="$1" kind="${2:-fact}" alias name target dir rel already
  export MEMORY_CHANNEL; MEMORY_CHANNEL="$(ledger_channel)"
  [ -n "$body" ] || { speak "What should I remember? Say remember, then the thing."; return 0; }
  if [ "$kind" = fact ] && alias="$(phrase_memory_alias "$(phrase_normalize "$body")")" && [ -n "$alias" ]; then
    name="${alias%%|*}"; target="${alias#*|}"
    dir="$(resolve_project "$target")"
    if [ -n "$dir" ]; then
      already="$(resolve_project "$name")"
      if [ "$already" = "$dir" ]; then speak "I already take $name as $(basename "$dir")."; return 0; fi
      rel="${dir#"$SITES_ROOT"/}"
      printf '%s|%s\n' "$name" "$rel" >> "${SHIPMATE_ALIASES:-$HOME/.shipmate/aliases}"
      memory_add alias "$name → $rel" "$(basename "$dir")" >/dev/null
      speak "Got it: when you say $name, I'll take it as $(basename "$dir")."; return 0
    fi
    memory_add fact "$body" >/dev/null
    speak "I don't know a project called $target, so I kept it as a note: $body."; return 0
  fi
  memory_add "$kind" "$body" >/dev/null
  if [ "$kind" = reminder ]; then speak "I'll remind you to $body. It stays in your morning briefing until you say done with it."
  else speak "Got it, I'll remember that $body."; fi
}

verb_forget() { # <body> <forget|done>
  local body="$1" op="${2:-forget}" kind="" m n id k text
  [ "$op" = done ] && kind=reminder
  case "$body" in ""|that|this|the\ last\ one) m="$(memory_list "$kind" | tail -1)" ;; *) m="$(memory_find "$body" "$kind")" ;; esac
  n="$(printf '%s' "$m" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "$n" = 0 ]; then
    if [ "$op" = done ]; then speak "I don't have a reminder about $body."; else speak "I don't have anything about $body."; fi; return 0
  fi
  if [ "$n" -gt 1 ]; then
    speak "That matches $n things: $(printf '%s\n' "$m" | awk -F'|' '{printf "%s%d, %s", (NR>1?"; ":""), NR, $4}'). Say it again with a few more words."; return 0
  fi
  IFS='|' read -r id k _ text <<EOF
$m
EOF
  memory_close "$op" "$id"
  if [ "$k" = alias ]; then  # unlearn the name too
    local f="${SHIPMATE_ALIASES:-$HOME/.shipmate/aliases}" nm="${text%% → *}"
    [ -f "$f" ] && awk -F'|' -v n="$nm" '$1 != n' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
  if [ "$op" = done ]; then speak "Checked off: $text."; else speak "Forgotten: $text."; fi
}

verb_recall() {
  local facts rem names line=""
  facts="$(memory_list fact | awk -F'|' '{printf "%s%s", (NR>1?"; ":""), $4}')"
  rem="$(memory_list reminder | while IFS='|' read -r _ _ t text; do printf '%s, from %s; ' "$text" "$(ago_words "$t")"; done | sed 's/; $//')"
  names="$(memory_list alias | awk -F'|' '{printf "%s%s", (NR>1?"; ":""), $4}')"
  [ -n "$facts" ] && line="I remember: $facts."
  [ -n "$rem" ] && line="$line Reminders: $rem."
  [ -n "$names" ] && line="$line Names: $names."
  if [ -n "$line" ]; then speak "$(printf '%s' "${line# }" | clip 1200)"
  else speak "Nothing yet. Say remember, then the thing, or remind me to, then the thing."; fi
}

verb_recap() {
  local first=1 t ch proj said replied out="" nrem
  while IFS='|' read -r t ch proj said replied; do
    [ -n "$t" ] || continue
    if [ "$first" = 1 ]; then
      out="Last, $(ago_words "$t") $(channel_words "$ch")${proj:+, about $proj}: you said \"$said\", and I said: $(printf '%s' "$replied" | clip 220)"
      first=0
    else out="$out Before that, $(ago_words "$t") $(channel_words "$ch"): \"$said\"."; fi
  done <<EOF
$(heard_recent 3)
EOF
  nrem="$(memory_list reminder | awk 'NF' | wc -l | tr -d ' ')"
  [ "$nrem" != 0 ] && out="$out You have $nrem open reminder$([ "$nrem" = 1 ] || echo s); say my reminders to hear them."
  if [ -n "$out" ]; then speak "$(printf '%s' "${out# }" | clip 1400)"
  else speak "I don't have a conversation on record yet."; fi
}

# ---- captain's log: deterministic journal append (your words, your publish gate) -----------

# verb_log <body-with-optional-"to <project>"-prefix> <mode>
# Appends a timestamped entry to the project's captains-log.md and commits it. Plain log =
# local commit only; a trailing "ship it"/"confirm" also pushes — which, on a deploy-on-push
# repo, IS publishing. No model involved: these are the user's own words.
verb_log() {
  local body="$1" mode="$2" project="" rest="$1" w1 w2 file entry pname base
  # Peel a leading "to <project>" (one or two dictated words) if it resolves.
  if printf '%s' "$body" | grep -q '^to '; then
    w1="$(printf '%s' "$body" | awk '{print $2}')"
    w2="$(printf '%s' "$body" | awk '{print $3}')"
    project="$(resolve_project "$w1 $w2")"
    if [ -n "$project" ]; then
      base="$(basename "$project" | tr '[:upper:]' '[:lower:]')"
      if [ "$base" = "$w1$w2" ]; then rest="$(printf '%s' "$body" | cut -d' ' -f4-)"
      else rest="$(printf '%s' "$body" | cut -d' ' -f3-)"; fi
    fi
  fi
  if [ -z "$project" ]; then project="$(project_or_default "")"; fi
  pname="$(basename "$project")"
  if [ -z "$rest" ]; then speak "Log what?"; return 1; fi
  if [ ! -d "$project" ]; then speak "I can't find the project directory for $pname."; return 1; fi

  file="$project/${SHIPMATE_LOG_FILE:-captains-log.md}"
  entry="- $(date '+%Y-%m-%d %H:%M') — $rest"
  if [ ! -f "$file" ]; then printf '# Captain'\''s log\n\n' > "$file"; fi
  printf '%s\n' "$entry" >> "$file"

  if git -C "$project" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$project" add "$(basename "$file")" 2>/dev/null || true
    git -C "$project" commit -q -m "Log: $(printf '%s' "$rest" | cut -c1-60)" 2>/dev/null || true
    if [ "$mode" = "execute" ]; then
      if git -C "$project" push -q 2>/dev/null; then
        speak "Logged to $pname and pushed — if it deploys on push, that entry is going live."
      else
        speak "Logged and committed to $pname, but the push failed — it's saved locally."
      fi
    else
      speak "Logged to $pname. Committed locally — end with 'ship it' to publish."
    fi
  else
    speak "Logged to $pname. Not a git repo, so it's just in the file."
  fi
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
  heard_record "$(ledger_channel)" "$(basename "$project")" "work on $task" "started job $id"
  speak "Job $id started on $(basename "$project"): $(printf '%s' "$task" | clip 100). I'll ping you when it's done, or ask me for status."
}

job_runner() { # <job dir> — runs headless, writes result/status, pushes a notification
  local jdir="$1" task project prompt out result status
  local start_branch=""
  task="$(cat "$jdir/task")"; project="$(cat "$jdir/project")"
  cd "$project" 2>/dev/null || { speak "I can't find the project directory for $(basename "$project")."; return 1; }
  start_branch="$(git branch --show-current 2>/dev/null || true)"
  prompt="Background agent job; no human is watching, so never ask questions — decide and proceed. Task: \"$task\".
Rules: work on a NEW git branch and never commit to or push the default branch (a push there can trigger a production deploy). Run the project's tests if it has any. NEVER deploy, publish, create infrastructure, or take any action that costs money — if the task needs that, prepare everything and stop. End your reply with 'SUMMARY:' followed by 2-3 plain sentences suitable to be read aloud."
  # Workers are untrusted by design: the allowlist lets them branch, edit, build and test, and
  # contains no `git push` and no provider CLI — shipping passes back through the gate. Headless
  # runs have nobody to approve a prompt, so anything outside this list is simply refused.
  # (--allowedTools is variadic: keep it ahead of the other flags or it swallows the prompt.)
  job_tools="${SHIPMATE_VOICE_JOB_TOOLS:-Bash(git status:*),Bash(git branch:*),Bash(git checkout:*),Bash(git switch:*),Bash(git add:*),Bash(git commit:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git stash:*),Bash(git rev-parse:*),Bash(git merge-base:*),Bash(npm:*),Bash(npx:*),Bash(node:*),Bash(pnpm:*),Bash(yarn:*),Bash(bun:*),Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(rg:*),Bash(find:*)}"
  if out="$(claude -p --allowedTools "$job_tools" --output-format json --permission-mode acceptEdits \
      ${SHIPMATE_VOICE_CLAUDE_ARGS:-} "$prompt" 2>"$jdir/err")"; then
    result="$(printf '%s' "$out" | json_get result)"; status="done"
    if [ -z "$result" ]; then result="Finished, but no summary came back."; fi
  else
    result="The job hit an error: $(tail -n1 "$jdir/err" 2>/dev/null | clip 200)"; status="failed"
  fi
  # The worker branched; put the checkout back where the driver left it so the next "ship it"
  # starts from the production branch (preflight insists on it). The job branch stays to merge.
  local end_branch; end_branch="$(git branch --show-current 2>/dev/null || true)"
  if [ -n "$start_branch" ] && [ "$end_branch" != "$start_branch" ]; then
    if [ -z "$(git status --porcelain 2>/dev/null)" ] && git checkout -q "$start_branch" 2>/dev/null; then
      result="$result Branch $end_branch has the work; the checkout is back on $start_branch."
      printf '%s' "$end_branch" > "$jdir/branch"
    else
      result="$result Note: the checkout is still on $end_branch with uncommitted changes."
    fi
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
  # Problems first: what the sentinel has open is the thing a driver most needs to hear.
  local key since short dtl
  while IFS='|' read -r key since short dtl; do
    [ -n "$key" ] && line="$line ${key%.*}: $short, for $(sentinel_ago "$((now - since))")."
  done <<EOF
$(sentinel_open)
EOF
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
  appsh="$VOICE_DIR/../skills/deploy/bin/app.sh"
  plist="$( { if [ -f "$STATE_DIR/session.project" ]; then cat "$STATE_DIR/session.project"; echo; fi
              for d in "$JOBS_DIR"/*/; do
                if [ -d "$d" ]; then cat "$d/project" 2>/dev/null; echo; fi
              done; } | awk 'NF' | sort -u )"
  while IFS= read -r p; do
    [ -n "$p" ] && [ "$(provider_of "$p")" != none ] || continue
    phase="$(bash "$appsh" status "$p" 2>/dev/null | awk -F': *' '/^deploy:/{print $2}' | awk '{print $1}')"
    [ -n "$phase" ] && line="$line $(basename "$p") production deploy: $phase."
  done <<EOF
$plist
EOF
  if [ -f "$GATE_FILE" ]; then
    local g gp
    gp="$(gate_field project)"
    if g="$(gate_peek "$gp")"; then
      line="$line A plan for $gp is waiting for ship it, $(( $(printf '%s' "$g" | awk '{print $3}') / 60 )) minutes left."
    fi
  fi
  if [ -n "$line" ]; then speak "$(printf '%s' "$line" | clip 1200)"
  else speak "All quiet: nothing is down, and no jobs yet. Say 'work on' something to start one."; fi
}

# verb_rollback <project dir> <mode> — deterministic (no model in the loop): a panicked
# "roll back, confirm" is a code path. Plan mode describes; execute reverts via the DO API.
verb_rollback() { # <project> <plan|execute> [forward] — deterministic, no model in the loop
  local project="$1" mode="$2" dir="${3:-back}" appsh out pname verb prov
  appsh="$VOICE_DIR/../skills/deploy/bin/app.sh"
  pname="$(basename "$project")"; prov="$(bash "$appsh" provider "$project")"
  verb=rollback; [ "$dir" = forward ] && verb=roll-forward
  if [ "$prov" = none ]; then
    speak "I don't know where $pname is deployed — it has no DigitalOcean or Vercel link. Tell me which project you mean."
    return 1
  fi
  if [ "$mode" = "execute" ]; then
    if out="$(bash "$appsh" "$verb" "$project" --yes 2>&1)"; then
      ledger_record "$verb" executed "$pname" "roll $dir $pname" "$prov: $(printf '%s' "$out" | tail -n1)" >/dev/null
      speak "$(printf '%s' "$out" | tail -n1 | sed 's/^✓ *//') Cost neutral. Ask me for status in a minute to confirm."
    else
      ledger_record "$verb" failed "$pname" "roll $dir $pname" "$prov: $(printf '%s' "$out" | tail -n1)" >/dev/null
      speak "Roll $dir failed: $(printf '%s' "$out" | tail -n1 | clip 200)"
      return 1
    fi
  else
    out="$(bash "$appsh" "$verb" "$project" 2>&1 || true)"
    case "$(printf '%s' "$out" | tail -n1)" in
      Would*) speak "$(printf '%s' "$out" | tail -n1 | sed -E 's/^Would /This would /') To do it, say: roll $dir $pname, confirm." ;;
      *)      speak "$(printf '%s' "$out" | tail -n1 | sed -E 's/^[✓✗] *//')" ;;
    esac
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
    PROJ="$(project_for "$(phrase_normalize "$3")")"
    shift 3; turn "$*" "$MODE" "$PROJ"; exit $? ;;
  --dispatch)
    PROJ="$(project_for "$(phrase_normalize "$2")")"
    shift 2; dispatch_job "$*" "$PROJ"; exit 0 ;;
  --status-report) verb_status; exit 0 ;;
  --result)        verb_result "job ${2:-}"; exit 0 ;;
  --stop)          verb_stop "job ${2:-}"; exit 0 ;;
  --counsel)
    PROJ="$(project_for "$(phrase_normalize "$2")")"
    shift 2; counsel "$*" "$PROJ"; exit $? ;;
  --counsel-set)
    case "${2:-}" in on|off) counsel_toggle "$2"; exit 0 ;; esac
    speak "usage: --counsel-set <on|off>"; exit 1 ;;
  --rollback)
    PROJ="$(project_for "$(phrase_normalize "${2:-}")")"
    MODE="plan"; DIRN="back"
    for a in "${@:3}"; do case "$a" in --yes) MODE="execute" ;; --forward) DIRN="forward" ;; esac; done
    verb_rollback "$PROJ" "$MODE" "$DIRN"; exit $? ;;
  --doctor)   verb_doctor; exit 0 ;;
  --remember) # <fact|reminder> <text…> — the kind is always explicit, so no text reads as a flag
    case "${2:-}" in fact|reminder) K="$2"; shift 2; verb_remember "$*" "$K"; exit 0 ;; esac
    speak "usage: --remember <fact|reminder> <text>"; exit 1 ;;
  --forget)   shift; verb_forget "$(phrase_normalize "$*")" forget; exit 0 ;;
  --done)     shift; verb_forget "$(phrase_normalize "$*")" done; exit 0 ;;
  --recall)   verb_recall; verb_recap; exit 0 ;;
  --briefing) if [ "${2:-}" = --push ]; then verb_brief push; else verb_brief; fi; exit 0 ;;
  --watchdog) verb_watchdog; exit 0 ;;
  --verify-live) verify_live "$2" "$3"; exit 0 ;;
  --log)
    PROJ="${2:-}"; shift 2
    PUB="plan"; if [ "${1:-}" = "--publish" ]; then PUB="execute"; shift; fi
    if [ "$PROJ" = "-" ]; then verb_log "$*" "$PUB"; else verb_log "to $PROJ $*" "$PUB"; fi
    exit $? ;;
esac

# Opportunistic queue flush: any utterance while online drains the dead-zone backlog.
if [ -d "$STATE_DIR/queue" ] && [ -n "$(ls "$STATE_DIR/queue" 2>/dev/null)" ]; then
  nohup bash "$SELF" --flush-queue >/dev/null 2>&1 &
fi

PHRASE="${*:-}"
# No argument? Read stdin — Shortcuts' "Run Script Over SSH" passes its Input that way. With a
# deadline: an empty dictation leaves the SSH channel open and silent, and a plain `cat` would
# wait on it forever (the phone shows a spinner, the Mac keeps a bridge process for hours).
read_stdin() { # [seconds] — stdin → text, or whatever arrived before the deadline
  local line="" acc="" t="${1:-10}"
  while IFS= read -r -t "$t" line; do acc="$acc$line"$'\n'; done
  [ -n "$line" ] && acc="$acc$line"      # final line without a newline (printf '%s' input)
  printf '%s' "$acc"
}
if [ -z "$PHRASE" ] && [ ! -t 0 ]; then PHRASE="$(read_stdin "${SHIPMATE_STDIN_TIMEOUT:-10}")"; fi
if [ -z "$PHRASE" ]; then speak "shipmate: I didn't catch that — tell me what to ship."; exit 1; fi

NORM="$(phrase_normalize "$PHRASE")"

# Fleet routing: "at home …" / "on the laptop …" runs the rest on that host. Only fires
# when the alias is registered in ~/.shipmate/hosts — idioms fall through untouched.
ROUTE="$(phrase_route "$NORM")"
# (not from a read-only channel: the other host's bridge wouldn't know the phrase was read-only)
if [ -n "$ROUTE" ] && [ "$ROUTE" != "${ROUTE#* }" ] && [ "${SHIPMATE_READONLY:-}" != 1 ]; then
  if route_to_host "${ROUTE%% *}" "${ROUTE#* }"; then exit 0; fi
fi

MODE="$(phrase_mode "$NORM")"
CLEAN="$(phrase_strip_confirm "$NORM")"
# A bare "confirm" / "do it" utterance means: execute what the session just planned.
if [ -z "$CLEAN" ] && [ "$MODE" = "execute" ]; then CLEAN="go ahead with what we just discussed"; fi
VERB="$(phrase_verb "$CLEAN")"

# A read-only channel (the glasses: SHIPMATE_READONLY=1, set by the server for shipmate:read
# tokens) can ask, brief, recall and plan. Anything more is refused in code and recorded.
if [ "${SHIPMATE_READONLY:-}" = 1 ]; then
  WHY="$(phrase_readonly_refusal "$VERB" "$MODE")"
  if [ -n "$WHY" ]; then
    P="$(resolve_project "$CLEAN")"; ledger_record scope refused "${P:+$(basename "$P")}" "$PHRASE" "read-only channel: $WHY" >/dev/null
    case "$WHY" in
      ship)    speak "I heard ship it, but the glasses can only plan. Tap Ship it on your phone, or say it to Siri." ;;
      memory)  speak "The glasses can't change what I remember. Say it to Siri or the Claude app." ;;
      *)       speak "The glasses are read-only, so I can't do that from here. Say it to Siri or the Claude app." ;;
    esac
    exit 0
  fi
fi

case "$VERB" in
  new)    rm -f "$STATE_DIR/session.id" "$STATE_DIR/session.project"; speak "Fresh session." ;;
  status) verb_status ;;
  result) verb_result "$CLEAN" ;;
  stop)   verb_stop "$CLEAN" ;;
  counsel_on)  counsel_toggle on ;;
  counsel_off) counsel_toggle off ;;
  doctor)   verb_doctor ;;
  brief)    verb_brief ;;
  remember) verb_remember "$(phrase_memory_body "$CLEAN")" fact ;;
  remind)   verb_remember "$(phrase_memory_body "$CLEAN")" reminder ;;
  forget)   verb_forget "$(phrase_memory_body "$CLEAN")" forget ;;
  done)     verb_forget "$(phrase_memory_body "$CLEAN")" done ;;
  recall)   verb_recall ;;
  recap)    verb_recap ;;
  log)      verb_log "$(phrase_log_body "$CLEAN")" "$MODE" ;;
  rollback) verb_rollback "$(project_for "$CLEAN")" "$MODE" ;;
  rollforward) verb_rollback "$(project_for "$CLEAN")" "$MODE" forward ;;
  counsel) run_or_queue counsel "$MODE" "$(project_for "$CLEAN")" "$(phrase_counsel_question "$CLEAN")" ;;
  job)    run_or_queue job "$MODE" "$(project_for "$CLEAN")" "$(phrase_task "$CLEAN")" ;;
  say)    run_or_queue say "$MODE" "$(project_for "$CLEAN")" "$CLEAN" ;;
esac
