#!/usr/bin/env bash
# Tests for the decision ledger (skills/deploy/lib/ledger.sh + bin/ledger.sh) and the gates
# that write to it. The ledger is the evidence for every claim about what the gates catch, so
# it must stay valid JSON under hostile input, record allowed actions as well as refusals,
# keep human assessments separate from recorded facts, and never be edited in place.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/../skills/deploy/bin"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"; trap 'rm -rf "$TMP"' EXIT
export SHIPMATE_LEDGER="$TMP/ledger.jsonl"
unset SHIPMATE_CHANNEL SSH_CONNECTION SHIPMATE_ALLOW
. "$DIR/../skills/deploy/lib/ledger.sh"
command -v python3 >/dev/null 2>&1 || { echo "• python3 not installed — skipping ledger tests"; exit 0; }

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3]"; printf '%s\n' "$2" | sed 's/^/      /' | head -12; fail=$((fail+1)); fi; }
field() { python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][int(sys.argv[2])]; print(r.get(sys.argv[3],""))' "$SHIPMATE_LEDGER" "$1" "$2"; }
G() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

echo "records:"
id="$(ledger_record plan-grant downgraded unakin 'ship it' 'no grant (none)')"
ok "id shape"        "$(printf '%s' "$id" | grep -cE '^[0-9]{14}-[0-9a-f]{6}$')" 1
ok "policy"          "$(field 0 policy)" plan-grant
ok "outcome"         "$(field 0 outcome)" downgraded
ok "type decision"   "$(field 0 type)" decision
ok "channel default" "$(field 0 channel)" terminal
ok "file mode 600"   "$(stat -f %Lp "$SHIPMATE_LEDGER" 2>/dev/null || stat -c %a "$SHIPMATE_LEDGER")" 600

echo "hostile text stays valid JSON:"
ledger_record ship executed 'proj"x' 'say "hi" \ then
newline	tab' 'detail with \"escaped\" and \\n literal' >/dev/null
ok "every line parses" "$(python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]; print("yes")' "$SHIPMATE_LEDGER")" yes
ok "quotes kept"       "$(field 1 project)" 'proj"x'
ok "newline flattened" "$(field 1 attempted)" 'say "hi" \ then newline tab'
long="$(printf 'x%.0s' $(seq 1 600))"; ledger_record ship executed p "$long" >/dev/null
ok "capped at 400"     "$(field 2 attempted | wc -c | tr -d ' ')" 401

echo "channel:"
SHIPMATE_CHANNEL=claude-app ledger_record scope refused p tool >/dev/null; ok "explicit" "$(field 3 channel)" claude-app
SSH_CONNECTION='1 2 3 4' ledger_record ship executed p x >/dev/null;      ok "ssh → siri" "$(field 4 channel)" siri

echo "annotate + report:"
out="$(bash "$BIN/ledger.sh" annotate "$id" 'Plausible consequence: none — a status question, no change.')"
has "annotate ack" "$out" "noted on $id"
ok  "note is a separate line" "$(field 5 type)" note
ok  "decision line unchanged" "$(field 0 detail)" 'no grant (none)'
ok  "unknown id refused" "$(bash "$BIN/ledger.sh" annotate nope x >/dev/null 2>&1; echo $?)" 1
rep="$(bash "$BIN/ledger.sh" report)"
has "count table"        "$rep" "plan-grant        downgraded  1"
has "routine not flagged" "$rep" "2 decision(s) where a gate stopped"
has "note shown"          "$rep" "Plausible consequence: none"
has "unassessed marked"   "$rep" "(not yet assessed)"
has "project filter"      "$(bash "$BIN/ledger.sh" report --project unakin)" "1 decision(s) for unakin"
has "show one"            "$(bash "$BIN/ledger.sh" show "$id")" "attempted: ship it"
bash "$BIN/ledger.sh" record pre-push:remote refused unakin "git push dapinitial" "reconstructed from 2026-09-11 history" >/dev/null
has "manual record" "$(bash "$BIN/ledger.sh" report --project unakin)" "reconstructed from 2026-09-11 history"

echo "the guard writes the ledger:"
R="$TMP/repo"; mkdir -p "$R"; git init -q --bare "$TMP/o.git"; git init -q --bare "$TMP/m.git"
git -C "$R" init -q -b main 2>/dev/null || { git -C "$R" init -q; git -C "$R" checkout -q -b main; }
G "$R" remote add origin "$TMP/o.git"; G "$R" remote add mirror "$TMP/m.git"
echo a > "$R/a"; G "$R" add -A; G "$R" commit -q -m a; G "$R" push -q -u origin main 2>/dev/null
bash "$BIN/install-hooks.sh" "$R" >/dev/null
before="$(wc -l < "$SHIPMATE_LEDGER")"
G "$R" push -q mirror main >/dev/null 2>&1
ok "wrong remote recorded" "$(tail -1 "$SHIPMATE_LEDGER" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["policy"], r["outcome"], r["project"])')" "pre-push:remote refused repo"
echo s > "$R/.env"; G "$R" add -f .env; G "$R" commit -q -m env; G "$R" push -q origin main >/dev/null 2>&1
has "protected recorded" "$(tail -1 "$SHIPMATE_LEDGER")" '"detail":"touches .env"'
SHIPMATE_ALLOW=1 G "$R" push -q mirror main >/dev/null 2>&1
has "override recorded"  "$(tail -1 "$SHIPMATE_LEDGER")" '"outcome":"overridden"'
# A blanket override records one line PER rule it actually covered, not one generic line: this
# push waves through both the wrong remote and the protected .env, and the record now says so.
has "override names the remote rule"    "$(tail -2 "$SHIPMATE_LEDGER")" '"detail":"SHIPMATE_ALLOW=remote"'
has "override names the protected rule, and the file" "$(tail -1 "$SHIPMATE_LEDGER")" '"detail":"SHIPMATE_ALLOW=protected; .env"'
ok  "four new lines"     "$(( $(wc -l < "$SHIPMATE_LEDGER") - before ))" 4
# And the dictation report reads phrase-parser misses back out of the same record.
bash "$BIN/ledger.sh" record phrase-parser unresolved - "deploy anakin" "no project matched by name or sound" >/dev/null
has "dictation report"   "$(bash "$BIN/ledger.sh" report --dictation)" "deploy anakin"
has "dictation counts"   "$(bash "$BIN/ledger.sh" report --dictation)" "1 distinct"

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
