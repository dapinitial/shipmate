#!/usr/bin/env bash
# timing.sh — how long each live site takes to answer, kept so "slow" means slow for that site.
#
# bin/sentinel.sh measures every site check (curl on the health URL, no redirects followed):
#   ttfb  time to first byte — until the first byte of the response arrived
#   load  full load — until the whole response body arrived. This is the health URL's own
#         document, not a browser render with its images and scripts.
# Only answers that count as up (2xx/3xx) are recorded; a failure is the site check's business,
# and a fast 503 would drag the median down.
#
# Store: one JSON line per measurement in $SENTINEL_DIR/.timings.jsonl (SHIPMATE_TIMINGS), 0600,
# trimmed to the last SHIPMATE_TIMING_KEEP_DAYS (8). It follows SHIPMATE_SENTINEL_DIR, so a test
# or a demo that points the sentinel elsewhere never writes the real one.
#
#   timing_record          stdin: project|url|code|ttfb_seconds|load_seconds, one per line
#   timing_slow <since> [now]
#                          one line per flagged project and measure:
#                            project|ttfb or load|recent_ms|median7_ms|samples|worst_ms|why
#                          why = "over" (recent median above SHIPMATE_SLOW_MS, default 3000) or
#                          "double" (at least SHIPMATE_SLOW_FACTOR, default 2, times the 7-day
#                          median, with enough history and above SHIPMATE_SLOW_FLOOR_MS, default
#                          300, so 40 ms becoming 90 ms is not news).
#   "recent" is the median of the measurements since <since> (at least 3 of them, so one slow
#   check is a blip, not a finding); the 7-day median is over every measurement in the 7 days
#   up to <now>, and needs at least 12 before the "double" rule is trusted.
TIMING_FILE="${SHIPMATE_TIMINGS:-${SHIPMATE_SENTINEL_DIR:-$HOME/.shipmate/sentinel}/.timings.jsonl}"

_timing_py() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "${SHIPMATE_TIMINGS:-$TIMING_FILE}" "$@" <<'EOF'
import json, os, statistics, sys, time
path, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
env = lambda k, d: os.environ.get(k) or d
now_env = float(env('SENTINEL_NOW', env('SHIPMATE_NOW', str(time.time()))))
def rows():
    try:
        for l in open(path):
            try: yield json.loads(l)
            except Exception: pass
    except Exception: return

if cmd == 'record':
    keep = float(env('SHIPMATE_TIMING_KEEP_DAYS', '8')) * 86400
    new = []
    for l in (args[0] if args else '').splitlines():
        f = l.split('|')
        if len(f) != 5: continue
        proj, url, code = f[0], f[1], f[2]
        try: ttfb, load = float(f[3]), float(f[4])
        except ValueError: continue
        if not proj or not code[:1] in ('2', '3') or load <= 0: continue
        new.append({'t': now_env, 'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now_env)), 'project': proj,
                    'url': url[:200], 'code': int(code) if code.isdigit() else 0,
                    'ttfb_ms': round(ttfb * 1000), 'load_ms': round(load * 1000)})
    if not new: sys.exit(0)
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    first = next(rows(), None)
    if first and first.get('t', 0) < now_env - keep:      # rewrite only when something has aged out
        kept = [r for r in rows() if r.get('t', 0) >= now_env - keep] + new
        tmp = path + '.tmp'
        with open(tmp, 'w') as fh: fh.write(''.join(json.dumps(r) + '\n' for r in kept))
        os.chmod(tmp, 0o600); os.replace(tmp, path)
    else:
        with open(path, 'a') as fh: fh.write(''.join(json.dumps(r) + '\n' for r in new))
        os.chmod(path, 0o600)

elif cmd == 'slow':
    since = float(args[0]); now = float(args[1]) if len(args) > 1 and args[1] else now_env
    over_ms = float(env('SHIPMATE_SLOW_MS', '3000'))
    factor = float(env('SHIPMATE_SLOW_FACTOR', '2'))
    floor = float(env('SHIPMATE_SLOW_FLOOR_MS', '300'))
    week = now - 7 * 86400
    by = {}
    for r in rows():
        t = r.get('t', 0)
        if t < week or t > now: continue
        by.setdefault(r.get('project', '?'), []).append(r)
    for proj in sorted(by):
        rs = by[proj]
        for m in ('ttfb', 'load'):
            allv = [r[m + '_ms'] for r in rs if isinstance(r.get(m + '_ms'), (int, float))]
            recent = [r[m + '_ms'] for r in rs if r.get('t', 0) >= since and isinstance(r.get(m + '_ms'), (int, float))]
            if len(recent) < 3: continue
            rec, base = statistics.median(recent), statistics.median(allv)
            why = ''
            if rec > over_ms: why = 'over'
            elif len(allv) >= 12 and rec >= floor and rec >= factor * base: why = 'double'
            if why: print(f'{proj}|{m}|{round(rec)}|{round(base)}|{len(recent)}|{max(recent)}|{why}')
EOF
}

timing_record() { _timing_py record "$(cat)"; }   # the script itself is on python's stdin
timing_slow()   { _timing_py slow "$1" "${2:-}"; }
