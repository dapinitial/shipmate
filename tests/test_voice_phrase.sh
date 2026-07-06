#!/usr/bin/env bash
# Tests for the voice-bridge phrase parser (voice/lib/phrase.sh).
# This code decides plan vs execute for spoken commands against billed infra — a parsing bug
# could turn a misheard sentence into an execute. So it gets the same treatment as envspec.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../voice/lib/phrase.sh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }

echo "normalize (dictation punctuation and case):"
ok "strips trailing period + comma" "$(phrase_normalize 'Deploy Panogram, confirm.')" "deploy panogram confirm"
ok "squeezes whitespace"            "$(phrase_normalize '  deploy    panogram ')"      "deploy panogram"
ok "keeps apostrophes"              "$(phrase_normalize "How's it going?")"             "how's it going"
ok "empty stays empty"              "$(phrase_normalize '')"                            ""

echo "mode (execute only on an explicit trailing confirm):"
ok "bare request is plan"           "$(phrase_mode 'deploy panogram')"                  plan
ok "trailing confirm executes"      "$(phrase_mode 'deploy panogram confirm')"          execute
ok "trailing do it executes"        "$(phrase_mode 'deploy panogram do it')"            execute
ok "trailing send it executes"      "$(phrase_mode 'resize the app send it')"           execute
ok "trailing ship it executes"      "$(phrase_mode 'ship it')"                          execute
ok "mid-sentence confirm is plan"   "$(phrase_mode 'confirm the dns record exists')"    plan
ok "question stays plan"            "$(phrase_mode 'what would it cost to deploy')"     plan

echo "strip_confirm:"
ok "removes trailing confirm" "$(phrase_strip_confirm 'deploy panogram confirm')" "deploy panogram"
ok "removes trailing do it"   "$(phrase_strip_confirm 'deploy panogram do it')"   "deploy panogram"
ok "leaves plain phrases"     "$(phrase_strip_confirm 'deploy panogram')"         "deploy panogram"
ok "leaves mid-phrase words"  "$(phrase_strip_confirm 'confirm the record')"      "confirm the record"
ok "bare confirm strips to empty" "$(phrase_strip_confirm 'confirm')"             ""
ok "bare do it strips to empty"   "$(phrase_strip_confirm 'do it')"               ""

echo "verb routing:"
ok "status"              "$(phrase_verb 'status')"                                    status
ok "any update"          "$(phrase_verb 'any updates')"                               status
ok "how's it going"      "$(phrase_verb "how's it going")"                            status
ok "result"              "$(phrase_verb 'result')"                                    result
ok "result of job 2"     "$(phrase_verb 'result of job 2')"                           result
ok "what happened"       "$(phrase_verb 'what happened with job 3')"                  result
ok "stop job"            "$(phrase_verb 'stop job 3')"                                stop
ok "cancel"              "$(phrase_verb 'cancel job 2')"                              stop
ok "new session"         "$(phrase_verb 'new session')"                               new
ok "start over"          "$(phrase_verb 'start over')"                                new
ok "work on = job"       "$(phrase_verb 'work on adding dark mode to panogram')"      job
ok "have an agent = job" "$(phrase_verb 'have an agent fix the failing tests')"       job
ok "in the background"   "$(phrase_verb 'add tests to panogram in the background')"   job
ok "deploy = say"        "$(phrase_verb 'deploy panogram')"                           say
ok "question = say"      "$(phrase_verb 'what will that cost per month')"             say
ok "stopword not stop"   "$(phrase_verb 'deploy the stopwatch app')"                  say
ok "roll back"           "$(phrase_verb 'roll back panogram')"                        rollback
ok "rollback one word"   "$(phrase_verb 'rollback panogram')"                         rollback
ok "undo the deploy"     "$(phrase_verb 'undo the deploy on panogram')"               rollback
ok "counsel on (exact)"  "$(phrase_verb 'counsel on')"                                counsel_on
ok "counsel off (exact)" "$(phrase_verb 'counsel off')"                               counsel_off
ok "counsel question"    "$(phrase_verb 'counsel on whether to move to vercel')"      counsel
ok "deliberate question" "$(phrase_verb 'deliberate about the dns migration')"        counsel
ok "convene the counsel" "$(phrase_verb 'convene the counsel should we resize')"      counsel

echo "counsel question extraction:"
ok "strips counsel on"      "$(phrase_counsel_question 'counsel on whether to move to vercel')" "whether to move to vercel"
ok "strips convene"         "$(phrase_counsel_question 'convene the counsel should we resize')" "should we resize"
ok "strips ask the counsel" "$(phrase_counsel_question 'ask the counsel about caching')"        "caching"
ok "strips deliberate"      "$(phrase_counsel_question 'deliberate about the dns migration')"   "the dns migration"

echo "job id extraction:"
ok "digits"        "$(phrase_job_id 'stop job 3')"          3
ok "spoken number" "$(phrase_job_id 'result of job two')"   2
ok "first number"  "$(phrase_job_id 'job 12 not 9')"        12
ok "none is empty" "$(phrase_job_id 'stop the job')"        ""

echo "task extraction:"
ok "work on"            "$(phrase_task 'work on adding dark mode')"                    "adding dark mode"
ok "have an agent to"   "$(phrase_task 'have an agent to fix the tests')"              "fix the tests"
ok "background suffix"  "$(phrase_task 'work on adding dark mode in the background')"  "adding dark mode"
ok "plain passthrough"  "$(phrase_task 'upgrade astro')"                               "upgrade astro"

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
