#!/usr/bin/env bash
# Tests for the briefing (skills/deploy/bin/briefing.sh): what needs you, what happened since
# the last briefing. It is read aloud and pushed unattended, so it must say only what the
# records show: no reconstructed history passed off as news, no "quiet" when the sentinel
# hasn't looked, and its window only moves when the daily push says so.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/../skills/deploy/bin"; . "$DIR/../voice/lib/phrase.sh"
command -v python3 >/dev/null 2>&1 || { echo "• python3 missing — skipping briefing tests"; exit 0; }
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"; trap 'rm -rf "$TMP"' EXIT
export TZ=America/Los_Angeles HOME="$TMP/home"
export SHIPMATE_LEDGER="$TMP/ledger.jsonl" SHIPMATE_SENTINEL_DIR="$TMP/sentinel" SHIPMATE_SENTINEL_LOG="$TMP/sentinel.jsonl" \
  SHIPMATE_VOICE_STATE="$TMP/voice" SHIPMATE_APPROVALS_DIR="$TMP/approvals" SHIPMATE_PLAN_GRANT="$TMP/plan-grant.json" \
  SHIPMATE_BRIEFING_MARK="$TMP/briefing.last" SHIPMATE_MEMORY="$TMP/memory.jsonl"
mkdir -p "$TMP/home" "$TMP/sentinel"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3] in: $2"; fail=$((fail+1)); fi; }
hasnt() { if printf '%s' "$2" | grep -q -F -- "$3"; then echo "  ✗ $1: should not say [$3] in: $2"; fail=$((fail+1)); else pass=$((pass+1)); fi; }

# "now" is Saturday 2026-10-17 07:30 PDT; the last briefing was Friday 07:30 PDT
NOW=1792247400; export SHIPMATE_NOW=$NOW
iso() { python3 -c 'import sys,datetime as d; print(d.datetime.fromtimestamp(int(sys.argv[1]), d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
fresh() { for f in "$TMP"/sentinel/*; do touch "$f"; done; }   # the sentinel just ran
B() { bash "$BIN/briefing.sh" "$@" 2>&1; }

echo "quiet:"
for p in unakin panogram rillet; do printf 'ok|0|%s||\n' "$NOW" > "$TMP/sentinel/$p.site"; done; fresh
out="$(B)"
ok "no marker: the last 24 hours, said plainly" "$out" "Since yesterday at 7:30 AM: Quiet: nothing shipped, nothing broke. All 3 projects are answering."
touch -t 202610170500 "$TMP"/sentinel/*
has "a stale sentinel is admitted, not called quiet" "$(B)" "The sentinel hasn't checked the fleet in 2 hours, so the live picture may be out of date."
hasnt "…and it doesn't claim all are answering" "$(B)" "projects are answering"
fresh

echo "what happened:"
L() { printf '{"id":"x","ts":"%s","type":"decision","policy":"%s","outcome":"%s","project":"%s","attempted":"%s","channel":"siri","detail":"%s"}\n' "$(iso "$1")" "$2" "$3" "$4" "$5" "$6" >> "$SHIPMATE_LEDGER"; }
L $((NOW-90000)) ship executed old 'ship it' ''                       # before the window
L $((NOW-36000)) ship executed unakin 'ship it' ''
L $((NOW-35000)) ship executed unakin 'ship it' ''
L $((NOW-30000)) ship executed rillet 'ship it' ''
L $((NOW-29000)) verify-live failed rillet 'deploy abc1234' 'deployment failed'
L $((NOW-20000)) rollback executed unakin 'roll back unakin' ''
L $((NOW-10000)) pre-push:remote refused unakin 'push mirror' 'wrong remote'
L $((NOW-9000)) plan-grant downgraded panogram 'ship it' 'no grant'
L $((NOW-8000)) pre-push:override overridden portfolio 'push' 'SHIPMATE_ALLOW=max-files'
L $((NOW-100)) none missed unakin 'push' 'Reconstructed from 2026-09-11 history.'
printf '{"type":"note","ts":"%s","ref":"x","note":"a human note"}\n' "$(iso $((NOW-50)))" >> "$SHIPMATE_LEDGER"
printf '{"ts":"%s","type":"observation","project":"panogram","check":"site","outcome":"open","detail":"x"}\n' "$(iso $((NOW-7000)))" >> "$SHIPMATE_SENTINEL_LOG"
printf '{"ts":"%s","type":"observation","project":"panogram","check":"site","outcome":"clear","detail":"x","lasted":720}\n' "$(iso $((NOW-6280)))" >> "$SHIPMATE_SENTINEL_LOG"
mkdir -p "$TMP/voice/jobs/4"; echo done > "$TMP/voice/jobs/4/status"; echo "$TMP/sites/panogram" > "$TMP/voice/jobs/4/project"; echo $((NOW-5000)) > "$TMP/voice/jobs/4/finished"
mkdir -p "$TMP/voice/jobs/3"; echo done > "$TMP/voice/jobs/3/status"; echo $((NOW-200000)) > "$TMP/voice/jobs/3/finished"
out="$(B)"
has "outage with how long, and recovery" "$out" "panogram was down for 12 minutes, and recovered."
has "ships counted per project"  "$out" "Shipped rillet and unakin twice."
hasnt "nothing before the window" "$out" "old"
has "a deploy that didn't go live" "$out" "rillet: deploy abc1234 did not go live (deployment failed)."
has "rollback"                   "$out" "unakin was rolled back."
has "gate holds, by project"     "$out" "The gate held back 2 requests: 1 on panogram and 1 on unakin."
has "overrides, facts only"      "$out" "The push guard was overridden once: 1 on portfolio."
has "a job that finished"        "$out" "Job 4 on panogram finished: done."
hasnt "an older job is old news" "$out" "Job 3"
hasnt "reconstructed history is not news" "$out" "missed"

echo "needs you:"
printf 'open|2|%s|down|https://unakin 503\n' "$((NOW-7200))" > "$TMP/sentinel/unakin.site"; fresh
mkdir -p "$TMP/approvals"; printf 'pending\nCreate panogram-api ($5/mo)\n' > "$TMP/approvals/n1"; printf 'approved\nold\n' > "$TMP/approvals/n2"
python3 -c 'import json,sys; json.dump({"project":"rillet","ts":(int(sys.argv[1])-120)*1000}, open(sys.argv[2],"w"))' "$NOW" "$SHIPMATE_PLAN_GRANT"
mkdir -p "$TMP/voice/queue/q1" "$TMP/voice/queue/q2"
M() { printf '{"op":"%s","id":"%s","ref":"%s","t":%s,"kind":"%s","text":"%s"}\n' "$@" >> "$SHIPMATE_MEMORY"; }
M add r1 '' $((NOW-90000)) reminder 'check panogram logs'; M add r2 '' $((NOW-80000)) reminder 'renew the domain'
M add f1 '' $((NOW-70000)) fact 'the freeze is on fridays'; M done '' r2 $((NOW-1000)) '' ''
out="$(B)"
has "open reminders are in what needs you" "$out" "You asked me to remind you to check panogram logs."
hasnt "a checked-off reminder is not"       "$out" "renew the domain"
hasnt "facts are not reminders"             "$out" "freeze"
has "reminder line for the glasses"         "$(B --lines)" "remind: check panogram logs"
has "needs you comes first"      "$out" "Since yesterday at 7:30 AM: Needs you: unakin is down, for 2 hours."
has "a pending approval, not an answered one" "$out" "1 spend approval waiting for your tap: Create panogram-api (\$5/mo)."
has "the armed plan"             "$out" "A plan for rillet is armed, 8 minutes left to say ship it."
has "the queue"                  "$out" "2 requests queued from a dead zone"
hasnt "not all answering while one is down" "$out" "projects are answering"

echo "lines (glasses):"
out="$(B --lines)"
ok "first line is the window"    "$(printf '%s\n' "$out" | head -1)" "since yday 7:30 AM"
ok "then what needs you"         "$(printf '%s\n' "$out" | sed -n 2p)" "!! unakin down 2h"
has "outage line"                "$out" "panogram down 12m, ok now"
has "ships line"                 "$out" "shipped rillet, unakin x2"
ok "every line fits the display" "$(printf '%s\n' "$out" | awk 'length($0) > 44' | wc -l | tr -d ' ')" 0

echo "window:"
ok "no marker yet"               "$([ -e "$SHIPMATE_BRIEFING_MARK" ] && echo yes || echo no)" no
B >/dev/null; B --lines >/dev/null
ok "asking never moves the window" "$([ -e "$SHIPMATE_BRIEFING_MARK" ] && echo yes || echo no)" no
B --mark >/dev/null
ok "--mark starts the next window now" "$(cat "$SHIPMATE_BRIEFING_MARK")" "$NOW"
out="$(SHIPMATE_NOW=$((NOW+3600)) B)"
has "after the mark: since this morning" "$out" "Since 7:30 AM this morning:"
hasnt "…and the night's news is gone" "$out" "Shipped"
has "…but what needs you still does" "$out" "unakin is down"
echo $((NOW-30*86400)) > "$SHIPMATE_BRIEFING_MARK"
has "a month-old marker is capped at a week" "$(B)" "Since October 10:"
has "--hours overrides the marker" "$(B --hours 2)" "Since 5:30 AM this morning:"

echo "phrases:"
ok "good morning → brief"        "$(phrase_verb 'good morning')" brief
ok "what did i miss → brief"     "$(phrase_verb 'what did i miss')" brief

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
