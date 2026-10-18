#!/usr/bin/env bash
# ledger.sh — read and annotate shipmate's decision ledger (~/.shipmate/ledger.jsonl).
#
# Usage: ledger.sh report [--since YYYY-MM-DD] [--project NAME]
#            counts per policy and outcome, then every non-routine decision with its id
#        ledger.sh report --dictation [--since YYYY-MM-DD]
#            what Siri said when no project could be placed, most frequent first —
#            the evidence behind every alias worth adding to ~/.shipmate/aliases
#        ledger.sh show <id>        one decision with its notes
#        ledger.sh annotate <id> "<assessment>"
#            add a human note to a decision: the plausible consequence, judged honestly
#        ledger.sh record <policy> <outcome> <project> "<attempted>" "<detail>"
#            add a decision by hand (e.g. reconstructed from history; say so in the detail)
#
# The ledger is append-only: annotate adds a note line; nothing is edited or deleted.
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '2,14p' "$0"; exit 0;; esac
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/ledger.sh"
command -v python3 >/dev/null 2>&1 || { echo "✗ ledger reports need python3"; exit 1; }

case "$1" in
  record)
    [ $# -ge 5 ] || { echo "usage: ledger.sh record <policy> <outcome> <project> <attempted> [detail]"; exit 1; }
    id="$(ledger_record "$2" "$3" "$4" "$5" "${6:-}")"; echo "recorded $id" ;;
  annotate)
    [ $# -ge 3 ] || { echo "usage: ledger.sh annotate <id> \"<assessment>\""; exit 1; }
    grep -q "\"id\":\"$2\"" "$LEDGER_FILE" 2>/dev/null || { echo "✗ no decision $2"; exit 1; }
    printf '{"type":"note","ref":"%s","ts":"%s","text":%s}\n' "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(ledger_json_str "$3")" >> "$LEDGER_FILE"
    echo "noted on $2" ;;
  show|report)
    [ -f "$LEDGER_FILE" ] || { echo "No decisions recorded yet ($LEDGER_FILE)."; exit 0; }
    python3 - "$LEDGER_FILE" "$@" <<'EOF'
import json, sys
path, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
recs, notes = [], {}
for line in open(path):
    try: r = json.loads(line)
    except ValueError: continue
    if r.get("type") == "note": notes.setdefault(r["ref"], []).append(r)
    elif r.get("type") == "decision": recs.append(r)
def fmt(r):
    s = f'{r["ts"][:16].replace("T"," ")}  {r["id"]}  {r["policy"]:<16} {r["outcome"]:<10} {r["project"]:<16} [{r["channel"]}]\n'
    s += f'    attempted: {r["attempted"]}\n'
    if r.get("detail"): s += f'    detail:    {r["detail"]}\n'
    for n in notes.get(r["id"], []): s += f'    note:      {n["text"]}\n'
    if r["outcome"] not in ROUTINE and not notes.get(r["id"]): s += '    note:      (not yet assessed)\n'
    return s
ROUTINE = {"executed", "live", "approved"}
if cmd == "show":
    hit = [r for r in recs if r["id"] == args[0]]
    print(fmt(hit[0]) if hit else f"no decision {args[0]}"); sys.exit(0)
since = project = None
for i, a in enumerate(args):
    if a == "--since": since = args[i + 1]
    if a == "--project": project = args[i + 1]
if "--dictation" in args:
    # What Siri actually handed the parser when it could not place a project. These are the
    # only honest source for a dictation alias: a word you were misheard saying, counted.
    miss = [r for r in recs if r["policy"] == "phrase-parser"
            and r["outcome"] in ("unresolved", "ambiguous")
            and (not since or r["ts"] >= since)]
    if not miss:
        print("No dictation misses recorded. Nothing to add to the dictionary."); sys.exit(0)
    heard = {}
    for r in miss:
        key = (r["attempted"].strip().lower(), r["outcome"], r.get("detail", ""))
        heard[key] = heard.get(key, 0) + 1
    print(f"{len(miss)} phrase(s) that named no project{' since ' + since if since else ''}, "
          f"{len(heard)} distinct:\n")
    print(f'  {"heard":<44}{"outcome":<12}times')
    for (ph, out, det), n in sorted(heard.items(), key=lambda kv: (-kv[1], kv[0][0])):
        print(f'  {ph[:42]:<44}{out:<12}{n}')
        if out == "ambiguous" and det: print(f'      {det}')
    print("\nAdd the ones you recognise to ~/.shipmate/aliases as  what-you-heard|project-dir")
    print("(a word that merely SOUNDS like a project no longer needs one — these are the rest).")
    sys.exit(0)
sel = [r for r in recs if (not since or r["ts"] >= since) and (not project or r["project"] == project)]
print(f"{len(sel)} decision(s){' since ' + since if since else ''}{' for ' + project if project else ''}\n")
counts = {}
for r in sel: counts[(r["policy"], r["outcome"])] = counts.get((r["policy"], r["outcome"]), 0) + 1
print(f'  {"policy":<18}{"outcome":<12}count')
for (p, o), n in sorted(counts.items()): print(f'  {p:<18}{o:<12}{n}')
flagged = [r for r in sel if r["outcome"] not in ROUTINE]
print(f"\n{len(flagged)} decision(s) where a gate stopped, changed or flagged something:\n")
for r in flagged: print(fmt(r))
EOF
    ;;
  *) echo "✗ unknown command: $1 (report | show | annotate | record)"; exit 1 ;;
esac
