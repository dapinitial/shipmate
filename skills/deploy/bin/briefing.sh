#!/usr/bin/env bash
# briefing.sh — what happened since your last briefing, and what needs you now. Facts only:
# it reads shipmate's own records, asks no model, and changes nothing but its own marker.
#
# Usage: briefing.sh [--lines] [--mark] [--hours N]
#   (default)  a few spoken sentences: what needs you, then what happened, newest concerns first
#   --lines    the same, as short lines for a heads-up display (the glasses' BRIEF view)
#   --mark     afterwards, start the next briefing's window now (the daily push does this)
#   --hours N  window of the last N hours instead of "since the last marked briefing"
#
# Window: since the last --mark (~/.shipmate/briefing.last), else the last 24 hours; never more
# than 7 days. Sources, each optional: the sentinel (open problems + ~/.shipmate/sentinel.jsonl),
# the decision ledger, your open reminders (~/.shipmate/memory.jsonl), background jobs, pending spend approvals, the armed plan, the dead-zone
# queue. If the sentinel hasn't run lately, the briefing says so instead of calling things quiet.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,16p' "$0"; exit 0;; esac
command -v python3 >/dev/null 2>&1 || { echo "The briefing needs python3, which isn't installed."; exit 1; }
LINES=""; MARK=""; HOURS=""
while [ $# -gt 0 ]; do
  case "$1" in --lines) LINES=1 ;; --mark) MARK=1 ;; --hours) HOURS="${2:-}"; shift ;; esac; shift
done
S="$HOME/.shipmate"
MARKER="${SHIPMATE_BRIEFING_MARK:-$S/briefing.last}"

python3 - "$MARKER" "$HOURS" "$LINES" <<'EOF'
import json, os, sys, time, datetime as dt
marker, hours, as_lines = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
H = os.path.expanduser('~/.shipmate')
env = lambda k, d: os.environ.get(k) or d
LEDGER = env('SHIPMATE_LEDGER', f'{H}/ledger.jsonl')
SDIR = env('SHIPMATE_SENTINEL_DIR', f'{H}/sentinel')
SLOG = env('SHIPMATE_SENTINEL_LOG', f'{H}/sentinel.jsonl')
VOICE = env('SHIPMATE_VOICE_STATE', f'{H}/voice')
APPROVALS = env('SHIPMATE_APPROVALS_DIR', f'{H}/approvals')
GRANT = env('SHIPMATE_PLAN_GRANT', f'{H}/mcp/plan-grant.json')
MEMORY = env('SHIPMATE_MEMORY', f'{H}/memory.jsonl')
PLAN_TTL = int(env('SHIPMATE_PLAN_TTL', '600'))
now = float(env('SHIPMATE_NOW', str(time.time())))

if hours: since = now - float(hours) * 3600
else:
    try: since = float(open(marker).read().strip())
    except Exception: since = now - 86400
since = max(since, now - 7 * 86400)

def epoch(ts):
    try: return dt.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc).timestamp()
    except Exception: return 0
def jsonl(p):
    try:
        for l in open(p):
            try: yield json.loads(l)
            except Exception: pass
    except Exception: return
def read(p):
    try: return open(p).read().strip()
    except Exception: return ''
def span(s):
    s = max(0, int(s))
    if s < 90: return '1 minute' if as_lines is False else '1m'
    if s < 5400: m = round(s / 60); return f'{m} minutes' if not as_lines else f'{m}m'
    if s < 129600: h = round(s / 3600); return (f'{h} hour' + ('s' if h != 1 else '')) if not as_lines else f'{h}h'
    d = round(s / 86400); return (f'{d} day' + ('s' if d != 1 else '')) if not as_lines else f'{d}d'
def times(n): return {1: 'once', 2: 'twice'}.get(n, f'{n} times')
def plural(n, w): return f'{n} {w}' + ('' if n == 1 else 's')
def andjoin(xs): return xs[0] if len(xs) == 1 else ', '.join(xs[:-1]) + ' and ' + xs[-1]
def when(t):
    a, b = dt.datetime.fromtimestamp(t), dt.datetime.fromtimestamp(now)
    clock = a.strftime('%I:%M %p').lstrip('0').replace(':00 ', ' ')
    days = (b.date() - a.date()).days
    part = 'this morning' if a.hour < 12 else 'this afternoon' if a.hour < 18 else 'tonight'
    if days == 0: return f'{clock} {part}' if not as_lines else clock
    if days == 1: return f'yesterday at {clock}' if not as_lines else f'yday {clock}'
    if days < 6: return a.strftime('%A at ') + clock if not as_lines else a.strftime('%a ') + clock
    return a.strftime('%B ') + str(a.day) if not as_lines else a.strftime('%b ') + str(a.day)

needs, happened, lines_now, lines_then = [], [], [], []

# -- what needs you now ---------------------------------------------------------------------
opened = []
try: names = sorted(os.listdir(SDIR))
except Exception: names = []
for n in names:
    if n.startswith('.'): continue
    f = read(os.path.join(SDIR, n)).split('|')
    if f[0] == 'open':
        proj, check = n.rsplit('.', 1)
        what = f[3] if len(f) > 3 and f[3] else check
        opened.append((proj, what, now - float(f[2] or now)))
for proj, what, age in opened:
    needs.append(f'{proj} is {what}, for {span(age)}.' if what == 'down' else f'{proj}: {what}, for {span(age)}.')
    lines_now.append(f'!! {proj} {what} {span(age)}')
approvals = []
try:
    for n in sorted(os.listdir(APPROVALS)):
        l = read(os.path.join(APPROVALS, n)).split('\n')
        if l and l[0].startswith('pending'): approvals.append((l[1] if len(l) > 1 else '').strip())
except Exception: pass
if approvals:
    needs.append(f'{plural(len(approvals), "spend approval")} waiting for your tap' + (f': {approvals[0]}.' if len(approvals) == 1 and approvals[0] else '.'))
    lines_now.append(f'{plural(len(approvals), "approval")} waiting')
try:
    g = json.load(open(GRANT)); left = g['ts'] / 1000 + PLAN_TTL - now
    if left > 0:
        needs.append(f"A plan for {g['project']} is armed, {max(1, round(left / 60))} minutes left to say ship it.")
        lines_now.append(f"plan armed: {g['project']}")
except Exception: pass
try: queued = len([q for q in os.listdir(os.path.join(VOICE, 'queue')) if not q.startswith('.')])
except Exception: queued = 0
if queued:
    needs.append(f'{plural(queued, "request")} queued from a dead zone, waiting to replay.')
    lines_now.append(f'{queued} queued')

live = {}
for r in jsonl(MEMORY):
    if r.get('op') == 'add' and r.get('kind') == 'reminder': live[r.get('id')] = r
    elif r.get('op') in ('forget', 'done'): live.pop(r.get('ref'), None)
rem = sorted(live.values(), key=lambda r: r.get('t', 0))
if rem:
    shown = [str(r.get('text', '')) for r in rem[:3]]
    needs.append('You asked me to remind you to ' + andjoin(shown) + (f', and {len(rem) - 3} more' if len(rem) > 3 else '') + '.')
    lines_now += [f'remind: {t}'[:44] for t in shown] + ([f'+{len(rem) - 3} more reminders'] if len(rem) > 3 else [])

# -- what happened in the window ------------------------------------------------------------
outages = {}
for r in jsonl(SLOG):
    if r.get('type') != 'observation' or epoch(r.get('ts', '')) < since: continue
    k = (r.get('project', '?'), r.get('check', '?'))
    if r.get('outcome') == 'clear': outages.setdefault(k, []).append(r.get('lasted'))
for (proj, check), lasts in sorted(outages.items()):
    word = {'site': 'was down', 'deploy': 'had a failed deploy', 'cert': 'had a certificate problem'}.get(check, f'had a {check} problem')
    known = [x for x in lasts if isinstance(x, (int, float))]
    dur = f' for {span(max(known))}' if known and check == 'site' else ''
    happened.append(f'{proj} {word}{dur}' + (f' ({times(len(lasts))})' if len(lasts) > 1 else '') + ', and recovered.')
    lines_then.append(f'{proj} {"down" if check == "site" else check}{" " + span(max(known)) if known and check == "site" else ""}, ok now')

# A reconstructed entry's timestamp is when it was written down, not when it happened.
dec = [r for r in jsonl(LEDGER) if r.get('type') == 'decision' and epoch(r.get('ts', '')) >= since
       and not str(r.get('detail', '')).lower().startswith('reconstructed')]
clip = lambda t, n=90: t if len(t) <= n else t[:n - 1].rstrip() + '…'
ships = {}
for r in dec:
    if r.get('policy') == 'ship' and r.get('outcome') == 'executed': ships[r.get('project', '?')] = ships.get(r.get('project', '?'), 0) + 1
if ships:
    happened.append('Shipped ' + andjoin([f'{p} {times(n)}' if n > 1 else p for p, n in sorted(ships.items())]) + '.')
    lines_then.append('shipped ' + ', '.join(f'{p}' + (f' x{n}' if n > 1 else '') for p, n in sorted(ships.items())))
for r in dec:
    p, o, proj, d = r.get('policy'), r.get('outcome'), r.get('project', '?'), clip(str(r.get('detail', '')))
    if p == 'verify-live' and o == 'failed':
        happened.append(f'{proj}: {r.get("attempted", "a deploy")} did not go live ({d}).'); lines_then.append(f'{proj} deploy NOT live')
    elif p == 'verify-live' and o == 'warned':
        happened.append(f'{proj} went live with a warning: {d}.'); lines_then.append(f'{proj} live, check it')
    elif p in ('rollback', 'roll-forward') and o in ('executed', 'failed'):
        verb = 'rolled back' if p == 'rollback' else 'rolled forward'
        happened.append(f'{proj} was {verb}.' if o == 'executed' else f'{proj}: the {p} failed.')
        lines_then.append(f'{proj} {verb}' if o == 'executed' else f'{proj} {p} FAILED')
stops = [r for r in dec if r.get('outcome') in ('refused', 'denied', 'downgraded', 'timeout')]
if stops:
    by = {}
    for r in stops: by[r.get('project', '?')] = by.get(r.get('project', '?'), 0) + 1
    happened.append(f'The gate held back {plural(len(stops), "request")}: ' + andjoin([f'{n} on {p}' for p, n in sorted(by.items())]) + '.')
    lines_then.append(f'gate held {len(stops)}')
over = [r for r in dec if r.get('policy', '').startswith('pre-push:override')]
if over:
    by = {}
    for r in over: by[r.get('project', '?')] = by.get(r.get('project', '?'), 0) + 1
    happened.append(f'The push guard was overridden {times(len(over))}: ' + andjoin([f'{n} on {p}' for p, n in sorted(by.items())]) + '.')
    lines_then.append(f'guard overridden {len(over)}')

jobs = []
try: ids = sorted(os.listdir(os.path.join(VOICE, 'jobs')), key=lambda x: int(x) if x.isdigit() else 0)
except Exception: ids = []
for j in ids:
    d = os.path.join(VOICE, 'jobs', j)
    try: fin = float(read(os.path.join(d, 'finished')) or 0)
    except ValueError: fin = 0
    if fin >= since:
        jobs.append((j, os.path.basename(read(os.path.join(d, 'project')) or '?'), read(os.path.join(d, 'status')) or 'finished'))
for j, proj, st in jobs:
    happened.append(f'Job {j} on {proj} finished: {st}.'); lines_then.append(f'job {j} {proj} {st}')

# -- is the picture current? ------------------------------------------------------------------
# the sentinel stamps .last-run after every full pass (a check's file only changes with its verdict)
try: fresh = os.path.getmtime(os.path.join(SDIR, '.last-run'))
except OSError: fresh = 0
projects = sorted({n.rsplit('.', 1)[0] for n in names if not n.startswith('.') and '.' in n})
stale = not fresh or now - fresh > 1800

head = f'Since {when(since)}:'
out = []
if needs: out.append('Needs you: ' + ' '.join(needs))
out += happened
if not needs and not happened: out.append('Quiet: nothing shipped, nothing broke.')
if stale: out.append("The sentinel hasn't checked the fleet " + (f'in {span(now - fresh)}' if fresh else 'yet') + ', so the live picture may be out of date.')
elif not opened and projects: out.append(f'All {len(projects)} projects are answering.')

if as_lines:
    L = [f'since {when(since)}'] + lines_now + lines_then
    if not lines_now and not lines_then: L.append('quiet: nothing shipped or broke')
    if stale: L.append('sentinel stale: ' + (span(now - fresh) if fresh else 'never ran'))
    elif not opened and projects: L.append(f'all {len(projects)} answering')
    print('\n'.join(L))
else:
    print(head + ' ' + ' '.join(out))
EOF
rc=$?
[ "$rc" -eq 0 ] && [ -n "$MARK" ] && { mkdir -p "$(dirname "$MARKER")"; printf '%s\n' "${SHIPMATE_NOW:-$(date +%s)}" > "$MARKER"; }
exit "$rc"
