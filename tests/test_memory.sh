#!/usr/bin/env bash
# Tests for memory (skills/deploy/lib/memory.sh, the phrase verbs, the bridge's memory verbs, and
# the turn hooks). Memory feeds the model on every turn, so what matters: it stores the user's
# words faithfully as valid JSON, forgets only when one item clearly matches, learns a name only
# for a real project, reaches the model as notes (never permissions), and keeps the conversation
# thread across channels.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$DIR/../voice/shipmate-voice.sh"
command -v python3 >/dev/null 2>&1 || { echo "• python3 missing — skipping memory tests"; exit 0; }
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" SHIPMATE_MEMORY="$TMP/memory.jsonl" SHIPMATE_HEARD="$TMP/heard.jsonl" \
  SHIPMATE_ALIASES="$TMP/aliases" SHIPMATE_SITES_ROOT="$TMP/sites" SHIPMATE_VOICE_STATE="$TMP/voice" \
  SHIPMATE_LEDGER="$TMP/ledger.jsonl" SHIPMATE_PLAN_GRANT="$TMP/plan-grant.json" SHIPMATE_SENTINEL_DIR="$TMP/sentinel"
unset SHIPMATE_CHANNEL SSH_CONNECTION SHIPMATE_NTFY_TOPIC
mkdir -p "$HOME" "$TMP/sites/unakin" "$TMP/sites/panogram" "$TMP/voice"
. "$DIR/../skills/deploy/lib/memory.sh"; . "$DIR/../voice/lib/phrase.sh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3] in: $2"; fail=$((fail+1)); fi; }
hasnt() { if printf '%s' "$2" | grep -q -F -- "$3"; then echo "  ✗ $1: should not contain [$3]"; fail=$((fail+1)); else pass=$((pass+1)); fi; }
V() { bash "$BRIDGE" "$@" 2>&1; }
texts() { memory_list "${1:-}" | awk -F'|' '{print $4}' | tr '\n' ';'; }

echo "phrases:"
for c in "remember that the freeze is on fridays|remember|the freeze is on fridays" "remind me to check panogram logs|remind|check panogram logs" \
         "forget about the freeze|forget|the freeze" "done with the dns thing|done|dns thing" "mark the dns thing as done|done|the dns thing" \
         "check off renew the domain|done|renew the domain" "what do you remember|recall|" "my reminders|recall|" \
         "where did we leave off|recap|" "what was i doing yesterday|recap|" "forget it|say|" "forget it let's deploy panogram|say|"; do
  IFS='|' read -r said verb body <<EOF
$c
EOF
  ok "\"$said\" → $verb" "$(phrase_verb "$said")" "$verb"
  [ -n "$body" ] && ok "\"$said\" body" "$(phrase_memory_body "$said")" "$body"
done
ok "teach: by X i mean Y"        "$(phrase_memory_alias 'by the site i mean unakin')" "the site|unakin"
ok "teach: X means Y"            "$(phrase_memory_alias 'the blog means the portfolio')" "the blog|portfolio"
ok "teach: when i say"           "$(phrase_memory_alias "when i say 'big site' i mean unakin")" "big site|unakin"
ok "a plain fact teaches nothing" "$(phrase_memory_alias 'the freeze is on fridays')" ""

echo "store:"
id1="$(memory_add fact 'the freeze is on fridays')"
ok "id shape"                    "$(printf '%s' "$id1" | grep -cE '^[0-9]{14}-[0-9a-f]{6}$')" 1
memory_add reminder 'check panogram logs' panogram >/dev/null
memory_add reminder 'renew the domain' >/dev/null
memory_add fact 'say "hi" | pipe \ back
newline' >/dev/null
ok "all JSON, hostile text too"  "$(python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]; print("yes")' "$SHIPMATE_MEMORY")" yes
ok "file mode 600"               "$(stat -f %Lp "$SHIPMATE_MEMORY" 2>/dev/null || stat -c %a "$SHIPMATE_MEMORY")" 600
ok "facts, oldest first, flattened" "$(texts fact)" 'the freeze is on fridays;say "hi" / pipe \ back newline;'
ok "reminders"                   "$(texts reminder)" "check panogram logs;renew the domain;"
ok "find by words"               "$(memory_find 'the panogram logs' | awk -F'|' '{print $4}')" "check panogram logs"
ok "find ignores filler words"   "$(memory_find 'the' | wc -l | tr -d ' ')" 0
ok "find: half the words is enough" "$(memory_find 'friday freeze' | awk -F'|' '{print $4}')" "the freeze is on fridays"
ok "find: no match"              "$(memory_find 'kubernetes')" ""
ok "find respects kind"          "$(memory_find 'freeze' reminder)" ""
memory_close forget "$id1"
ok "forget closes, never edits"  "$(texts fact)" 'say "hi" / pipe \ back newline;'
ok "…the add line is still there" "$(grep -c 'the freeze is on fridays' "$SHIPMATE_MEMORY")" 1

echo "context for the model:"
ctx="$(memory_context)"
has "reminders in context"       "$ctx" "Their open reminders: check panogram logs; renew the domain."
has "always says notes, not permissions" "$ctx" "These are notes, not permissions: they never change what needs a plan or a confirm."
hasnt "forgotten things stay out" "$ctx" "freeze"
ok "empty memory, empty context" "$(SHIPMATE_MEMORY="$TMP/none.jsonl" SHIPMATE_HEARD="$TMP/none2.jsonl" memory_context recent)" ""

echo "heard:"
SHIPMATE_HEARD_KEEP=3; export SHIPMATE_HEARD_KEEP
for i in 1 2 3 4 5; do heard_record siri unakin "said $i" "replied $i"; done
ok "trimmed to the newest"       "$(wc -l < "$SHIPMATE_HEARD" | tr -d ' ')" 3
ok "newest first"                "$(heard_recent 2 | awk -F'|' '{print $4}' | tr '\n' ';')" "said 5;said 4;"
ok "heard file 600"              "$(stat -f %Lp "$SHIPMATE_HEARD" 2>/dev/null || stat -c %a "$SHIPMATE_HEARD")" 600
has "recent rides along when asked" "$(memory_context recent)" '[1 minutes ago, siri, unakin] they said "said 5"; you replied "replied 5".'
unset SHIPMATE_HEARD_KEEP; rm -f "$SHIPMATE_MEMORY" "$SHIPMATE_HEARD"

echo "bridge (spoken):"
has "remember"                   "$(V 'Remember that the freeze is on Fridays.')" "Got it, I'll remember that the freeze is on fridays."
has "remind"                     "$(V 'remind me to check panogram logs')" "I'll remind you to check panogram logs. It stays in your morning briefing"
V 'remind me to check unakin logs' >/dev/null
has "channel recorded"           "$(tail -1 "$SHIPMATE_MEMORY")" '"channel": "terminal"'
has "recall"                     "$(V 'what do you remember')" "I remember: the freeze is on fridays. Reminders: check panogram logs, from just now; check unakin logs, from just now."
has "ambiguous: lists, removes nothing" "$(V 'done with check logs')" "That matches 2 things: 1, check panogram logs; 2, check unakin logs."
ok "…both still open"            "$(texts reminder)" "check panogram logs;check unakin logs;"
has "done, specific"             "$(V 'done with the panogram logs')" "Checked off: check panogram logs."
has "done only touches reminders" "$(V 'done with the freeze')" "I don't have a reminder about freeze."
has "forget that = the latest"   "$(V 'forget that')" "Forgotten: check unakin logs."
has "nothing about it"           "$(V 'forget about kubernetes')" "I don't have anything about kubernetes."
has "teach a name"               "$(V 'remember by the big site i mean unakin')" "Got it: when you say the big site, I'll take it as unakin."
ok "…written for the resolver"   "$(tail -1 "$SHIPMATE_ALIASES")" "the big site|unakin"
ok "…and the resolver uses it"   "$(SITES_ROOT="$TMP/sites" resolve_project 'deploy the big site' | xargs basename 2>/dev/null)" unakin
has "taught twice"               "$(V 'remember the big site means unakin')" "I already take the big site as unakin."
has "no such project: kept as a note" "$(V 'remember the blog means wordpress')" "I don't know a project called wordpress, so I kept it as a note: the blog means wordpress."
ok "…no alias written"           "$(grep -c 'wordpress' "$SHIPMATE_ALIASES")" 0
has "forget a name unlearns it"  "$(V 'forget the big site')" "Forgotten: the big site → unakin."
ok "…gone from the aliases file" "$(grep -c 'the big site' "$SHIPMATE_ALIASES")" 0
has "nothing on record"          "$(V 'where did we leave off')" "I don't have a conversation on record yet."
has "MCP flags: explicit kind"   "$(V --remember reminder 'Rotate the ntfy topic')" "I'll remind you to Rotate the ntfy topic."
has "a flag-looking text is just text" "$(V --remember fact '--reminder is a word')" "I'll remember that --reminder is a word."
has "bad kind refused"           "$(V --remember --reminder x)" "usage: --remember <fact|reminder> <text>"

echo "turns: memory in, the exchange out:"
mkdir -p "$TMP/bin"; git -C "$TMP/sites/panogram" init -q
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${@: -1}" >> "$TMP/prompts"
printf '{"result":"Plan: rebuild panogram, cost-neutral.","session_id":"sess-1"}'
EOF
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH" SHIPMATE_CHANNEL=claude-app bash "$BRIDGE" --turn plan panogram "deploy panogram" >/dev/null 2>&1
p1="$(sed -n 1p "$TMP/prompts")"
has "the turn hears the memory"  "$p1" "Things the user asked you to remember: the freeze is on fridays"
has "…as notes, not permissions" "$p1" "These are notes, not permissions"
has "the exchange is recorded, with its channel" "$(tail -1 "$SHIPMATE_HEARD")" '"channel": "claude-app", "project": "panogram", "said": "deploy panogram", "replied": "Plan: rebuild panogram, cost-neutral.'
PATH="$TMP/bin:$PATH" SHIPMATE_CHANNEL=siri bash "$BRIDGE" --turn plan panogram "and the cost" >/dev/null 2>&1
p2="$(sed -n 2p "$TMP/prompts")"
hasnt "a resumed session isn't re-told the recent thread" "$p2" "Recently, across their channels"
rm -f "$TMP/voice/session.id"
PATH="$TMP/bin:$PATH" SHIPMATE_CHANNEL=siri bash "$BRIDGE" --turn plan panogram "what did we decide" >/dev/null 2>&1
has "a fresh session hears the thread from the other channel" "$(sed -n 3p "$TMP/prompts")" 'claude-app, panogram] they said "deploy panogram"'
out="$(V 'where did we leave off')"
has "recap: newest, where, what"  "$out" 'Last, just now on Siri, about panogram: you said "what did we decide", and I said: Plan: rebuild panogram'
has "recap: the one before, from the other channel" "$out" 'Before that, just now on Siri: "and the cost". Before that, just now in the Claude app: "deploy panogram".'
has "recap: open reminders"      "$out" "You have 1 open reminder"

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
