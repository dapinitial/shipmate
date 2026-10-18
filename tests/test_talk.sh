#!/usr/bin/env bash
# Tests for talking on the glasses: POST /glance/ask (mcp/shipmate-mcp.js) and the bridge's
# read-only channel. A spoken question must reach the bridge as words, transcribed on this
# machine with the audio deleted afterwards, and a read-only token must get exactly what the
# read scope means everywhere else: ask, brief, recall, plan — never ship, never write memory.
# whisper is a stub here; the bridge is the real one, on verbs that need no model.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "• node/python3 missing — skipping talk tests"; exit 0; }
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"
PORT="$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
mkdir -p "$TMP/home/.shipmate/mcp" "$TMP/sites/unakin/.git" "$TMP/bin"
printf 'stub words\n' > "$TMP/said"
cat > "$TMP/bin/whisper" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/whisper.log"
while [ \$# -gt 0 ]; do [ "\$1" = -f ] && { cp "\$2" "$TMP/last.wav"; echo "\$2" > "$TMP/last.path"; }; shift; done
cat "$TMP/said"
EOF
chmod +x "$TMP/bin/whisper"; : > "$TMP/model.bin"
ENVV=(HOME="$TMP/home" SHIPMATE_SITES_ROOT="$TMP/sites" SHIPMATE_LEDGER="$TMP/ledger.jsonl" SHIPMATE_MEMORY="$TMP/memory.jsonl"
      SHIPMATE_HEARD="$TMP/heard.jsonl" SHIPMATE_WHISPER="$TMP/bin/whisper" SHIPMATE_WHISPER_MODEL="$TMP/model.bin")
env "${ENVV[@]}" node "$DIR/../mcp/shipmate-mcp.js" --http "$PORT" 2>"$TMP/server.log" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/.well-known/oauth-authorization-server" && break; sleep 0.1; done
B="http://127.0.0.1:$PORT"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3] in: $2"; fail=$((fail+1)); fi; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1],""))' "$1"; }

code="$(env "${ENVV[@]}" node "$DIR/../mcp/shipmate-mcp.js" --pair-device 'Test G2' 2>&1 | grep -oE '[A-Z0-9]{4}-[A-Z0-9]{4}' | head -1)"
TOK="$(curl -s -X POST -d "code=$code" "$B/device/pair" | j access_token)"
ok "paired a read-only device" "$([ ${#TOK} -gt 20 ] && echo yes)" yes
askt() { curl -s -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d "{\"text\":\"$1\"}" "$B/glance/ask"; }
pcm() { python3 -c 'import sys; sys.stdout.buffer.write(b"\x01\x00" * int(sys.argv[1]))' "$1" > "$TMP/a.pcm"; }
aska() { curl -s -w '\n%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/octet-stream' --data-binary @"$TMP/a.pcm" "$B/glance/ask?ms=$1${2:+&rate=$2}"; }
wavrate() { python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(44); print(d[:4].decode(), d[8:12].decode(), struct.unpack("<HHI", d[20:28]), struct.unpack("<H", d[34:36])[0])' "$TMP/last.wav"; }

echo "access:"
ok "no token → 401"              "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/glance/ask")" 401
ok "forged token → 401"          "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer forgedforgedforgedforged12' "$B/glance/ask")" 401
ok "CORS preflight for the phone WebView" "$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS -H 'Origin: https://x' "$B/glance/ask")" 204

echo "typed questions, read-only:"
out="$(askt 'what do you remember')"
ok "heard as typed"              "$(printf '%s' "$out" | j heard)" "what do you remember"
has "answered by the bridge"     "$(printf '%s' "$out" | j answer)" "Nothing yet."
out="$(askt 'roll back unakin' | j answer)"
ok "plans are not refused"       "$(printf '%s' "$out" | grep -c -E 'read-only|can only plan')" 0
has "ship it is refused"         "$(askt 'deploy unakin, ship it' | j answer)" "the glasses can only plan. Tap Ship it on your phone"
has "…and recorded, with the channel" "$(tail -1 "$TMP/ledger.jsonl")" '"policy":"scope","outcome":"refused","project":"unakin","attempted":"deploy unakin, ship it","channel":"glasses","detail":"read-only channel: ship"'
has "memory writes are refused"  "$(askt 'remember that the freeze is on fridays' | j answer)" "The glasses can't change what I remember."
ok "…and nothing was written"    "$([ -e "$TMP/memory.jsonl" ] && echo written || echo untouched)" untouched
has "background work is refused" "$(askt 'work on dark mode for unakin' | j answer)" "The glasses are read-only"
has "routing to another host is not a way around it" "$(askt 'at home deploy unakin ship it' | j answer)" "the glasses can only plan"
ok "empty question → 400"        "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"text":"  "}' "$B/glance/ask")" 400

echo "spoken questions:"
printf ' Good morning.\n' > "$TMP/said"
pcm 16000; out="$(aska 1000)"
ok "1 s of audio → 200"           "$(printf '%s' "$out" | tail -1)" 200
ok "heard what whisper said"      "$(printf '%s' "$out" | head -1 | j heard)" "Good morning."
has "the briefing answered"       "$(printf '%s' "$out" | head -1 | j answer)" "Since "
ok "a valid 16 kHz mono 16-bit WAV" "$(wavrate)" "RIFF WAVE (1, 1, 16000) 16"
ok "the audio is deleted after"   "$([ -e "$(cat "$TMP/last.path")" ] && echo kept || echo gone)" gone
has "the model and English were asked for" "$(tail -1 "$TMP/whisper.log")" "-m $TMP/model.bin -f"
pcm 48000; aska 1000 >/dev/null; ok "rate worked out from bytes over time: 48 kHz" "$(wavrate)" "RIFF WAVE (1, 1, 48000) 16"
pcm 24000; aska 1500 >/dev/null; ok "…and 16 kHz from a 1.5 s clip" "$(wavrate)" "RIFF WAVE (1, 1, 16000) 16"
pcm 16000; aska 1000 8000 >/dev/null; ok "a stated rate wins" "$(wavrate)" "RIFF WAVE (1, 1, 8000) 16"
pcm 800; ok "too short → 400"     "$(aska 100 | tail -1)" 400
printf '[BLANK_AUDIO]\n' > "$TMP/said"; pcm 16000
out="$(aska 1000)"; ok "silence → 400" "$(printf '%s' "$out" | tail -1)" 400
has "…said plainly"               "$(printf '%s' "$out" | head -1 | j error)" "didn't catch any words"
python3 -c 'import sys; sys.stdout.buffer.write(b"\0" * (3 * 1024 * 1024 + 10))' > "$TMP/a.pcm"
ok "over 30 s → 413"              "$(aska 40000 | tail -1)" 413
printf 'ship it\n' > "$TMP/said"; pcm 16000
has "a spoken ship it is refused too" "$(aska 1000 | head -1 | j answer)" "the glasses can only plan"

echo "no speech engine:"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
env "${ENVV[@]}" SHIPMATE_WHISPER_MODEL="$TMP/missing.bin" node "$DIR/../mcp/shipmate-mcp.js" --http "$PORT" 2>>"$TMP/server.log" & SRV=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "$B/.well-known/oauth-authorization-server" && break; sleep 0.1; done
out="$(aska 1000)"
ok "→ 503"                        "$(printf '%s' "$out" | tail -1)" 503
has "…with the fix"               "$(printf '%s' "$out" | head -1 | j error)" "brew install whisper-cpp"
has "typed questions still work"  "$(askt 'what do you remember' | j answer)" "Nothing yet."

echo "limits:"
for i in $(seq 1 30); do curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{}' "$B/glance/ask"; done
ok "30 questions in ten minutes, then 429" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"text":"status"}' "$B/glance/ask")" 429
ok "no query string or audio in the server log" "$(grep -c 'ms=' "$TMP/server.log")" 0

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
