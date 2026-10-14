#!/usr/bin/env bash
# Trust-boundary tests for the MCP server's HTTP transport (OAuth 2.1). Starts a real server on
# a free loopback port with a throwaway HOME, then plays both the legitimate client and the
# attacker: no token, the revoked legacy path token, forged and wrong-audience tokens, bad
# redirect URIs, PKCE failures, code replay, scope escalation, and refresh-token reuse.
# No tool call here reaches the bridge: every call is refused, or is tools/list.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "• node not installed — skipping MCP auth tests"; exit 0; }
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t shipmate)"
freeport() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }
PORT="$(freeport)"; CAP="$(freeport)"   # CAP: a local stand-in for ntfy that captures the sign-in push
mkdir -p "$TMP/home/.shipmate/mcp"
printf 'SHIPMATE_NTFY_TOPIC=test-topic\n' > "$TMP/home/.shipmate/voice.env"
printf 'legacytokenlegacytokenlegacytoken1234\n' > "$TMP/home/.shipmate/mcp/http-token"
HOME="$TMP/home" SHIPMATE_APPROVALS_DIR="$TMP/approvals" SHIPMATE_ACCESS_TTL=3600 SHIPMATE_NTFY_URL="http://127.0.0.1:$CAP" \
  node "$DIR/../mcp/shipmate-mcp.js" --http "$PORT" 2>"$TMP/server.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/.well-known/oauth-authorization-server" && break; sleep 0.1; done

HOME="$TMP/home" SHIPMATE_APPROVALS_DIR="$TMP/approvals" \
  node - "$PORT" "$DIR/../mcp/shipmate-mcp.js" "$TMP" "$CAP" <<'EOF'
const [port, server, tmp, cap] = process.argv.slice(2);
const pushes = [];
require('http').createServer((q, s) => { let b = ''; q.on('data', (c) => b += c);
  q.on('end', () => { pushes.push({ path: q.url, headers: q.headers, body: b }); s.end('ok'); }); }).listen(+cap, '127.0.0.1');
const { execFileSync } = require('child_process');
const crypto = require('crypto'), fs = require('fs'), path = require('path');
const base = `http://127.0.0.1:${port}`;
let pass = 0, fail = 0;
const ok = (name, got, want) => { if (got === want) pass++; else { fail++; console.log(`  ✗ ${name}: expected [${want}] got [${got}]`); } };
const b64url = (b) => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const req = async (p, opt = {}) => fetch(base + p, { redirect: 'manual', ...opt });
const form = (o) => ({ method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(o).toString() });
const rpc = (token, method, params) => req('/mcp', { method: 'POST',
  headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
const CB = 'https://claude.ai/api/mcp/auth_callback';

async function signIn(clientId, scope, verdict = 'approved') {
  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  const q = new URLSearchParams({ response_type: 'code', client_id: clientId, redirect_uri: CB, state: 'st8',
    code_challenge: challenge, code_challenge_method: 'S256', resource: `${base}/mcp`, ...(scope ? { scope } : {}) });
  let r = await req(`/authorize?${q}`);
  const wait = r.headers.get('location');
  r = await req(wait);
  const html = await r.text();
  const code = (html.match(/class="code">([A-Z0-9]{3}-[A-Z0-9]{3})</) || [])[1];
  execFileSync('node', [server, verdict === 'approved' ? '--approve-login' : '--deny-login', code], { env: process.env });
  r = await req(wait);
  return { loc: new URL(r.headers.get('location')), verifier, code };
}

(async () => {
  console.log('discovery:');
  let r = await req('/mcp', { method: 'POST', body: '{}' });
  ok('no token → 401', r.status, 401);
  ok('challenge names metadata', /resource_metadata="http:\/\/127\.0\.0\.1:\d+\/\.well-known\/oauth-protected-resource"/.test(r.headers.get('www-authenticate') || ''), true);
  const prm = await (await req('/.well-known/oauth-protected-resource')).json();
  ok('resource', prm.resource, `${base}/mcp`);
  const asm = await (await req('/.well-known/oauth-authorization-server')).json();
  ok('PKCE S256 only', JSON.stringify(asm.code_challenge_methods_supported), '["S256"]');
  ok('public clients only', JSON.stringify(asm.token_endpoint_auth_methods_supported), '["none"]');
  // fetch() drops a custom Host header, so send this one with curl
  ok('foreign Host refused', execFileSync('curl', ['-s', '-o', '/dev/null', '-w', '%{http_code}', '-H', 'Host: evil.example.com',
    `${base}/.well-known/oauth-authorization-server`]).toString(), '421');
  ok('tailnet Host → https issuer', JSON.parse(execFileSync('curl', ['-s', '-H', 'Host: box.tail1234.ts.net',
    `${base}/.well-known/oauth-authorization-server`]).toString()).issuer, 'https://box.tail1234.ts.net');

  console.log('legacy path token revoked:');
  r = await req('/mcp/legacytokenlegacytokenlegacytoken1234', { method: 'POST', body: '{}' });
  ok('old URL → 404', r.status, 404);
  ok('token file deleted', fs.existsSync(path.join(tmp, 'home/.shipmate/mcp/http-token')), false);

  console.log('registration:');
  const reg = (uris) => req('/register', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_name: 'test', redirect_uris: uris }) });
  ok('evil redirect refused', (await reg(['https://evil.example.com/cb'])).status, 400);
  ok('lookalike path refused', (await reg(['https://claude.ai/evil'])).status, 400);
  ok('http claude.ai refused', (await reg(['http://claude.ai/api/mcp/auth_callback'])).status, 400);
  ok('one bad uri spoils the set', (await reg([CB, 'https://evil.example.com/cb'])).status, 400);
  r = await reg([CB]); ok('claude callback accepted', r.status, 201);
  const client = (await r.json()).client_id;
  ok('loopback accepted', (await reg(['http://localhost:33418/callback'])).status, 201);

  console.log('authorize:');
  r = await req(`/authorize?${new URLSearchParams({ response_type: 'code', client_id: 'nope', redirect_uri: CB, code_challenge: 'x', code_challenge_method: 'S256' })}`);
  ok('unknown client: no redirect', r.status, 200);
  r = await req(`/authorize?${new URLSearchParams({ response_type: 'code', client_id: client, redirect_uri: 'https://evil.example.com/cb', code_challenge: 'x', code_challenge_method: 'S256' })}`);
  ok('unregistered redirect: no redirect', r.status, 200);
  r = await req(`/authorize?${new URLSearchParams({ response_type: 'code', client_id: client, redirect_uri: CB, code_challenge: 'x', code_challenge_method: 'plain' })}`);
  ok('plain PKCE refused', new URL(r.headers.get('location')).searchParams.get('error'), 'invalid_request');
  const denied = await signIn(client, null, 'denied');
  ok('owner deny → access_denied', denied.loc.searchParams.get('error'), 'access_denied');
  ok('state echoed', denied.loc.searchParams.get('state'), 'st8');

  console.log('sign-in push (needs a tailnet address on this host):');
  const hasTailnet = Object.values(require('os').networkInterfaces()).flat()
    .some((a) => a && a.family === 'IPv4' && /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(a.address));
  if (hasTailnet) {
    await new Promise((r) => setTimeout(r, 300));
    const p = pushes.find((x) => x.path === '/test-topic');
    ok('push sent to the topic', !!p, true);
    ok('Approve button → tailnet approve URL', /http, Approve, http:\/\/100\.[\d.]+:\d+\/approve\/[a-f0-9]{24}/.test((p && p.headers.actions) || ''), true);
    ok('Deny button present', /http, Deny, /.test((p && p.headers.actions) || ''), true);
    ok('push body shows the code', /Code on screen: [A-Z0-9]{3}-[A-Z0-9]{3}/.test((p && p.body) || ''), true);
  } else console.log('  • no tailnet address — push assertions skipped');
  ok('server survived the sign-in push', (await req('/.well-known/oauth-protected-resource')).status, 200);

  console.log('token exchange:');
  const s1 = await signIn(client, null);
  const code = s1.loc.searchParams.get('code');
  ok('approved → code', !!code, true);
  const tok = (o) => req('/token', form({ grant_type: 'authorization_code', client_id: client, redirect_uri: CB, ...o }));
  r = await tok({ code, code_verifier: b64url(crypto.randomBytes(32)) });
  ok('wrong verifier refused', r.status, 400);
  r = await tok({ code, code_verifier: s1.verifier });
  ok('code burned by the failed attempt', r.status, 400);
  const s2 = await signIn(client, null);
  r = await tok({ code: s2.loc.searchParams.get('code'), code_verifier: s2.verifier });
  ok('valid exchange', r.status, 200);
  const full = await r.json();
  ok('both scopes by default', full.scope, 'shipmate:read shipmate:execute');
  r = await tok({ code: s2.loc.searchParams.get('code'), code_verifier: s2.verifier });
  ok('code replay refused', r.status, 400);

  console.log('the MCP endpoint:');
  r = await rpc(full.access_token, 'tools/list', {});
  ok('valid token → tools', ((await r.json()).result.tools || []).length > 5, true);
  r = await rpc('forgedforgedforgedforgedforged', 'tools/list', {});
  ok('forged token → 401', r.status, 401);
  ok('invalid_token error', /error="invalid_token"/.test(r.headers.get('www-authenticate') || ''), true);
  r = await req('/mcp', { method: 'POST', headers: { Authorization: `Basic ${full.access_token}` }, body: '{}' });
  ok('non-bearer scheme → 401', r.status, 401);
  ok('db holds hashes, not tokens', fs.readFileSync(path.join(tmp, 'home/.shipmate/mcp/oauth.json'), 'utf8').includes(full.access_token), false);

  console.log('scopes:');
  const s3 = await signIn(client, 'shipmate:read');
  const ro = await (await tok({ code: s3.loc.searchParams.get('code'), code_verifier: s3.verifier })).json();
  ok('read-only scope granted', ro.scope, 'shipmate:read');
  for (const [name, args] of [['shipmate_execute', { request: 'x' }], ['shipmate_task_start', { task: 'x' }],
                              ['shipmate_log', { entry: 'x' }], ['shipmate_rollback', { confirm: true }], ['shipmate_counsel_toggle', { on: true }]]) {
    const out = await (await rpc(ro.access_token, 'tools/call', { name, arguments: args })).json();
    ok(`read token can't ${name}`, out.result && out.result.isError && /needs the shipmate:execute scope/.test(out.result.content[0].text), true);
  }
  r = await req(`/authorize?${new URLSearchParams({ response_type: 'code', client_id: client, redirect_uri: CB, scope: 'shipmate:admin', code_challenge: 'x', code_challenge_method: 'S256' })}`);
  ok('unknown scope → invalid_scope', new URL(r.headers.get('location')).searchParams.get('error'), 'invalid_scope');

  console.log('refresh rotation + reuse detection:');
  const rf = (t) => req('/token', form({ grant_type: 'refresh_token', client_id: client, refresh_token: t }));
  r = await rf(full.refresh_token); ok('refresh works', r.status, 200);
  const rotated = await r.json();
  ok('refresh token rotated', rotated.refresh_token !== full.refresh_token, true);
  r = await rf(full.refresh_token); ok('old refresh reused → refused', r.status, 400);
  r = await rpc(rotated.access_token, 'tools/list', {});
  ok('reuse revoked the whole family', r.status, 401);
  r = await req('/token', form({ grant_type: 'password', username: 'a', password: 'b' }));
  ok('password grant refused', r.status, 400);

  console.log('revocation:');
  const s5 = await signIn(client, null);
  const t5 = await (await tok({ code: s5.loc.searchParams.get('code'), code_verifier: s5.verifier })).json();
  await req('/revoke', form({ token: t5.refresh_token }));
  ok('revoked refresh kills access too', (await rpc(t5.access_token, 'tools/list', {})).status, 401);
  const s6 = await signIn(client, null);
  const t6 = await (await tok({ code: s6.loc.searchParams.get('code'), code_verifier: s6.verifier })).json();
  ok('--grants shows the client id', execFileSync('node', [server, '--grants'], { env: process.env }).toString().includes(client.slice(0, 8)), true);
  ok('--revoke-client', /^revoked [1-9]\d* token\(s\)/.test(execFileSync('node', [server, '--revoke-client', client.slice(0, 8)], { env: process.env }).toString()), true);
  ok('client tokens dead', (await rpc(t6.access_token, 'tools/list', {})).status, 401);
  execFileSync('node', [server, '--revoke-all'], { env: process.env });
  ok('--revoke-all leaves nothing', execFileSync('node', [server, '--grants'], { env: process.env }).toString().trim(), 'no active sign-ins');

  console.log('passkeys:');
  const env = { ...process.env, SHIPMATE_PUBLIC_URL: base, SHIPMATE_NO_CLIPBOARD: '1' };
  const cli = (...a) => execFileSync('node', [server, ...a], { env }).toString().trim();
  ok('no passkeys yet', cli('--passkeys'), 'no passkeys — sign-in uses the phone tap');
  r = await req('/passkey/enroll/notarealtokennotarealtoken'); ok('bogus enroll link', /Link expired/.test(await r.text()), true);
  const link = cli('--enroll-passkey'); const enrollPath = new URL(link).pathname;
  ok('enroll link minted', /^\/passkey\/enroll\/[A-Za-z0-9_-]{30,}$/.test(enrollPath), true);
  const optsOf = (html) => JSON.parse((html.match(/const o=(\{.*?\});\n/) || [])[1] || '{}');
  const eo = optsOf(await (await req(enrollPath)).text());
  ok('rp id is the host', eo.rp && eo.rp.id, '127.0.0.1');
  ok('user verification required', eo.authenticatorSelection && eo.authenticatorSelection.userVerification, 'required');
  const rpHash = crypto.createHash('sha256').update('127.0.0.1').digest();
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const credId = crypto.randomBytes(16);
  const authCreate = (flags, rp = rpHash) => Buffer.concat([rp, Buffer.from([flags]), Buffer.alloc(4), Buffer.alloc(16),
    Buffer.from([0, credId.length]), credId, Buffer.from([0xa5])]);
  const cdj = (type, challenge, origin = base) => Buffer.from(JSON.stringify({ type, challenge, origin }));
  const enroll = (o) => req(enrollPath, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({
    id: b64url(credId), alg: -7, name: 'test phone', publicKey: b64url(publicKey.export({ format: 'der', type: 'spki' })),
    clientDataJSON: b64url(cdj('webauthn.create', eo.challenge)), authenticatorData: b64url(authCreate(0x45)), ...o }) });
  ok('enroll: wrong origin', (await enroll({ clientDataJSON: b64url(cdj('webauthn.create', eo.challenge, 'https://evil.example.com')) })).status, 400);
  ok('enroll: wrong challenge', (await enroll({ clientDataJSON: b64url(cdj('webauthn.create', 'x' + eo.challenge)) })).status, 400);
  ok('enroll: wrong RP', (await enroll({ authenticatorData: b64url(authCreate(0x45, crypto.createHash('sha256').update('evil.example.com').digest())) })).status, 400);
  ok('enroll: no biometrics (UV off)', (await enroll({ authenticatorData: b64url(authCreate(0x41)) })).status, 400);
  ok('enroll: get-ceremony type', (await enroll({ clientDataJSON: b64url(cdj('webauthn.get', eo.challenge)) })).status, 400);
  ok('enroll: valid', (await enroll({})).status, 200);
  ok('link is single-use', /Link expired/.test(await (await req(enrollPath)).text()), true);
  ok('listed', /test phone {2}ES256/.test(cli('--passkeys')), true);

  const pushesBefore = pushes.length;
  const verifier = b64url(crypto.randomBytes(32));
  let rr = await req(`/authorize?${new URLSearchParams({ response_type: 'code', client_id: client, redirect_uri: CB, state: 'pk',
    code_challenge: b64url(crypto.createHash('sha256').update(verifier).digest()), code_challenge_method: 'S256' })}`);
  const waitPath = rr.headers.get('location'), pkPath = waitPath.replace('/wait/', '/passkey/');
  await new Promise((res) => setTimeout(res, 300));
  ok('no phone push once a passkey exists', pushes.length, pushesBefore);
  const page = async () => { const h = await (await req(waitPath)).text(); return { h, o: optsOf(h) }; };
  let pg = await page();
  ok('page offers the passkey', /Sign in with passkey/.test(pg.h), true);
  ok('page lists the credential', JSON.stringify(pg.o.allow), JSON.stringify([b64url(credId)]));
  const authGet = (flags, counter = 0) => { const b = Buffer.concat([rpHash, Buffer.from([flags]), Buffer.alloc(4)]); b.writeUInt32BE(counter, 33); return b; };
  const assertion = (challenge, o = {}) => {
    const ad = o.authData || authGet(0x05, o.counter || 0), cd = cdj('webauthn.get', challenge, o.origin);
    const sig = crypto.sign('sha256', Buffer.concat([ad, crypto.createHash('sha256').update(cd).digest()]), o.key || privateKey);
    return req(pkPath, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({
      id: o.id || b64url(credId), clientDataJSON: b64url(cd), authenticatorData: b64url(ad), signature: b64url(sig) }) });
  };
  const other = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey;
  ok('forged signature', (await assertion(pg.o.challenge, { key: other })).status, 400);
  ok('challenge burned by the failure', (await assertion(pg.o.challenge)).status, 400);
  pg = await page(); ok('phishing origin', (await assertion(pg.o.challenge, { origin: 'https://shipmate-login.example.com' })).status, 400);
  pg = await page(); ok('no biometrics', (await assertion(pg.o.challenge, { authData: authGet(0x01) })).status, 400);
  pg = await page(); ok('unknown passkey', (await assertion(pg.o.challenge, { id: b64url(crypto.randomBytes(16)) })).status, 400);
  ok('still not signed in', /Sign in with passkey/.test((await page()).h), true);
  pg = await page(); ok('valid assertion', (await assertion(pg.o.challenge, { counter: 7 })).status, 200);
  rr = await req(waitPath);
  const pcode = new URL(rr.headers.get('location')).searchParams.get('code');
  ok('passkey sign-in → code', !!pcode, true);
  ok('replay after success', (await assertion(pg.o.challenge, { counter: 8 })).status, 400);
  rr = await tok({ code: pcode, code_verifier: verifier });
  ok('code → tokens', rr.status, 200);
  // a cloned authenticator: counter goes backwards
  rr = await req(`/authorize?${new URLSearchParams({ response_type: 'code', client_id: client, redirect_uri: CB,
    code_challenge: b64url(crypto.createHash('sha256').update(verifier).digest()), code_challenge_method: 'S256' })}`);
  const wait2 = rr.headers.get('location');
  const o2 = optsOf(await (await req(wait2)).text());
  const ad2 = authGet(0x05, 3), cd2 = cdj('webauthn.get', o2.challenge);
  rr = await req(wait2.replace('/wait/', '/passkey/'), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({
    id: b64url(credId), clientDataJSON: b64url(cd2), authenticatorData: b64url(ad2),
    signature: b64url(crypto.sign('sha256', Buffer.concat([ad2, crypto.createHash('sha256').update(cd2).digest()]), privateKey)) }) });
  ok('counter went backwards → refused', rr.status, 400);
  ok('remove passkey', cli('--remove-passkey', b64url(credId).slice(0, 6)), 'removed 1 passkey(s)');
  ok('back to the phone tap', cli('--passkeys'), 'no passkeys — sign-in uses the phone tap');

  console.log('authenticator app (TOTP):');
  const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const unb32 = (s) => { let bits = 0, v = 0; const o = []; for (const ch of s.replace(/\s/g, '')) { v = (v << 5) | B32.indexOf(ch); bits += 5; if (bits >= 8) { o.push((v >>> (bits - 8)) & 255); bits -= 8; } } return Buffer.from(o); };
  const totp = (sec, step) => { const m = Buffer.alloc(8); m.writeUInt32BE(step >>> 0, 4); const h = crypto.createHmac('sha1', unb32(sec)).update(m).digest(); const o = h[19] & 15; return String((h.readUInt32BE(o) & 0x7fffffff) % 1e6).padStart(6, '0'); };
  const step = () => Math.floor(Date.now() / 30000);
  ok('none enrolled', cli('--totp-status'), 'no authenticator app enrolled');
  const tl = new URL(cli('--enroll-totp')).pathname;
  ok('totp link minted', /^\/totp\/enroll\/[A-Za-z0-9_-]{30,}$/.test(tl), true);
  let th = await (await req(tl)).text();
  ok('QR drawn as SVG', /<svg[^>]*>.*<\/svg>/s.test(th), true);
  const secret = (th.match(/<code[^>]*>([A-Z2-7 ]{20,})<\/code>/) || [])[1];
  ok('secret shown for manual entry', !!secret, true);
  ok('same secret on reload', (await (await req(tl)).text()).includes(secret), true);
  const enrollCode = (c) => req(tl, form({ code: c }));
  r = await enrollCode('000000'); ok('wrong confirm code', /That code didn&#39;t match/.test(await r.text()), true);
  r = await enrollCode(totp(secret, step())); ok('confirm with the real code', /Authenticator added/.test(await r.text()), true);
  ok('enrolled', /^authenticator app enrolled/.test(cli('--totp-status')), true);
  ok('link spent', /Link expired/.test(await (await req(tl)).text()), true);
  ok('secret not in audit log', fs.readFileSync(path.join(tmp, 'home/.shipmate/mcp/auth.log'), 'utf8').includes(secret.replace(/ /g, '')), false);

  const pb = pushes.length, v2 = b64url(crypto.randomBytes(32));
  const startLogin = async () => (await req(`/authorize?${new URLSearchParams({ response_type: 'code', client_id: client, redirect_uri: CB, state: 'tt',
    code_challenge: b64url(crypto.createHash('sha256').update(v2).digest()), code_challenge_method: 'S256' })}`)).headers.get('location');
  let w = await startLogin();
  await new Promise((res) => setTimeout(res, 300));
  ok('no push with an authenticator', pushes.length, pb);
  ok('page asks for a code', /6-digit code from your authenticator app/.test(await (await req(w)).text()), true);
  const sendCode = (wp, c) => req(wp.replace('/wait/', '/totp/'), form({ code: c }));
  r = await sendCode(w, '123456'); ok('wrong code → back with error', r.headers.get('location'), w + '?e=1');
  ok('the code used to enroll is spent', (await sendCode(w, totp(secret, step()))).headers.get('location'), w + '?e=1');
  ok('a far-future code refused', (await sendCode(w, totp(secret, step() + 5))).headers.get('location'), w + '?e=1');
  const next = totp(secret, step() + 1); // ±1 step allowed for clock drift
  r = await sendCode(w, next); ok('next-window code accepted', r.headers.get('location'), w);
  r = await req(w); const tcode = new URL(r.headers.get('location')).searchParams.get('code');
  ok('code sign-in → authorization code', !!tcode, true);
  w = await startLogin();
  ok('replaying an accepted code fails', (await sendCode(w, next)).headers.get('location'), w + '?e=1');
  for (let i = 0; i < 4; i++) await sendCode(w, '000000'); // tries 2–5 (the replay was the first)
  r = await sendCode(w, '000000'); ok('sixth try cancels the sign-in', /Too many wrong codes/.test(await r.text()), true);
  ok('cancelled sign-in is gone', /Sign-in expired/.test(await (await req(w)).text()), true);
  ok('remove authenticator', cli('--remove-totp'), 'authenticator app removed');

  console.log('audit trail:');
  const auditLog = fs.readFileSync(path.join(tmp, 'home/.shipmate/mcp/auth.log'), 'utf8');
  for (const ev of ['register_refused', 'authorize_denied', 'token_refused', 'scope_refused', 'refresh_reuse_revoked', 'mcp_refused', 'revoke_all',
                    'passkey_enroll_refused', 'passkey_enrolled', 'passkey_signin_refused', 'passkey_signin', 'passkey_removed',
                    'totp_enroll_refused', 'totp_enrolled', 'totp_signin_refused', 'totp_signin', 'totp_removed'])
    ok(`audit has ${ev}`, auditLog.includes(`"event":"${ev}"`), true);
  ok('audit never holds a token', auditLog.includes(full.access_token) || auditLog.includes(full.refresh_token), false);

  console.log();
  if (fail === 0) { console.log(`✓ all ${pass} assertions passed`); process.exit(0); }
  console.log(`✗ ${fail} failed, ${pass} passed`); process.exit(1);
})().catch((e) => { console.log('✗ crashed:', e.message); process.exit(1); });
EOF
