#!/usr/bin/env bash
# Tests for provider neutrality: lib/provider.sh (which host), bin/app.sh (one set of verbs),
# bin/vercel-app.sh against a local stand-in for the Vercel REST API and a stub `vercel` CLI,
# and do-app.sh's phase mapping against a stub doctl. Nothing here touches a real provider.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/../skills/deploy/bin"
command -v python3 >/dev/null 2>&1 || { echo "• python3 missing — skipping provider tests"; exit 0; }
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"
. "$DIR/../skills/deploy/lib/provider.sh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "  ✗ $1: expected [$3] got [$2]"; fail=$((fail+1)); fi; }
has() { if printf '%s' "$2" | grep -q -F -- "$3"; then pass=$((pass+1)); else echo "  ✗ $1: missing [$3] in: $2"; fail=$((fail+1)); fi; }

# --- a fake Vercel: project prj_1, production currently = dpl_b (sha bbbbbbb) -------------------
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
cat > "$TMP/fake.py" <<'EOF'
import json, sys, os
from http.server import BaseHTTPRequestHandler, HTTPServer
state = json.load(open(sys.argv[2]))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(sys.argv[3], 'a') as f: f.write(self.path + ' ' + self.headers.get('Authorization', '') + '\n')
        if self.headers.get('Authorization') != 'Bearer test-token-123':
            self.send_response(403); self.end_headers(); return
        st = json.load(open(sys.argv[2]))
        if self.path.startswith('/v9/projects/prj_1'): body = st['project']
        elif self.path.startswith('/v6/deployments'): body = {'deployments': st['deployments']}
        else: self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
state() { # <current uid> <git repo or ""> — rewrite the fake's world
  python3 - "$TMP/state.json" "$1" "$2" <<'EOF'
import json, sys
cur, repo = sys.argv[2], sys.argv[3]
d = lambda uid, sha, st: {'uid': uid, 'state': st, 'target': 'production', 'meta': {'githubCommitSha': sha * 7}}
json.dump({'project': {'name': 'demo', 'targets': {'production': {'id': cur, 'readyState': 'READY',
           'meta': {'githubCommitSha': {'dpl_c': 'c', 'dpl_b': 'b', 'dpl_a': 'a'}[cur] * 7},
           'alias': ['demo.vercel.app', 'demo.example.com']}},
           'link': ({'type': 'github', 'org': repo.split('/')[0], 'repo': repo.split('/')[1], 'productionBranch': 'main'} if repo else None)},
           'deployments': [d('dpl_e', 'e', 'ERROR'), d('dpl_q', 'f', 'QUEUED'), d('dpl_g', 'g', 'BUILDING'),
                           d('dpl_c', 'c', 'READY'), d('dpl_b', 'b', 'READY'), d('dpl_a', 'a', 'READY')]},
          open(sys.argv[1], 'w'))
EOF
}
state dpl_b acme/demo
python3 "$TMP/fake.py" "$PORT" "$TMP/state.json" "$TMP/requests.log" & FAKE=$!
trap 'kill $FAKE 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 40); do python3 -c "import socket;socket.create_connection(('127.0.0.1',$PORT),0.2)" 2>/dev/null && break; sleep 0.1; done
export SHIPMATE_VERCEL_API="http://127.0.0.1:$PORT" VERCEL_TOKEN=test-token-123

# --- a stub vercel CLI that records its arguments ----------------------------------------------
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/cli.log"\n' "$TMP" > "$TMP/bin/vercel"; chmod +x "$TMP/bin/vercel"
export PATH="$TMP/bin:$PATH"

mkrepo() { # <name> <origin> — a git repo linked to prj_1
  local r="$TMP/$1"; mkdir -p "$r/.vercel"
  git -C "$r" init -q -b main 2>/dev/null || { git -C "$r" init -q; git -C "$r" checkout -q -b main; }
  git -C "$r" remote add origin "$2"
  printf '{"projectId":"prj_1","orgId":"team_x","projectName":"demo"}' > "$r/.vercel/project.json"
  printf '%s' "$r"
}
V="$(mkrepo v git@github.com:acme/demo.git)"
VA() { bash "$BIN/vercel-app.sh" "$@" 2>&1; }

echo "provider detection:"
P="$TMP/p"; mkdir -p "$P"
ok "nothing"            "$(provider_of "$P")" none
mkdir -p "$P/.vercel"; echo '{}' > "$P/.vercel/project.json"; ok "vercel link"  "$(provider_of "$P")" vercel
mkdir -p "$P/.do"; echo 'name: x' > "$P/.do/app.yaml";        ok "do spec wins" "$(provider_of "$P")" do
printf 'provider: vercel\n' > "$P/.shipmate.yml";              ok "explicit wins" "$(provider_of "$P")" vercel
ok "app.sh provider"    "$(bash "$BIN/app.sh" provider "$V")" vercel
has "app.sh none"       "$(bash "$BIN/app.sh" status "$TMP" 2>&1)" "has no deploy target"

echo "vercel reads:"
out="$(VA status "$V")"
has "status app"     "$out" "app:    demo (vercel, prj_1)"
has "status phase"   "$out" "deploy: READY bbbbbbb"
ok  "url prefers a custom domain" "$(VA url "$V")" "https://demo.example.com"
ok  "token in header" "$(tail -1 "$TMP/requests.log" | awk '{print $2, $3}')" "Bearer test-token-123"
ok  "team scoped"     "$(tail -1 "$TMP/requests.log" | grep -c 'teamId=team_x')" 1

echo "phase mapping (the commit the deploy built):"
ok "current → LIVE"          "$(VA phase "$V" bbbbbbb)" LIVE
ok "newer ready → SUPERSEDED" "$(VA phase "$V" ccccccc)" SUPERSEDED
ok "error → FAILED"          "$(VA phase "$V" eeeeeee)" FAILED
ok "queued → PENDING"        "$(VA phase "$V" fffffff)" PENDING
ok "building → BUILDING"     "$(VA phase "$V" ggggggg)" BUILDING
ok "never seen → UNKNOWN"    "$(VA phase "$V" 1234567)" UNKNOWN
ok "via app.sh"              "$(bash "$BIN/app.sh" phase "$V" bbbbbbb)" LIVE

echo "drift check:"
ok "consistent"            "$(VA check "$V" >/dev/null; echo $?)" 0
W="$(mkrepo w git@github.com:me/fork.git)"
has "wrong repo"           "$(VA check "$W")" "Vercel deploys from 'acme/demo' but origin is 'me/fork'"
state dpl_b ""
has "no git link"          "$(VA check "$V")" "no git connection"
state dpl_b acme/demo

echo "rollback / roll-forward:"
has "describe rollback"    "$(VA rollback "$V")" "Would roll production back from bbbbbbb to aaaaaaa"
has "warns about holds"    "$(VA rollback "$V")" "stops promoting new pushes until you roll forward"
ok  "describe runs no CLI" "$([ -f "$TMP/cli.log" ] && echo ran || echo none)" none
VA rollback "$V" --yes >/dev/null
ok  "--yes runs vercel rollback on the previous one" "$(tail -1 "$TMP/cli.log" | awk '{print $1, $2}')" "rollback dpl_a"
ok  "CLI never sees the token" "$(grep -c 'test-token' "$TMP/cli.log")" 0
state dpl_a acme/demo
has "describe roll-forward" "$(VA roll-forward "$V")" "Would roll production forward from aaaaaaa to ccccccc"
VA roll-forward "$V" --yes >/dev/null
ok  "--yes promotes the newest ready" "$(tail -1 "$TMP/cli.log" | awk '{print $1, $2}')" "promote dpl_c"
state dpl_c acme/demo
has "nothing to roll forward" "$(VA roll-forward "$V")" "already serving the newest deployment"
state dpl_a acme/demo
has "rollback with nothing older" "$(VA rollback "$V")" "no earlier ready production deployment"
state dpl_b acme/demo
has "never deletes" "$(VA destroy "$V")" "never deletes Vercel projects"

echo "credentials:"
out="$(HOME="$TMP/nohome" VERCEL_TOKEN= bash "$BIN/vercel-app.sh" status "$V" 2>&1)"
has "no creds → clear error" "$out" "no Vercel credentials"
mkdir -p "$TMP/cfg/Library/Application Support/com.vercel.cli"
printf '{"token":"test-token-123"}' > "$TMP/cfg/Library/Application Support/com.vercel.cli/auth.json"
has "falls back to the CLI login" "$(HOME="$TMP/cfg" VERCEL_TOKEN= bash "$BIN/vercel-app.sh" status "$V" 2>&1)" "app:    demo"
has "bad token → API error, no trace" "$(VERCEL_TOKEN=wrong bash "$BIN/vercel-app.sh" status "$V" 2>&1)" "Vercel API 403"
has "unlinked dir" "$(bash "$BIN/vercel-app.sh" status "$TMP" 2>&1)" "is not linked to a Vercel project"

echo "do-app.sh phase mapping (stub doctl):"
D="$TMP/d"; mkdir -p "$D/.do"; printf 'name: dapp\n' > "$D/.do/app.yaml"
cat > "$TMP/bin/doctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "apps list --format ID,Spec.Name --no-header") echo "app-1 dapp" ;;
  "apps list-deployments app-1 -o json") echo '[{"phase":"BUILDING","services":[{"source_commit_hash":"ddddddd1"}]},{"phase":"ACTIVE","services":[{"source_commit_hash":"aaaaaaa1"}]},{"phase":"SUPERSEDED","services":[{"source_commit_hash":"bbbbbbb1"}]},{"phase":"ERROR","services":[{"source_commit_hash":"eeeeeee1"}]},{"phase":"PENDING_BUILD","services":[{"source_commit_hash":"fffffff1"}]}]' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/doctl"
for pair in "aaaaaaa LIVE" "bbbbbbb SUPERSEDED" "eeeeeee FAILED" "fffffff PENDING" "ddddddd BUILDING" "1234567 UNKNOWN"; do
  set -- $pair; ok "do $1 → $2" "$(bash "$BIN/app.sh" phase "$D" "$1" 2>&1)" "$2"
done

echo
if [ "$fail" -eq 0 ]; then echo "✓ all $pass assertions passed"; exit 0
else echo "✗ $fail failed, $pass passed"; exit 1; fi
