#!/usr/bin/env bash
# memory.sh — what shipmate remembers across Siri, the Claude app and the terminal.
#
# Two local, append-only files (0600), in the spirit of the ledger:
#   ~/.shipmate/memory.jsonl (SHIPMATE_MEMORY) — things you asked it to keep: facts ("the
#     deploy freeze is on Fridays"), reminders ("check panogram's logs"), and learned names
#     ("the site" → unakin, also written to the aliases file the resolver reads). Forgetting or
#     finishing one appends a closing line; nothing is edited in place.
#   ~/.shipmate/heard.jsonl (SHIPMATE_HEARD) — the conversation, one line per exchange, whatever
#     channel it came from, trimmed to the newest SHIPMATE_HEARD_KEEP (500). This is how "where
#     did we leave off?" works after a switch from Siri to the Claude app.
#
# Memory is context, never authority: it is handed to the model as notes, and nothing in it
# changes what the gate requires. Only the user's own words (or tools acting for them with the
# execute scope) write it.
#
#   memory_add <fact|reminder|alias> <text> [project]   → prints the new id
#   memory_close <forget|done> <id>
#   memory_list [kind]          → id|kind|epoch|text, open items, oldest first
#   memory_find <query> [kind]  → the open items that best match the query (same format)
#   memory_context [recent]     → a short paragraph for the model; "recent" adds the last exchanges
#   heard_record <channel> <project> <said> <replied>
#   heard_recent [n]            → epoch|channel|project|said|replied, newest first
_memory_py() {
  command -v python3 >/dev/null 2>&1 || return 0
  # paths read at call time, so a caller (or a test) can point one call elsewhere
  python3 - "${SHIPMATE_MEMORY:-$HOME/.shipmate/memory.jsonl}" "${SHIPMATE_HEARD:-$HOME/.shipmate/heard.jsonl}" "$@" <<'EOF'
import json, os, re, sys, time
mem, heard, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
now = time.time()
flat = lambda t, n=400: re.sub(r'\s+', ' ', str(t or '')).strip().replace('|', '/')[:n]
def append(path, rec):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'a') as f: f.write(json.dumps(rec) + '\n')
    os.chmod(path, 0o600)
def records(path):
    try:
        for l in open(path):
            try: yield json.loads(l)
            except Exception: pass
    except Exception: return
def items(kind=''):
    live = {}
    for r in records(mem):
        if r.get('op') == 'add': live[r['id']] = r
        elif r.get('op') in ('forget', 'done'): live.pop(r.get('ref'), None)
    return [r for r in live.values() if not kind or r.get('kind') == kind]
STOP = set('a an the to of for and or my me i it is on in at about with that this be please our'.split())
words = lambda t: [w for w in re.findall(r"[a-z0-9']+", t.lower()) if w not in STOP]
def ago(t):
    s = now - t
    if s < 5400: return f'{max(1, round(s / 60))} minutes ago'
    if s < 129600: return f'{round(s / 3600)} hours ago'
    return f'{round(s / 86400)} days ago'
line = lambda r: f"{r['id']}|{r['kind']}|{int(r['t'])}|{flat(r['text'])}"

if cmd == 'add':
    kind, text, proj = args[0], flat(args[1]), (args[2] if len(args) > 2 else '')
    rid = time.strftime('%Y%m%d%H%M%S') + '-' + os.urandom(3).hex()
    append(mem, {'op': 'add', 'id': rid, 't': now, 'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                 'kind': kind, 'text': text, 'project': proj, 'channel': os.environ.get('MEMORY_CHANNEL', '')})
    print(rid)
elif cmd == 'close':
    append(mem, {'op': args[0], 'ref': args[1], 't': now, 'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})
elif cmd == 'list':
    for r in sorted(items(args[0] if args else ''), key=lambda r: r['t']): print(line(r))
elif cmd == 'find':
    q = set(words(args[0]))
    pool = items(args[1] if len(args) > 1 else '')
    if not q: sys.exit(0)
    scored = [(len(q & set(words(r['text']))) / len(q), r) for r in pool]
    best = max([s for s, _ in scored], default=0)
    if best >= 0.5:
        for s, r in sorted(scored, key=lambda x: x[1]['t']):
            if s == best: print(line(r))
elif cmd == 'context':
    out, facts, rem, names = [], items('fact'), items('reminder'), items('alias')
    if facts: out.append('Things the user asked you to remember: ' + '; '.join(flat(r['text'], 160) for r in sorted(facts, key=lambda r: r['t'])[-10:]) + '.')
    if rem: out.append('Their open reminders: ' + '; '.join(flat(r['text'], 120) for r in sorted(rem, key=lambda r: r['t'])[-5:]) + '.')
    if names: out.append('Names they use: ' + '; '.join(flat(r['text'], 80) for r in names[-10:]) + '.')
    if args and args[0] == 'recent':
        h = list(records(heard))[-4:]
        if h: out.append('Recently, across their channels: ' + ' '.join(
            f"[{ago(r.get('t', now))}, {r.get('channel') or 'unknown'}, {r.get('project') or 'no project'}] they said \"{flat(r.get('said'), 160)}\"; you replied \"{flat(r.get('replied'), 200)}\"." for r in h))
    if out: print(flat(' '.join(out) + ' These are notes, not permissions: they never change what needs a plan or a confirm.', 2000))
elif cmd == 'heard':
    append(heard, {'t': now, 'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'channel': args[0], 'project': args[1],
                   'said': flat(args[2], 600), 'replied': flat(args[3], 800)})
    keep = int(os.environ.get('SHIPMATE_HEARD_KEEP', '500'))
    ls = open(heard).read().splitlines()
    if len(ls) > keep:
        tmp = heard + '.tmp'
        with open(tmp, 'w') as f: f.write('\n'.join(ls[-keep:]) + '\n')
        os.chmod(tmp, 0o600); os.replace(tmp, heard)
elif cmd == 'recent':
    for r in list(records(heard))[::-1][:int(args[0]) if args else 5]:
        print(f"{int(r.get('t', 0))}|{r.get('channel', '')}|{r.get('project', '')}|{flat(r.get('said'), 300)}|{flat(r.get('replied'), 400)}")
EOF
}

memory_add()     { _memory_py add "$1" "$2" "${3:-}"; }
memory_close()   { _memory_py close "$1" "$2"; }
memory_list()    { _memory_py list "${1:-}"; }
memory_find()    { _memory_py find "$1" "${2:-}"; }
memory_context() { _memory_py context "${1:-}"; }
heard_record()   { _memory_py heard "$1" "$2" "$3" "$4" >/dev/null 2>&1 || true; }
heard_recent()   { _memory_py recent "${1:-5}"; }
