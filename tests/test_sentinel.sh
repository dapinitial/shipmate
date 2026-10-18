#!/usr/bin/env bash
# Tests for the sentinel (skills/deploy/lib/sentinel.sh + bin/sentinel.sh): shipmate speaking
# first. What matters is restraint as much as detection: a problem is announced once, only
# after it is confirmed, its recovery is announced once, a build in progress is no verdict, and
# nothing is ever written to the decision ledger or done to a project.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/../skills/deploy/bin"
command -v python3 >/dev/null 2>&1 || { echo "• python3 missing — skipping sentinel tests"; exit 0; }
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"
export SHIPMATE_SENTINEL_DIR="$TMP/state" SHIPMATE_SENTINEL_LOG="$TMP/sentinel.jsonl" SHIPMATE_LEDGER="$TMP/ledger.jsonl"
. "$DIR/../skills/deploy/lib/sentinel.sh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3] in: $2"; fail=$((fail+1)); fi; }

echo "state machine:"
export SENTINEL_NOW=1000
ok "first ok is silent"        "$(sentinel_step a.site ok)" ""
ok "one bad is not enough"     "$(sentinel_step a.site bad down 'HTTP 503')" ""
ok "nothing open yet"          "$(sentinel_open)" ""
SENTINEL_NOW=1300
ok "second bad opens"          "$(sentinel_step a.site bad down 'HTTP 503')" open
ok "listed open, since first sighting" "$(sentinel_open)" "a.site|1000|down|HTTP 503"
SENTINEL_NOW=1600
ok "still bad is silent"       "$(sentinel_step a.site bad down 'HTTP 502')" ""
ok "start kept, detail fresh"  "$(sentinel_open)" "a.site|1000|down|HTTP 502"
ok "skip keeps it open"        "$(sentinel_step a.site skip; sentinel_open)" "a.site|1000|down|HTTP 502"
SENTINEL_NOW=1900
ok "recovery clears with duration" "$(sentinel_step a.site ok)" "clear 900"
ok "cleared means closed"      "$(sentinel_open)" ""
ok "ok after clear is silent"  "$(sentinel_step a.site ok)" ""
ok "a blip then ok never opens" "$(sentinel_step b.site bad down x; sentinel_step b.site ok; sentinel_step b.site bad down x)" ""
ok "the blip reset the count"  "$(sentinel_open)" ""
ok "confirm=1 opens at once"   "$(sentinel_step c.deploy bad 'deploy failed' 'ERROR 1234567' 1)" open
ok "skip never opens"          "$(sentinel_step d.deploy skip; sentinel_step d.deploy skip; sentinel_open | grep -c '^d\.')" 0
ok "bad keys refused"          "$(sentinel_step '../x' bad; echo $?)" 1
sentinel_step e.site bad 'down' 'pipe | and tab	and
newline' 1 >/dev/null
ok "separators cleaned"        "$(sentinel_open | grep '^e\.')" "e.site|1900|down|pipe / and tab and newline"
ok "transition log is valid JSON" "$(python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]; print("yes")' "$SHIPMATE_SENTINEL_LOG")" yes
ok "log: open + clear for a, open for c and e" "$(python3 -c 'import json,sys; print(" ".join(r["project"]+":"+r["check"]+":"+r["outcome"] for r in map(json.loads, open(sys.argv[1]))))' "$SHIPMATE_SENTINEL_LOG")" \
   "a:site:open a:site:clear c:deploy:open e:site:open"
ok "log type is observation"   "$(head -1 "$SHIPMATE_SENTINEL_LOG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["type"])')" observation
ok "ago: minutes"              "$(sentinel_ago 900)" "15 min"
ok "ago: hours"                "$(sentinel_ago 7200)" "2 h"
ok "ago: days"                 "$(sentinel_ago 259200)" "3 days"
unset SENTINEL_NOW

echo "runner:"
rm -rf "$TMP/state" "$TMP/sentinel.jsonl"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
cat > "$TMP/site.py" <<'EOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        code, body = open(sys.argv[2]).read().split(' ', 1)
        self.send_response(int(code)); self.end_headers(); self.wfile.write(body.encode())
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
site() { printf '%s %s' "$1" "${2:-hello shipmate}" > "$TMP/site.txt"; }
site 200
python3 "$TMP/site.py" "$PORT" "$TMP/site.txt" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 40); do python3 -c "import socket;socket.create_connection(('127.0.0.1',$PORT),0.2)" 2>/dev/null && break; sleep 0.1; done

# a fake fleet: one DigitalOcean project with a stub app.sh that reports $TMP/phase
ROOT="$TMP/sites"; P="$ROOT/demo"; mkdir -p "$P/.do"; git -C "$P" init -q
echo 'name: demo' > "$P/.do/app.yaml"
printf 'health_url: http://127.0.0.1:%s/\n' "$PORT" > "$P/.shipmate.yml"
mkdir -p "$ROOT/notes"; git -C "$ROOT/notes" init -q   # no deploy target: never probed
cat > "$TMP/app.sh" <<EOF
#!/usr/bin/env bash
echo "\$1 \$2" >> "$TMP/app.calls"
case "\$1" in status) echo "app:    demo"; echo "url:    https://demo.example"; echo "deploy: \$(cat "$TMP/phase")";;
  *) echo "✗ the sentinel must only read status"; exit 9;; esac
EOF
chmod +x "$TMP/app.sh"; echo "ACTIVE 6/6 2026-10-17" > "$TMP/phase"
export SHIPMATE_APP_SH="$TMP/app.sh" SHIPMATE_SENTINEL_CHECKS="site deploy"
S() { bash "$BIN/sentinel.sh" "$ROOT" 2>&1; }

ok "healthy: says nothing"     "$(S)" ""
ok "a full pass leaves a heartbeat" "$([ -f "$TMP/state/.last-run" ] && echo yes)" yes
ok "only status was asked, only for the deployable repo" "$(sort -u "$TMP/app.calls" | sed "s#$ROOT/##")" "status demo"
site 503 'oops'
ok "first 503: still silent"   "$(S)" ""
out="$(S)"
has "second 503: down"         "$out" "🔴 demo is down: http://127.0.0.1:$PORT/ answers HTTP 503, two checks in a row"
has "suggests the gated phrase" "$out" "say 'roll back demo, confirm'"
ok "third 503: silent"         "$(S)" ""
has "report lists it"          "$(bash "$BIN/sentinel.sh" --report)" "• demo: down for"
site 200
has "back up: one line"        "$(S)" "🟢 demo is back: http://127.0.0.1:$PORT/ answers again, after about"
ok "report empty again"        "$(bash "$BIN/sentinel.sh" --report)" "sentinel: nothing open"
printf 'health_url: http://127.0.0.1:%s/\nexpect_text: Combat medic\n' "$PORT" > "$P/.shipmate.yml"
S >/dev/null; has "200 without the expected text is down" "$(S)" "answers 200 but without \"Combat medic\""
site 200 'Combat medic'; S >/dev/null
echo "ERROR 3/6 2026-10-17" > "$TMP/phase"
has "a failed deploy is said at once" "$(S)" "❌ demo: the latest deploy failed. Production stays on the previous version"
echo "BUILDING 2/6 2026-10-17" > "$TMP/phase"
ok "a build in progress is no verdict" "$(S)" ""
echo "ACTIVE 6/6 2026-10-17" > "$TMP/phase"
ok "live again: one line"      "$(S)" "✅ demo deploys again: the latest deploy is live."
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
S >/dev/null; has "no answer at all" "$(S)" "http://127.0.0.1:$PORT/ doesn't answer"
ok "never writes the decision ledger" "$([ -e "$SHIPMATE_LEDGER" ] && echo written || echo untouched)" untouched
mkdir "$TMP/state/.lock"
before="$(wc -l < "$TMP/app.calls")"
ok "a running sentinel blocks a second" "$(S; echo "exit $?")" "exit 0"
ok "…and the second one probed nothing" "$(wc -l < "$TMP/app.calls")" "$before"
rmdir "$TMP/state/.lock"

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
