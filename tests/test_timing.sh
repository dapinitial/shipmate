#!/usr/bin/env bash
# Tests for slow-page watching (skills/deploy/lib/timing.sh, measured by bin/sentinel.sh, said by
# bin/briefing.sh). "Slow" has to mean slow for that site: over 3 s, or twice its own 7-day
# median, on the typical check of the window rather than one bad one, and never a 40 ms page
# becoming a 90 ms one. The measurements must be real ones, from the same request as the
# site check, and only of answers that count as up.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/../skills/deploy/bin"
command -v python3 >/dev/null 2>&1 || { echo "• python3 missing — skipping timing tests"; exit 0; }
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"
export TZ=America/Los_Angeles HOME="$TMP/home"
export SHIPMATE_SENTINEL_DIR="$TMP/sentinel" SHIPMATE_SENTINEL_LOG="$TMP/sentinel.jsonl" SHIPMATE_LEDGER="$TMP/ledger.jsonl" \
  SHIPMATE_VOICE_STATE="$TMP/voice" SHIPMATE_APPROVALS_DIR="$TMP/approvals" SHIPMATE_PLAN_GRANT="$TMP/grant.json" \
  SHIPMATE_BRIEFING_MARK="$TMP/briefing.last" SHIPMATE_MEMORY="$TMP/memory.jsonl"
mkdir -p "$TMP/home" "$TMP/sentinel"
. "$DIR/../skills/deploy/lib/timing.sh"
F="$TMP/sentinel/.timings.jsonl"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3] in: $2"; fail=$((fail+1)); fi; }
hasnt() { if printf '%s' "$2" | grep -q -F -- "$3"; then echo "  ✗ $1: should not say [$3] in: $2"; fail=$((fail+1)); else pass=$((pass+1)); fi; }

# "now" is Saturday 2026-10-17 07:30 PDT; the window is the last 24 hours
NOW=1792247400; DAY=86400
rec() { # <epoch> <project> <code> <ttfb s> <load s>
  printf '%s|https://%s.example/|%s|%s|%s\n' "$2" "$2" "$3" "$4" "$5" | SENTINEL_NOW="$1" timing_record; }
week() { # <project> <ttfb s> <load s> — 6 days of ordinary checks before the window, every 2 hours
  local t=$((NOW - 7 * DAY + 3600)); while [ $t -lt $((NOW - DAY)) ]; do rec $t "$1" 200 "$2" "$3"; t=$((t + 7200)); done; }
recent() { # <project> <n> <ttfb s> <load s> — n checks inside the window
  local i=1; while [ $i -le "$2" ]; do rec $((NOW - i * 1800)) "$1" 200 "$3" "$4"; i=$((i + 1)); done; }
SLOW() { timing_slow $((NOW - DAY)) "$NOW"; }

echo "recording:"
rec $NOW demo 200 0.123 0.4567
ok "seconds become milliseconds" "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(r["project"], r["code"], r["ttfb_ms"], r["load_ms"])' "$F")" "demo 200 123 457"
ok "the file is 0600"           "$(stat -f '%Lp' "$F" 2>/dev/null || stat -c '%a' "$F")" 600
ok "it lives with the sentinel's state, not ~/.shipmate" "$([ -e "$TMP/home/.shipmate" ] && echo leaked || echo contained)" contained
rec $NOW demo 503 0.01 0.02; rec $NOW demo 000 0 15; rec $NOW demo 301 0.05 0.05
printf 'garbage\ndemo|u|200|x|y\n' | timing_record
ok "only up answers are kept (2xx/3xx), garbage skipped" "$(wc -l < "$F" | tr -d ' ')" 2
rm -f "$F"; rec $((NOW - 9 * DAY)) old 200 0.1 0.2; rec $NOW demo 200 0.1 0.2
ok "older than 8 days is trimmed on the next write" "$(grep -c '"old"' "$F")" 0
rm -f "$F"

echo "judging:"
week steady 0.2 0.6;   recent steady 20 0.2 0.6
week doubled 0.2 0.6;  recent doubled 20 0.25 1.5
week over 2.0 2.8;     recent over 20 2.2 3.4
week blip 0.2 0.6;     recent blip 19 0.2 0.6; rec $((NOW - 60)) blip 200 4.0 9.0
week tiny 0.02 0.04;   recent tiny 20 0.05 0.09
recent newcomer 20 0.2 1.5                     # no week behind it yet
recent sparse 2 5.0 6.0                        # two checks are not a pattern
out="$(SLOW)"
hasnt "a steady site is never flagged"        "$out" "steady|"
has   "twice its own median: flagged"         "$out" "doubled|load|1500|600|20|1500|double"
hasnt "…but its first byte, only 25% up, isn't" "$out" "doubled|ttfb"
has   "over 3 s: flagged"                     "$out" "over|load|3400|"
has   "…named as over"                        "$(printf '%s\n' "$out" | grep '^over|load')" "|over"
hasnt "…and first byte 2.2 s is neither"      "$out" "over|ttfb"
hasnt "one slow check is a blip, not a finding" "$out" "blip|"
hasnt "40 ms to 90 ms is not news (floor)"    "$out" "tiny|"
hasnt "no week of history: 'double' isn't trusted" "$out" "newcomer|"
hasnt "fewer than 3 checks: no verdict"       "$out" "sparse|"
ok    "with the floor at 0, tiny is flagged"  "$(SHIPMATE_SLOW_FLOOR_MS=0 SLOW | grep -c '^tiny|')" 2
ok    "the 3 s line can be moved"             "$(SHIPMATE_SLOW_MS=4000 SLOW | grep -c '^over|')" 0

echo "the briefing:"
touch "$TMP/sentinel/.last-run"; printf 'ok|0|%s||\n' "$NOW" > "$TMP/sentinel/doubled.site"
B() { SHIPMATE_NOW=$NOW bash "$BIN/briefing.sh" "$@" 2>&1; }
out="$(B)"
has   "the doubled site, against its week"    "$out" "doubled was slow: full load typically 1.5 s, against 0.6 s over the last week."
has   "the slow one"                          "$out" "over was slow: full load typically 3.4 s, against 2.8 s over the last week."
hasnt "nothing about the steady one"          "$out" "steady was slow"
has   "heads-up line for the glasses"         "$(B --lines)" "doubled slow: load 1.5s (wk 0.6s)"
ok    "no timings, nothing said"              "$(SHIPMATE_TIMINGS="$TMP/none.jsonl" B | grep -c 'was slow')" 0

echo "measured by the sentinel:"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
cat > "$TMP/site.py" <<'EOF'
import sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        code, delay, body = open(sys.argv[2]).read().split(' ', 2)
        time.sleep(float(delay)); self.send_response(int(code)); self.end_headers(); self.wfile.flush()
        time.sleep(float(delay)); self.wfile.write(body.encode())
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
printf '200 0.3 Combat medic' > "$TMP/site.txt"
python3 "$TMP/site.py" "$PORT" "$TMP/site.txt" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 40); do python3 -c "import socket;socket.create_connection(('127.0.0.1',$PORT),0.2)" 2>/dev/null && break; sleep 0.1; done
ROOT="$TMP/sites"; P="$ROOT/demo"; mkdir -p "$P/.do"; git -C "$P" init -q; echo 'name: demo' > "$P/.do/app.yaml"
printf 'health_url: http://127.0.0.1:%s/\nexpect_text: Combat medic\n' "$PORT" > "$P/.shipmate.yml"
printf '#!/usr/bin/env bash\necho "deploy: ACTIVE 6/6"\n' > "$TMP/app.sh"; chmod +x "$TMP/app.sh"
export SHIPMATE_APP_SH="$TMP/app.sh" SHIPMATE_SENTINEL_CHECKS="site"
rm -f "$F"; out="$(bash "$BIN/sentinel.sh" "$ROOT" 2>&1)"
ok "a healthy slow-ish site: the sentinel stays silent" "$out" ""
ok "one measurement for the one check" "$(wc -l < "$F" | tr -d ' ')" 1
ok "first byte after the server's first pause, full load after both" "$(python3 -c '
import json,sys; r=json.loads(open(sys.argv[1]).readline())
print("yes" if 280 <= r["ttfb_ms"] < r["load_ms"] and r["load_ms"] >= 580 else r)' "$F")" yes
ok "expect_text read from the same request (no second fetch needed)" "$(ls "$TMP/sentinel" | grep -c '^\.body')" 0
printf '503 0 oops' > "$TMP/site.txt"; bash "$BIN/sentinel.sh" "$ROOT" >/dev/null 2>&1
ok "a 503 is not timed" "$(wc -l < "$F" | tr -d ' ')" 1
ok "and the real home was never written" "$([ -e "$HOME/.shipmate" ] && echo written || echo untouched)" untouched

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
