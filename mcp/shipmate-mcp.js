#!/usr/bin/env node
/*
 * shipmate-mcp — a zero-dependency MCP server over the shipmate engine.
 *
 * Transports:
 *   stdio (default)         claude mcp add --scope user shipmate -- node .../mcp/shipmate-mcp.js
 *   Streamable HTTP         node .../mcp/shipmate-mcp.js --http [port]     (default 8787)
 *     Binds 127.0.0.1 ONLY. Publish with Tailscale Funnel. POST /mcp requires an OAuth 2.1
 *     bearer token from this server's own authorization server (PKCE, dynamic registration
 *     limited to Claude callbacks + loopback, scopes shipmate:read / shipmate:execute, owner
 *     approval by a tailnet-only tap). See mcp/README.md.
 *   Admin (on the host):    --approve-login <CODE> · --deny-login <CODE> · --grants · --revoke-all
 *                           --enroll-passkey · --passkeys · --remove-passkey <id>
 *                           --enroll-totp · --totp-status · --remove-totp
 *
 * Tools (both transports):
 *   shipmate_plan      — describe what a request would do + cost. Read-only, always safe.
 *   shipmate_execute   — act. STRUCTURALLY gated: only works within 10 minutes of a
 *                        shipmate_plan for the same project, and the grant is single-use.
 *   shipmate_status    — running/finished background jobs.
 *   shipmate_task_start / shipmate_task_result / shipmate_task_stop — background agent jobs
 *                        (branch-only, never deploy/bill — the bridge enforces the rules).
 *
 * It shells out to voice/shipmate-voice.sh's machine interface, so voice and MCP are two
 * mouths on one tested engine.
 */
'use strict';

const { execFile, spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');
const os = require('os');
const readline = require('readline');

const BRIDGE = path.join(__dirname, '..', 'voice', 'shipmate-voice.sh');
const STATE_DIR = path.join(os.homedir(), '.shipmate', 'mcp');
const PLAN_GRANT = path.join(STATE_DIR, 'plan-grant.json');
const TOKEN_FILE = path.join(STATE_DIR, 'http-token');
const PLAN_TTL_MS = 10 * 60 * 1000;
const TURN_TIMEOUT_MS = 10 * 60 * 1000;

const log = (...a) => console.error('[shipmate-mcp]', ...a);

let CHANNEL = 'mcp-stdio'; // 'claude-app' once serving HTTP; the bridge's ledger lines carry it

function bridge(args) {
  return new Promise((resolve) => {
    execFile('bash', [BRIDGE, ...args],
      { timeout: TURN_TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024, env: { ...process.env, SHIPMATE_CHANNEL: CHANNEL } },
      (err, stdout, stderr) => {
        // The bridge speaks errors on stdout by design; prefer its words over exit codes.
        const text = (stdout || '').trim() || (stderr || '').trim()
          || (err ? `shipmate bridge failed: ${err.message}` : '');
        resolve({ text, isError: !!err && !(stdout || '').trim() });
      });
  });
}

// ---- two-phase gate ------------------------------------------------------------------

// The grant itself (mint on plan, consume on execute) lives in voice/lib/gate.sh and runs
// inside the bridge, so every channel shares it. This server only reads the grant file for the
// Ship-it button: a valid nonce on a tailnet-only POST runs "ship it" for the armed project.
function readGrant() {
  try { return JSON.parse(fs.readFileSync(PLAN_GRANT, 'utf8')); } catch { return null; }
}

// ---- tools ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: 'shipmate_plan',
    description: 'Describe what a deploy/ops request would do and its exact cost. Read-only ' +
      '(code-enforced): creates, changes, charges, and publishes nothing. Also the only way ' +
      'to unlock shipmate_execute for the next 10 minutes.',
    inputSchema: {
      type: 'object',
      properties: {
        request: { type: 'string', description: 'Plain-language request, e.g. "deploy this to DigitalOcean"' },
        project: { type: 'string', description: 'Project name under the sites root (default: current session project)' },
      },
      required: ['request'],
    },
  },
  {
    name: 'shipmate_execute',
    description: 'Execute the previously planned request. The engine enforces the gate: without ' +
      'a single-use grant from a shipmate_plan for the same project in the last 10 minutes, the ' +
      'call runs as a plan instead, is read back, and arms the grant — call execute again to do ' +
      'it. Cost-neutral steps proceed; new spend, resizes, and deletions still stop and describe themselves.',
    inputSchema: {
      type: 'object',
      properties: {
        request: { type: 'string', description: 'What to execute — normally "go ahead with the plan"' },
        project: { type: 'string', description: 'Must match the planned project' },
      },
      required: ['request'],
    },
  },
  {
    name: 'shipmate_status',
    description: 'Status of shipmate background jobs (running/done/failed, per project).',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'shipmate_task_start',
    description: 'Start a background agent job (build/test work on a fresh branch; it never ' +
      'deploys, never pushes the default branch, never creates billed resources). Returns ' +
      'immediately with a job number; a push notification fires when it finishes.',
    inputSchema: {
      type: 'object',
      properties: {
        task: { type: 'string', description: 'What to build/fix/test, e.g. "add dark mode"' },
        project: { type: 'string', description: 'Project name under the sites root' },
      },
      required: ['task'],
    },
  },
  {
    name: 'shipmate_task_result',
    description: 'The summary of a finished background job (latest job if no number given).',
    inputSchema: {
      type: 'object',
      properties: { job_id: { type: 'integer', description: 'Job number from shipmate_task_start' } },
    },
  },
  {
    name: 'shipmate_task_stop',
    description: 'Stop a running background job (latest running job if no number given).',
    inputSchema: {
      type: 'object',
      properties: { job_id: { type: 'integer', description: 'Job number to stop' } },
    },
  },
  {
    name: 'shipmate_counsel',
    description: 'Deliberate on a technical/infra question — always read-only, never acts. ' +
      'With the counsel toggle OFF (default) the single default Anthropic model answers. ' +
      'With it ON, the question fans out to several models in parallel and a chair ' +
      'synthesizes, naming where the panel disagrees.',
    inputSchema: {
      type: 'object',
      properties: {
        question: { type: 'string', description: 'The question to deliberate on' },
        project: { type: 'string', description: 'Project name for context (default: current session project)' },
      },
      required: ['question'],
    },
  },
  {
    name: 'shipmate_doctor',
    description: 'One-sentence system health check: internet, tailnet, MCP server, provider ' +
      'auth, disk, running jobs, queued dead-zone intents. Deterministic and fast.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'shipmate_rollback',
    description: 'Roll a project back to its previous successful deployment (DigitalOcean; ' +
      'cost-neutral, reversible by redeploying). Without confirm:true it only DESCRIBES what ' +
      'would happen; with confirm:true it acts, deterministically — no model in the loop.',
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string', description: 'Project name under the sites root' },
        confirm: { type: 'boolean', description: 'true = actually roll back; false/omitted = describe only' },
      },
      required: ['project'],
    },
  },
  {
    name: 'shipmate_log',
    description: "Append a timestamped entry to a project's captains-log.md and commit it " +
      '(deterministic — the words are stored verbatim). publish:true also pushes, which on ' +
      'a deploy-on-push repo makes the entry live.',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'The log entry, verbatim' },
        project: { type: 'string', description: 'Project name (default: current session project)' },
        publish: { type: 'boolean', description: 'true = also git push (may trigger a deploy)' },
      },
      required: ['text'],
    },
  },
  {
    name: 'shipmate_counsel_toggle',
    description: 'Turn multi-model counsel deliberation on or off (off = single Anthropic model, the default).',
    inputSchema: {
      type: 'object',
      properties: { enabled: { type: 'boolean', description: 'true = counsel on, false = off' } },
      required: ['enabled'],
    },
  },
];

async function callTool(name, args) {
  const a = args || {};
  const proj = a.project || '-';
  const wrap = ({ text, isError }) =>
    ({ content: [{ type: 'text', text }], ...(isError ? { isError: true } : {}) });

  switch (name) {
    case 'shipmate_plan':
      return wrap(await bridge(['--turn', 'plan', proj, a.request]));
    case 'shipmate_execute':
      // The plan→execute grant is minted and consumed inside the bridge (voice/lib/gate.sh),
      // so Siri, this server and the terminal share one gate instead of three.
      return wrap(await bridge(['--turn', 'execute', proj, a.request]));
    case 'shipmate_status':
      return wrap(await bridge(['--status-report']));
    case 'shipmate_task_start':
      return wrap(await bridge(['--dispatch', proj, a.task]));
    case 'shipmate_task_result':
      return wrap(await bridge(['--result', ...(a.job_id != null ? [String(a.job_id)] : [])]));
    case 'shipmate_task_stop':
      return wrap(await bridge(['--stop', ...(a.job_id != null ? [String(a.job_id)] : [])]));
    case 'shipmate_doctor':
      return wrap(await bridge(['--doctor']));
    case 'shipmate_rollback':
      return wrap(await bridge(['--rollback', proj, ...(a.confirm === true ? ['--yes'] : [])]));
    case 'shipmate_log':
      return wrap(await bridge(['--log', proj, ...(a.publish === true ? ['--publish'] : []), a.text]));
    case 'shipmate_counsel':
      return wrap(await bridge(['--counsel', proj, a.question]));
    case 'shipmate_counsel_toggle':
      return wrap(await bridge(['--counsel-set', a.enabled ? 'on' : 'off']));
    default:
      throw Object.assign(new Error(`unknown tool: ${name}`), { code: -32602 });
  }
}

// The decision ledger shared with the bridge (skills/deploy/lib/ledger.sh writes the same shape).
function ledgerRecord(policy, outcome, project, attempted, detail) {
  try {
    const file = process.env.SHIPMATE_LEDGER || path.join(os.homedir(), '.shipmate', 'ledger.jsonl');
    const ts = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    const id = ts.replace(/\D/g, '').slice(0, 14) + '-' + crypto.randomBytes(3).toString('hex');
    fs.appendFileSync(file, JSON.stringify({ id, ts, type: 'decision', policy, outcome, project,
      attempted: String(attempted).slice(0, 400), channel: CHANNEL, detail: String(detail || '').slice(0, 400) }) + '\n', { mode: 0o600 });
  } catch {}
}

function readOnlyCall(name, args) {
  if (READ_TOOLS.has(name)) return true;
  if (name === 'shipmate_rollback') return !(args && args.confirm === true); // describe-only is a read
  return false;
}

// ---- JSON-RPC core (transport-independent) ---------------------------------------------

// Returns the response object for a request, or null for a notification.
async function handle(msg, ctx) {
  const { id, method, params } = msg;
  const isNotification = id === undefined;
  const reply = (result) => (isNotification ? null : { jsonrpc: '2.0', id, result });
  const fail = (code, message) => (isNotification ? null : { jsonrpc: '2.0', id, error: { code, message } });

  switch (method) {
    case 'initialize':
      return reply({
        protocolVersion: (params && params.protocolVersion) || '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'shipmate', version: '0.2.0' },
      });
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return null;
    case 'ping':
      return reply({});
    case 'tools/list':
      return reply({ tools: TOOLS });
    case 'tools/call':
      try {
        // Authorization: an HTTP token carries scopes; stdio (the local user) carries all.
        const scopes = (ctx && ctx.scopes) || SCOPES;
        if (!scopes.includes('shipmate:execute') && !readOnlyCall(params.name, params.arguments)) {
          if (ctx) {
            audit('scope_refused', { client: ctx.client, tool: params.name });
            ledgerRecord('scope', 'refused', (params.arguments && params.arguments.project) || '-', params.name,
              `read-only sign-in (client ${ctx.client})`);
          }
          return reply({ content: [{ type: 'text', text: `${params.name} needs the shipmate:execute scope; this sign-in is read-only.` }], isError: true });
        }
        return reply(await callTool(params.name, params.arguments));
      }
      catch (e) { return fail(e.code || -32603, e.message); }
    default:
      return fail(-32601, `method not found: ${method}`);
  }
}

// ---- stdio transport --------------------------------------------------------------------

function serveStdio() {
  const out = (m) => m && process.stdout.write(JSON.stringify(m) + '\n');
  readline.createInterface({ input: process.stdin, terminal: false }).on('line', async (line) => {
    line = line.trim();
    if (!line) return;
    let msg;
    try { msg = JSON.parse(line); }
    catch { return out({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); }
    out(await handle(msg).catch((e) => ({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: e.message } })));
  });
  log(`serving shipmate tools over stdio (bridge: ${BRIDGE})`);
}

// ---- Streamable HTTP transport + OAuth 2.1 ------------------------------------------------
//
// The HTTP endpoint is POST /mcp, published through Tailscale Funnel. It accepts only a bearer
// access token issued by this server's own OAuth 2.1 authorization server (MCP authorization
// spec): protected-resource + authorization-server metadata, dynamic client registration
// restricted to known callback URLs, authorization code + PKCE (S256), 1-hour access tokens,
// rotating 30-day refresh tokens with reuse detection, and two scopes:
//   shipmate:read     plan, status, doctor, counsel, task results, rollback descriptions
//   shipmate:execute  everything that changes something (execute, jobs, log, rollback confirm)
// Signing in requires the owner: /authorize pushes an Approve/Deny tap that only a device on
// the owner's tailnet can press (the onboard server's /approve endpoint), with a terminal
// fallback (--approve-login <code>). Tokens are stored as SHA-256 hashes, never in the clear.
// The pre-OAuth path token (/mcp/<token>) is revoked: that path is a 404.

const OAUTH_FILE = path.join(STATE_DIR, 'oauth.json');
const APPROVALS = process.env.SHIPMATE_APPROVALS_DIR || path.join(os.homedir(), '.shipmate', 'approvals');
const SCOPES = ['shipmate:read', 'shipmate:execute'];
const ACCESS_TTL_S = parseInt(process.env.SHIPMATE_ACCESS_TTL || '3600', 10);
const REFRESH_TTL_S = 30 * 24 * 3600;
const CODE_TTL_S = 300;
const LOGIN_TTL_S = 300;
const READ_TOOLS = new Set(['shipmate_plan', 'shipmate_status', 'shipmate_doctor',
  'shipmate_counsel', 'shipmate_task_result']);

const sha = (t) => crypto.createHash('sha256').update(String(t)).digest('hex');
const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const rand = (n) => b64url(crypto.randomBytes(n));
const now = () => Math.floor(Date.now() / 1000);

function oauthLoad() {
  let db;
  try { db = JSON.parse(fs.readFileSync(OAUTH_FILE, 'utf8')); } catch { db = {}; }
  for (const k of ['clients', 'codes', 'access', 'refresh', 'spent']) db[k] = db[k] || {};
  // drop anything expired on every load — the file never grows without bound
  const t = now();
  for (const k of ['codes', 'access', 'refresh']) for (const h of Object.keys(db[k])) if (db[k][h].exp < t) delete db[k][h];
  for (const h of Object.keys(db.spent)) if (db.spent[h].exp < t) delete db.spent[h];
  return db;
}
function oauthSave(db) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = OAUTH_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(db), { mode: 0o600 });
  fs.renameSync(tmp, OAUTH_FILE);
}

// Callback URLs a client may register: Claude's hosted connector callbacks plus loopback (Claude
// Code and other local clients). Extra ones via SHIPMATE_OAUTH_REDIRECTS (comma-separated).
function redirectAllowed(u) {
  const extra = (process.env.SHIPMATE_OAUTH_REDIRECTS || '').split(',').map((x) => x.trim()).filter(Boolean);
  if (extra.includes(u)) return true;
  let url; try { url = new URL(u); } catch { return false; }
  if (url.hash) return false;
  if (url.protocol === 'https:' && ['claude.ai', 'claude.com'].includes(url.hostname)
      && url.pathname === '/api/mcp/auth_callback') return true;
  if (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) return true;
  return false;
}

// Public base URL: SHIPMATE_PUBLIC_URL, else the request's Host when it is a tailnet name
// (Funnel) or loopback. Any other Host is refused, so metadata can't be pointed elsewhere.
function baseUrl(req) {
  if (process.env.SHIPMATE_PUBLIC_URL) return process.env.SHIPMATE_PUBLIC_URL.replace(/\/+$/, '');
  const host = String(req.headers.host || '').toLowerCase();
  if (/^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$/.test(host)) return `https://${host}`;
  if (/^(localhost|127\.0\.0\.1)(:\d+)?$/.test(host)) return `http://${host}`;
  return null;
}

function issueTokens(db, clientId, scope, resource, fam) {
  const access = rand(32), refresh = rand(32);
  fam = fam || rand(12);
  db.access[sha(access)] = { client_id: clientId, scope, resource, fam, exp: now() + ACCESS_TTL_S };
  db.refresh[sha(refresh)] = { client_id: clientId, scope, resource, fam, exp: now() + REFRESH_TTL_S };
  return { access_token: access, token_type: 'Bearer', expires_in: ACCESS_TTL_S, refresh_token: refresh, scope };
}
function revokeFamily(db, fam) {
  for (const k of ['access', 'refresh']) for (const h of Object.keys(db[k])) if (db[k][h].fam === fam) delete db[k][h];
}

function audit(event, detail) {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.appendFileSync(path.join(STATE_DIR, 'auth.log'),
      JSON.stringify({ ts: new Date().toISOString(), event, ...detail }) + '\n', { mode: 0o600 });
  } catch {}
}

// ---- passkeys (WebAuthn) -------------------------------------------------------------------
//
// Once the owner enrolls a passkey, signing in to shipmate means Face ID / Touch ID on their own
// device: the browser signs a one-time challenge with a key bound to this server's origin, so it
// can't be phished or replayed, and nothing has to be delivered to a phone. The phone-push
// approval is then off for sign-in; `--approve-login` on the host stays as recovery.
//
// Enrolling needs a one-time link (10 minutes, single use) that only the owner can mint: from the
// tailnet-only onboarding page (/passkey) or on the host (--enroll-passkey). Attestation is
// "none": the enrollment link is the root of trust, not the authenticator's maker.
// Verification is zero-dependency: clientDataJSON (type, challenge, origin), authenticatorData
// (RP ID hash, user-present + user-verified flags, sign count) and an ES256 or RS256 signature.

const PASSKEYS_FILE = path.join(STATE_DIR, 'passkeys.json');
const ENROLL_FILE = path.join(STATE_DIR, 'passkey-enroll.json');
const PUBLIC_URL_FILE = path.join(STATE_DIR, 'public-url');
const ENROLL_TTL_S = 600;

const b64urlDecode = (t) => Buffer.from(String(t || '').replace(/-/g, '+').replace(/_/g, '/'), 'base64');
const readJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return d; } };
const writeJson = (f, v) => {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f + '.tmp', JSON.stringify(v, null, 1), { mode: 0o600 }); fs.renameSync(f + '.tmp', f);
};
const loadPasskeys = () => readJson(PASSKEYS_FILE, []);
const savePasskeys = (list) => writeJson(PASSKEYS_FILE, list);

// The public origin, as the HTTP server last saw it (the onboarding process can't ask Tailscale
// under launchd, so the HTTP server records it whenever it serves a tailnet request).
function publicUrl() {
  if (process.env.SHIPMATE_PUBLIC_URL) return process.env.SHIPMATE_PUBLIC_URL.replace(/\/+$/, '');
  try { return fs.readFileSync(PUBLIC_URL_FILE, 'utf8').trim(); } catch { return ''; }
}

function mintEnrollToken() {
  const t = rand(24), db = readJson(ENROLL_FILE, {}), n = now();
  for (const k of Object.keys(db)) if (db[k] < n) delete db[k];
  db[sha(t)] = n + ENROLL_TTL_S; writeJson(ENROLL_FILE, db);
  return t;
}
function enrollTokenValid(t, consume) {
  const db = readJson(ENROLL_FILE, {}), h = sha(t || ''), ok = !!db[h] && db[h] >= now();
  if (consume && db[h]) { delete db[h]; writeJson(ENROLL_FILE, db); }
  return ok;
}

// authenticatorData: rpIdHash(32) flags(1) signCount(4) [aaguid(16) credIdLen(2) credId …]
function parseAuthData(buf) {
  if (buf.length < 37) throw new Error('authenticator data too short');
  const flags = buf[32], out = { rpIdHash: buf.subarray(0, 32), up: !!(flags & 1), uv: !!(flags & 4),
    signCount: buf.readUInt32BE(33) };
  if (flags & 0x40 && buf.length >= 55) {
    const len = buf.readUInt16BE(53);
    out.credId = buf.subarray(55, 55 + len);
  }
  return out;
}

// Common checks for both ceremonies; returns the parsed authenticator data or throws.
function checkCeremony(kind, clientDataJSON, authData, challenge, origin) {
  let cd;
  try { cd = JSON.parse(clientDataJSON.toString('utf8')); } catch { throw new Error('bad clientDataJSON'); }
  if (cd.type !== kind) throw new Error(`wrong ceremony type ${cd.type}`);
  if (!challenge || cd.challenge !== challenge) throw new Error('challenge mismatch');
  if (cd.origin !== origin) throw new Error(`origin mismatch (${String(cd.origin).slice(0, 60)})`);
  const ad = parseAuthData(authData);
  const rpId = new URL(origin).hostname;
  if (!crypto.timingSafeEqual(ad.rpIdHash, crypto.createHash('sha256').update(rpId).digest())) throw new Error('RP ID mismatch');
  if (!ad.up) throw new Error('user not present');
  if (!ad.uv) throw new Error('user not verified (Face ID / Touch ID / device PIN required)');
  return ad;
}

function passkeyRegister(body, challenge, origin) {
  const clientData = b64urlDecode(body.clientDataJSON), authData = b64urlDecode(body.authenticatorData);
  const ad = checkCeremony('webauthn.create', clientData, authData, challenge, origin);
  const rawId = b64urlDecode(body.id);
  if (!ad.credId || !rawId.length || !ad.credId.equals(rawId)) throw new Error('credential id mismatch');
  const alg = Number(body.alg);
  if (alg !== -7 && alg !== -257) throw new Error(`unsupported algorithm ${alg}`);
  const key = crypto.createPublicKey({ key: b64urlDecode(body.publicKey), format: 'der', type: 'spki' });
  if (alg === -7 && key.asymmetricKeyDetails && key.asymmetricKeyDetails.namedCurve !== 'prime256v1') throw new Error('ES256 needs P-256');
  const list = loadPasskeys();
  if (list.some((k) => k.id === body.id)) throw new Error('passkey already enrolled');
  const entry = { id: b64url(rawId), alg, spki: b64url(key.export({ format: 'der', type: 'spki' })),
    name: String(body.name || 'passkey').slice(0, 60), created: now(), signCount: ad.signCount, lastUsed: 0 };
  list.push(entry); savePasskeys(list);
  return entry;
}

function passkeyAssert(body, challenge, origin) {
  const list = loadPasskeys(), k = list.find((x) => x.id === body.id);
  if (!k) throw new Error('unknown passkey');
  const clientData = b64urlDecode(body.clientDataJSON), authData = b64urlDecode(body.authenticatorData);
  const ad = checkCeremony('webauthn.get', clientData, authData, challenge, origin);
  const signed = Buffer.concat([authData, crypto.createHash('sha256').update(clientData).digest()]);
  const pub = crypto.createPublicKey({ key: b64urlDecode(k.spki), format: 'der', type: 'spki' });
  const good = k.alg === -7
    ? crypto.verify('sha256', signed, { key: pub, dsaEncoding: 'der' }, b64urlDecode(body.signature))
    : crypto.verify('sha256', signed, pub, b64urlDecode(body.signature));
  if (!good) throw new Error('bad signature');
  // A counter that goes backwards means a cloned authenticator. Synced passkeys report 0: allowed.
  if (ad.signCount !== 0 && ad.signCount <= k.signCount) throw new Error('sign count did not increase (possible clone)');
  k.signCount = ad.signCount; k.lastUsed = now(); savePasskeys(list);
  return k;
}

// ---- authenticator-app codes (TOTP, RFC 6238) ------------------------------------------------
//
// For owners whose authenticator app (Microsoft Authenticator, Google Authenticator, 1Password…)
// is where their second factors live. Enrolled through the same one-time link as a passkey; the
// QR code is drawn on the server (vendored qrcode-generator, MIT) and the secret never leaves
// that page. Codes: SHA-1, 6 digits, 30 s, ±1 step for clock drift, never reusable (the last
// accepted step is stored), five tries per sign-in. Weaker than a passkey (a convincing fake page
// could ask for a code), far stronger than a push any tailnet device could tap.

const TOTP_FILE = path.join(STATE_DIR, 'totp.json');
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function base32(buf) {
  let bits = 0, val = 0, out = '';
  for (const b of buf) { val = (val << 8) | b; bits += 8; while (bits >= 5) { out += B32[(val >>> (bits - 5)) & 31]; bits -= 5; } }
  if (bits > 0) out += B32[(val << (5 - bits)) & 31];
  return out;
}
function unbase32(s) {
  let bits = 0, val = 0; const out = [];
  for (const ch of String(s).toUpperCase().replace(/[^A-Z2-7]/g, '')) {
    val = (val << 5) | B32.indexOf(ch); bits += 5;
    if (bits >= 8) { out.push((val >>> (bits - 8)) & 255); bits -= 8; }
  }
  return Buffer.from(out);
}
function totpAt(secretB32, step) {
  const msg = Buffer.alloc(8); msg.writeUInt32BE(Math.floor(step / 2 ** 32), 0); msg.writeUInt32BE(step >>> 0, 4);
  const h = crypto.createHmac('sha1', unbase32(secretB32)).update(msg).digest();
  const o = h[h.length - 1] & 15;
  return String(((h.readUInt32BE(o) & 0x7fffffff) % 1e6)).padStart(6, '0');
}
const totpStep = () => Math.floor(Date.now() / 1000 / 30);
// Returns the matching step, or -1. Rejects any step at or before the last one accepted.
function totpMatch(secretB32, code, lastStep) {
  code = String(code || '').replace(/\s/g, '');
  if (!/^\d{6}$/.test(code)) return -1;
  const s0 = totpStep();
  for (const st of [s0, s0 - 1, s0 + 1]) {
    if (st <= (lastStep || 0)) continue;
    if (crypto.timingSafeEqual(Buffer.from(totpAt(secretB32, st)), Buffer.from(code))) return st;
  }
  return -1;
}
const loadTotp = () => readJson(TOTP_FILE, null);
const totpEnrolled = () => { const t = loadTotp(); return !!(t && t.confirmed); };
function qrSvg(text) {
  const qrcode = require(path.join(__dirname, 'vendor', 'qrcode.js'));
  const q = qrcode(0, 'M'); q.addData(text); q.make();
  return q.createSvgTag({ cellSize: 6, margin: 4, scalable: false });
}

// ---- sign-in approval (reuses the tap-to-confirm channel) ----------------------------------

const logins = new Map(); // pollId → { nonce, userCode, q, exp, passkey, challenge, access }
const enrollChallenges = new Map(); // sha(enroll token) → { challenge, exp }
const loginRate = [];      // timestamps of recent /authorize requests

function tailnetIp() {
  for (const addrs of Object.values(os.networkInterfaces())) for (const a of addrs || []) {
    if (a.family !== 'IPv4' && a.family !== 4) continue;
    const o = a.address.split('.').map(Number);
    if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) return a.address;
  }
  return '';
}

function requestLoginApproval(desc, push = true) {
  const nonce = crypto.randomBytes(12).toString('hex');
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  let userCode = '';
  for (const b of crypto.randomBytes(6)) userCode += alphabet[b % alphabet.length];
  userCode = userCode.slice(0, 3) + '-' + userCode.slice(3);
  fs.mkdirSync(APPROVALS, { recursive: true });
  fs.writeFileSync(path.join(APPROVALS, nonce), `pending ${now()}\n${desc} — code ${userCode}\nlogin ${userCode}\n`, { mode: 0o600 });
  const topic = readNtfyTopic(), ip = tailnetIp();
  let pushed = false;
  if (push && topic && ip) {
    // A failed push must never take the server down: the page also offers --approve-login.
    // Header values must be Latin-1 for node's http client, so the button labels are plain text.
    try {
      const port = process.env.SHIPMATE_ONBOARD_PORT || '8790';
      const target = `${process.env.SHIPMATE_NTFY_URL || 'https://ntfy.sh'}/${topic}`;
      const lib = target.startsWith('http:') ? http : require('https');
      const req = lib.request(target, {
        method: 'POST', timeout: 10000,
        headers: {
          Title: 'shipmate sign-in', Priority: 'high',
          Actions: `http, Approve, http://${ip}:${port}/approve/${nonce}, method=POST, clear=true; ` +
                   `http, Deny, http://${ip}:${port}/deny/${nonce}, method=POST, clear=true`,
        },
      });
      req.on('error', (e) => log(`sign-in push failed: ${e.message}`));
      req.on('timeout', () => req.destroy());
      req.end(`${desc}\nCode on screen: ${userCode}. Only approve if you just started this.`);
      pushed = true;
    } catch (e) { log(`sign-in push failed: ${e.message}`); }
  }
  return { nonce, userCode, pushed };
}

function loginVerdict(nonce) {
  try {
    const first = fs.readFileSync(path.join(APPROVALS, nonce), 'utf8').split('\n')[0];
    return first.split(' ')[0]; // pending | approved | denied
  } catch { return 'expired'; }
}

// CLI fallback: `shipmate-mcp.js --approve-login ABC-123` (or --deny-login) on the host itself.
function cliLoginDecision(code, verdict) {
  code = String(code || '').toUpperCase();
  let hit = false;
  try {
    for (const f of fs.readdirSync(APPROVALS)) {
      const file = path.join(APPROVALS, f);
      const lines = fs.readFileSync(file, 'utf8').split('\n');
      if (lines[0].startsWith('pending') && lines.includes(`login ${code}`)) {
        fs.writeFileSync(file, [`${verdict} ${now()}`, ...lines.slice(1)].join('\n'), { mode: 0o600 });
        hit = true;
      }
    }
  } catch {}
  console.log(hit ? `${verdict} sign-in ${code}` : `no pending sign-in with code ${code}`);
  process.exit(hit ? 0 : 1);
}

const esc = (t) => String(t).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function loginPage(res, title, body, refresh, script) {
  const nonce = rand(12);
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Frame-Options': 'DENY', 'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': `default-src 'none'; style-src 'unsafe-inline'; connect-src 'self'; script-src 'nonce-${nonce}'` });
  res.end(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
    (refresh ? `<meta http-equiv="refresh" content="2">` : '') +
    `<title>${esc(title)}</title><style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:32rem;margin:12vh auto;padding:0 1.25rem;color:#1b1f2a;background:#f5f6f8}` +
    `h1{font-size:1.3rem}code,.code{font:600 1.6rem ui-monospace,Menlo,monospace;letter-spacing:.08em}.muted{color:#5a6070;font-size:.9rem}</style>` +
    `<h1>${esc(title)}</h1>${body}` + (script ? `<script nonce="${nonce}">${script}</script>` : ''));
}

// Browser side of both ceremonies: tiny, no libraries, sends only what the server verifies.
const WEBAUTHN_JS = `
const d=(s)=>Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
const e=(b)=>btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
const say=(t)=>{document.getElementById('msg').textContent=t};
async function post(u,b){const r=await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});return [r.ok,await r.text()];}`;

// ---- HTTP server ----------------------------------------------------------------------------

function readBody(req, limit) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > limit) req.destroy(); });
    req.on('end', () => resolve(body));
    req.on('error', () => resolve(''));
  });
}
function parseForm(body, type) {
  if (/json/.test(type || '')) { try { return JSON.parse(body); } catch { return {}; } }
  return Object.fromEntries(new URLSearchParams(body));
}
function json(res, code, obj, extra) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...(extra || {}) });
  res.end(JSON.stringify(obj));
}

function serveHttp(port) {
  CHANNEL = 'claude-app';
  // The pre-OAuth URL token is revoked on startup: delete it so nothing can serve it again.
  try { fs.unlinkSync(TOKEN_FILE); log('revoked the legacy path token (http-token deleted)'); } catch {}

  const server = http.createServer((req, res) => {
    route(req, res).catch((e) => {
      log(`request failed: ${req.method} ${String(req.url).split('?')[0]}: ${e.message}`);
      if (!res.headersSent) { res.writeHead(500, { 'Content-Type': 'text/plain' }); res.end('internal error'); }
    });
  });
  async function route(req, res) {
    const u = new URL(req.url, 'http://x');
    const p = u.pathname;
    // One line per request (path only, never query strings or headers: they can carry codes/tokens).
    res.on('finish', () => log(`${req.method} ${p} → ${res.statusCode} (host ${req.headers.host || '-'})`));
    const base = baseUrl(req);
    if (!base) { res.writeHead(421); return res.end('misdirected request'); }
    const resource = `${base}/mcp`;
    if (base.startsWith('https://') && publicUrl() !== base) { try { fs.writeFileSync(PUBLIC_URL_FILE, base + '\n', { mode: 0o600 }); } catch {} }

    // -- authenticator-app enrollment: same one-time link, /totp/enroll/<token> --------------
    const te = p.match(/^\/totp\/enroll\/([A-Za-z0-9_-]{20,40})$/);
    if (te) {
      if (!enrollTokenValid(te[1], false)) return loginPage(res, 'Link expired', '<p>Enrollment links work once, for 10 minutes. Make a new one from the onboarding page or with <code>--enroll-totp</code>.</p>');
      const pend = enrollChallenges.get('totp:' + sha(te[1])) || { secret: base32(crypto.randomBytes(20)), exp: now() + ENROLL_TTL_S, tries: 0 };
      enrollChallenges.set('totp:' + sha(te[1]), pend);
      const host = new URL(base).hostname;
      const uri = `otpauth://totp/shipmate:${encodeURIComponent(host.split('.')[0])}?secret=${pend.secret}&issuer=shipmate&algorithm=SHA1&digits=6&period=30`;
      const show = (msg) => loginPage(res, 'Add shipmate to your authenticator app',
        `<p>Scan this with Microsoft Authenticator (or any authenticator app): <b>+</b> → <b>Other account</b> → scan.</p>` +
        `<div style="background:#fff;display:inline-block;padding:.5rem">${qrSvg(uri)}</div>` +
        `<p class="muted">Can't scan? Choose "enter code manually" with account <b>shipmate</b> and key<br><code style="font-size:.95rem;word-break:break-all">${esc(pend.secret.replace(/(.{4})/g, '$1 ').trim())}</code></p>` +
        `<form method="post"><p><label>Then type the 6-digit code it shows<br><input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]{6,7}" maxlength="7" style="font:600 1.4rem ui-monospace,Menlo,monospace;width:8ch" autofocus required></label></p>` +
        `<p><button style="font-size:1.05rem;padding:.5rem 1rem">Confirm</button></p></form>` + (msg ? `<p><b>${esc(msg)}</b></p>` : ''));
      if (req.method === 'GET') return show('');
      if (req.method === 'POST') {
        const f = parseForm(await readBody(req, 4096), req.headers['content-type']);
        if (++pend.tries > 5) { enrollChallenges.delete('totp:' + sha(te[1])); enrollTokenValid(te[1], true);
          audit('totp_enroll_refused', { why: 'too many wrong codes' }); return loginPage(res, 'Too many wrong codes', '<p>Make a new enrollment link and start over.</p>'); }
        const st = totpMatch(pend.secret, f.code, 0);
        if (st < 0) { audit('totp_enroll_refused', { why: 'wrong code' }); return show("That code didn't match. Check the phone's clock is automatic, then try the current code."); }
        writeJson(TOTP_FILE, { secret: pend.secret, confirmed: true, created: now(), lastStep: st });
        enrollTokenValid(te[1], true); enrollChallenges.delete('totp:' + sha(te[1]));
        audit('totp_enrolled', {});
        return loginPage(res, 'Authenticator added', '<p>Sign-ins to shipmate now ask for a code from your authenticator app (or your passkey, if you have one).</p>');
      }
      res.writeHead(405); return res.end();
    }

    // -- passkey enrollment: one-time link from the tailnet page or the host -------------------
    const en = p.match(/^\/passkey\/enroll\/([A-Za-z0-9_-]{20,40})$/);
    if (en) {
      if (!enrollTokenValid(en[1], false)) return loginPage(res, 'Link expired', '<p>Enrollment links work once, for 10 minutes. Make a new one from the onboarding page or with <code>--enroll-passkey</code>.</p>');
      if (req.method === 'GET') {
        const challenge = rand(32);
        enrollChallenges.set(sha(en[1]), { challenge, exp: now() + ENROLL_TTL_S });
        const exclude = loadPasskeys().map((k) => ({ type: 'public-key', id: k.id }));
        const opts = { challenge, rp: { id: new URL(base).hostname, name: 'shipmate' },
          user: { id: rand(16), name: 'owner', displayName: 'shipmate owner' },
          pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
          authenticatorSelection: { residentKey: 'preferred', userVerification: 'required' },
          attestation: 'none', timeout: 120000, excludeCredentials: exclude };
        return loginPage(res, 'Add a passkey to shipmate',
          `<p>This makes a passkey for signing in to shipmate. Your device will ask for Face ID, Touch ID or its passcode.</p>` +
          `<p><label>Name it <input id="nm" value="iPhone" maxlength="60"></label></p>` +
          `<p><button id="go" style="font-size:1.05rem;padding:.6rem 1.1rem">Create passkey</button></p><p id="msg" class="muted"></p>`,
          false, `${WEBAUTHN_JS}
const o=${JSON.stringify(opts)};
document.getElementById('go').onclick=async()=>{try{
  const pk={...o,challenge:d(o.challenge),user:{...o.user,id:d(o.user.id)},excludeCredentials:o.excludeCredentials.map(x=>({...x,id:d(x.id)}))};
  const c=await navigator.credentials.create({publicKey:pk});const r=c.response;
  if(!r.getPublicKey){say('This browser is too old for passkeys here — update it and try again.');return;}
  const [ok,t]=await post(location.pathname,{id:e(c.rawId),clientDataJSON:e(r.clientDataJSON),authenticatorData:e(r.getAuthenticatorData()),publicKey:e(r.getPublicKey()),alg:r.getPublicKeyAlgorithm(),name:document.getElementById('nm').value});
  say(ok?'Done. Sign-ins to shipmate now use this passkey.':'Refused: '+t);if(ok)document.getElementById('go').disabled=true;
}catch(x){say('Cancelled or failed: '+x.message)}};`);
      }
      if (req.method === 'POST') {
        const ch = enrollChallenges.get(sha(en[1]));
        const body = parseForm(await readBody(req, 65536), 'json');
        try {
          if (!ch || ch.exp < now()) throw new Error('no enrollment in progress — reload the page');
          const k = passkeyRegister(body, ch.challenge, base);
          enrollTokenValid(en[1], true); enrollChallenges.delete(sha(en[1]));
          audit('passkey_enrolled', { passkey: k.id.slice(0, 8), name: k.name, alg: k.alg });
          res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('ok');
        } catch (err) {
          audit('passkey_enroll_refused', { why: err.message });
          res.writeHead(400, { 'Content-Type': 'text/plain' }); return res.end(err.message);
        }
      }
      res.writeHead(405); return res.end();
    }

    // -- discovery ---------------------------------------------------------------------
    if (req.method === 'GET' && (p === '/.well-known/oauth-protected-resource' || p === '/.well-known/oauth-protected-resource/mcp')) {
      return json(res, 200, { resource, authorization_servers: [base], scopes_supported: SCOPES,
        bearer_methods_supported: ['header'], resource_name: 'shipmate' });
    }
    if (req.method === 'GET' && (p === '/.well-known/oauth-authorization-server' || p === '/.well-known/openid-configuration')) {
      return json(res, 200, {
        issuer: base, authorization_endpoint: `${base}/authorize`, token_endpoint: `${base}/token`,
        registration_endpoint: `${base}/register`, revocation_endpoint: `${base}/revoke`,
        response_types_supported: ['code'], grant_types_supported: ['authorization_code', 'refresh_token'],
        code_challenge_methods_supported: ['S256'], token_endpoint_auth_methods_supported: ['none'],
        scopes_supported: SCOPES,
      });
    }

    // -- dynamic client registration (RFC 7591), public clients only --------------------
    if (p === '/register' && req.method === 'POST') {
      const m = parseForm(await readBody(req, 16384), 'json');
      const uris = Array.isArray(m.redirect_uris) ? m.redirect_uris : [];
      if (!uris.length || !uris.every(redirectAllowed)) {
        audit('register_refused', { redirect_uris: uris.slice(0, 3) });
        return json(res, 400, { error: 'invalid_redirect_uri', error_description: 'redirect_uris must be Claude connector callbacks or loopback' });
      }
      const db = oauthLoad();
      const ids = Object.keys(db.clients);
      if (ids.length >= 50) { // evict the oldest client that holds no live tokens
        const live = new Set([...Object.values(db.access), ...Object.values(db.refresh)].map((t) => t.client_id));
        const victim = ids.filter((i) => !live.has(i)).sort((a, b) => db.clients[a].created - db.clients[b].created)[0];
        if (!victim) return json(res, 400, { error: 'invalid_client_metadata', error_description: 'too many clients' });
        delete db.clients[victim];
      }
      const id = rand(16);
      const name = String(m.client_name || 'MCP client').slice(0, 80);
      db.clients[id] = { redirect_uris: uris, name, created: now() };
      oauthSave(db); audit('register', { client: id.slice(0, 8), name });
      return json(res, 201, { client_id: id, client_id_issued_at: now(), client_name: name, redirect_uris: uris,
        token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'] });
    }

    // -- authorization: owner approves on a tailnet device -------------------------------
    if (p === '/authorize' && req.method === 'GET') {
      const q = Object.fromEntries(u.searchParams);
      const db = oauthLoad();
      const client = db.clients[q.client_id];
      // Never redirect to an unverified URI: these errors render here instead.
      if (!client) return loginPage(res, 'Unknown client', '<p>This app is not registered with shipmate.</p>');
      if (!client.redirect_uris.includes(q.redirect_uri)) return loginPage(res, 'Bad redirect', '<p>That callback is not registered for this app.</p>');
      const back = (err) => {
        const r = new URL(q.redirect_uri); r.searchParams.set('error', err); if (q.state) r.searchParams.set('state', q.state);
        res.writeHead(302, { Location: r.toString() }); res.end();
      };
      if (q.response_type !== 'code') return back('unsupported_response_type');
      if (!q.code_challenge || q.code_challenge_method !== 'S256') return back('invalid_request');
      if (q.resource && q.resource !== resource) return back('invalid_target');
      const scope = (q.scope ? q.scope.split(/\s+/) : SCOPES).filter((s) => SCOPES.includes(s));
      if (!scope.length) return back('invalid_scope');
      const t = now();
      while (loginRate.length && loginRate[0] < t - 3600) loginRate.shift();
      const pending = [...logins.values()].filter((l) => l.exp > t).length;
      if (pending >= 3 || loginRate.length >= 10) return back('temporarily_unavailable');
      loginRate.push(t);
      const access = scope.includes('shipmate:execute') ? 'full access (can ship)' : 'read-only';
      const usePasskey = loadPasskeys().length > 0, useTotp = totpEnrolled();
      const { nonce, userCode, pushed } = requestLoginApproval(`Sign in "${client.name}" to shipmate — ${access}`, !usePasskey && !useTotp);
      const pollId = rand(18);
      logins.set(pollId, { nonce, userCode, exp: t + LOGIN_TTL_S, q: { ...q, scope: scope.join(' ') },
        passkey: usePasskey, totp: useTotp, totpTries: 0, challenge: rand(32), access });
      audit('authorize_requested', { client: q.client_id.slice(0, 8), name: client.name, scope: scope.join(' '), pushed, passkey: usePasskey, totp: useTotp });
      res.writeHead(302, { Location: `/authorize/wait/${pollId}` }); return res.end();
    }
    const tp = p.match(/^\/authorize\/totp\/([A-Za-z0-9_-]{16,40})$/);
    if (tp && req.method === 'POST') {
      const l = logins.get(tp[1]), f = parseForm(await readBody(req, 4096), req.headers['content-type']);
      const waitUrl = `/authorize/wait/${tp[1]}`;
      if (!l || l.exp < now() || !l.totp) return loginPage(res, 'Sign-in expired', '<p>Start again from Claude.</p>');
      if (++l.totpTries > 5) {
        logins.delete(tp[1]); audit('totp_signin_refused', { why: 'too many wrong codes', client: l.q.client_id.slice(0, 8) });
        return loginPage(res, 'Too many wrong codes', '<p>This sign-in is cancelled. Start again from Claude.</p>');
      }
      const t = loadTotp(), st = t && t.confirmed ? totpMatch(t.secret, f.code, t.lastStep) : -1;
      if (st < 0) {
        audit('totp_signin_refused', { why: 'wrong or reused code', client: l.q.client_id.slice(0, 8) });
        res.writeHead(303, { Location: waitUrl + '?e=1' }); return res.end();
      }
      t.lastStep = st; writeJson(TOTP_FILE, t); // that code (and every earlier one) is now spent
      const file = path.join(APPROVALS, l.nonce), lines = fs.readFileSync(file, 'utf8').split('\n');
      fs.writeFileSync(file, [`approved ${now()}`, ...lines.slice(1)].join('\n'), { mode: 0o600 });
      audit('totp_signin', { client: l.q.client_id.slice(0, 8) });
      res.writeHead(303, { Location: waitUrl }); return res.end();
    }
    const pk = p.match(/^\/authorize\/passkey\/([A-Za-z0-9_-]{16,40})$/);
    if (pk && req.method === 'POST') {
      const l = logins.get(pk[1]);
      const body = parseForm(await readBody(req, 65536), 'json');
      try {
        if (!l || l.exp < now() || !l.passkey) throw new Error('no sign-in waiting — start again from Claude');
        if (!l.challenge) throw new Error('challenge already used');
        const challenge = l.challenge; l.challenge = null; // one assertion per challenge, pass or fail
        const k = passkeyAssert(body, challenge, base);
        const file = path.join(APPROVALS, l.nonce);
        const lines = fs.readFileSync(file, 'utf8').split('\n');
        fs.writeFileSync(file, [`approved ${now()}`, ...lines.slice(1)].join('\n'), { mode: 0o600 });
        audit('passkey_signin', { passkey: k.id.slice(0, 8), name: k.name, client: l.q.client_id.slice(0, 8) });
        res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('ok');
      } catch (err) {
        if (l && l.passkey) l.challenge = rand(32); // a fresh one for the next try (page reload fetches it)
        audit('passkey_signin_refused', { why: err.message });
        res.writeHead(400, { 'Content-Type': 'text/plain' }); return res.end(err.message);
      }
    }
    const wait = p.match(/^\/authorize\/wait\/([A-Za-z0-9_-]{16,40})$/);
    if (wait && req.method === 'GET') {
      const l = logins.get(wait[1]);
      if (!l || l.exp < now()) { logins.delete(wait[1]); return loginPage(res, 'Sign-in expired', '<p>Start again from Claude.</p>'); }
      const v = loginVerdict(l.nonce);
      const totpForm = l.totp
        ? `<form method="post" action="${esc(p.replace('/wait/', '/totp/'))}"><p><label>${l.passkey ? 'Or enter' : 'Enter'} the 6-digit code from your authenticator app<br>` +
          `<input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]{6,7}" maxlength="7" style="font:600 1.4rem ui-monospace,Menlo,monospace;width:8ch" ${l.passkey ? '' : 'autofocus'} required></label></p>` +
          `<p><button style="font-size:1.05rem;padding:.5rem 1rem">Sign in</button></p></form>` + (u.searchParams.get('e') ? `<p><b>That code didn't work. Try the current one.</b></p>` : '')
        : '';
      if (v === 'pending' && l.totp && !l.passkey) {
        return loginPage(res, 'Sign in to shipmate',
          `<p><b>${esc((oauthLoad().clients[l.q.client_id] || {}).name || 'An app')}</b> is asking for ${esc(l.access)}.</p>` + totpForm +
          `<p class="muted">Lost your phone? On the Mac that runs shipmate: <code style="font-size:.85rem">node mcp/shipmate-mcp.js --approve-login ${esc(l.userCode)}</code></p>`);
      }
      if (v === 'pending' && l.passkey) {
        return loginPage(res, 'Sign in to shipmate',
          `<p><b>${esc(l.q.client_id && (oauthLoad().clients[l.q.client_id] || {}).name || 'An app')}</b> is asking for ${esc(l.access)}.</p>` +
          `<p><button id="go" style="font-size:1.05rem;padding:.6rem 1.1rem">Sign in with passkey</button></p><p id="msg" class="muted"></p>` + totpForm +
          `<p class="muted">Lost your passkey? On the Mac that runs shipmate: <code style="font-size:.85rem">node mcp/shipmate-mcp.js --approve-login ${esc(l.userCode)}</code></p>`,
          false, `${WEBAUTHN_JS}
const o=${JSON.stringify({ challenge: l.challenge, rpId: new URL(base).hostname, allow: loadPasskeys().map((k) => k.id) })};
async function go(){try{
  const c=await navigator.credentials.get({publicKey:{challenge:d(o.challenge),rpId:o.rpId,userVerification:'required',timeout:120000,
    allowCredentials:o.allow.map(id=>({type:'public-key',id:d(id)}))}});const r=c.response;
  const [ok,t]=await post(location.pathname.replace('/wait/','/passkey/'),{id:e(c.rawId),clientDataJSON:e(r.clientDataJSON),authenticatorData:e(r.authenticatorData),signature:e(r.signature)});
  if(ok)location.reload();else say('Refused: '+t);
}catch(x){say('Cancelled or failed: '+x.message)}}
document.getElementById('go').onclick=go;`);
      }
      if (v === 'pending') {
        return loginPage(res, 'Approve on your phone',
          `<p>shipmate sent an <b>Approve</b> button to your phone. It only works from a device on your tailnet.</p>` +
          `<p>Check the code matches:</p><p class="code">${esc(l.userCode)}</p>` +
          `<p class="muted">No phone? On the Mac that runs shipmate: <code style="font-size:.85rem">node mcp/shipmate-mcp.js --approve-login ${esc(l.userCode)}</code></p>`, true);
      }
      logins.delete(wait[1]);
      try { fs.unlinkSync(path.join(APPROVALS, l.nonce)); } catch {}
      const r = new URL(l.q.redirect_uri);
      if (v === 'approved') {
        const code = rand(32), db = oauthLoad();
        db.codes[sha(code)] = { client_id: l.q.client_id, redirect_uri: l.q.redirect_uri, challenge: l.q.code_challenge,
          scope: l.q.scope, resource, exp: now() + CODE_TTL_S };
        oauthSave(db); audit('authorize_approved', { client: l.q.client_id.slice(0, 8), scope: l.q.scope });
        r.searchParams.set('code', code);
      } else {
        audit('authorize_denied', { client: l.q.client_id.slice(0, 8), verdict: v });
        r.searchParams.set('error', 'access_denied');
      }
      if (l.q.state) r.searchParams.set('state', l.q.state);
      res.writeHead(302, { Location: r.toString() }); return res.end();
    }

    // -- token endpoint --------------------------------------------------------------------
    if (p === '/token' && req.method === 'POST') {
      const f = parseForm(await readBody(req, 16384), req.headers['content-type']);
      const db = oauthLoad();
      const bad = (error, why) => { audit('token_refused', { grant: f.grant_type, why }); return json(res, 400, { error, error_description: why }); };
      if (f.grant_type === 'authorization_code') {
        const h = sha(f.code || ''), c = db.codes[h];
        if (!c) return bad('invalid_grant', 'unknown, used or expired code');
        delete db.codes[h]; oauthSave(db); // single use, even when the rest fails
        if (c.client_id !== f.client_id) return bad('invalid_grant', 'client mismatch');
        if (c.redirect_uri !== f.redirect_uri) return bad('invalid_grant', 'redirect_uri mismatch');
        if (!f.code_verifier || b64url(crypto.createHash('sha256').update(f.code_verifier).digest()) !== c.challenge)
          return bad('invalid_grant', 'PKCE verification failed');
        if (f.resource && f.resource !== c.resource) return bad('invalid_target', 'resource mismatch');
        const out = issueTokens(db, c.client_id, c.scope, c.resource);
        oauthSave(db); audit('token_issued', { client: c.client_id.slice(0, 8), scope: c.scope });
        return json(res, 200, out);
      }
      if (f.grant_type === 'refresh_token') {
        const h = sha(f.refresh_token || '');
        if (db.spent[h]) { // a rotated refresh token came back: assume theft, kill the whole family
          revokeFamily(db, db.spent[h].fam); oauthSave(db);
          audit('refresh_reuse_revoked', { fam: db.spent[h].fam });
          return bad('invalid_grant', 'refresh token reuse — all tokens from this sign-in revoked');
        }
        const r = db.refresh[h];
        if (!r) return bad('invalid_grant', 'unknown or expired refresh token');
        if (r.client_id !== f.client_id) return bad('invalid_grant', 'client mismatch');
        delete db.refresh[h];
        db.spent[h] = { fam: r.fam, exp: r.exp };
        const out = issueTokens(db, r.client_id, r.scope, r.resource, r.fam);
        oauthSave(db); audit('token_refreshed', { client: r.client_id.slice(0, 8) });
        return json(res, 200, out);
      }
      return bad('unsupported_grant_type', String(f.grant_type || 'missing'));
    }
    if (p === '/revoke' && req.method === 'POST') {
      const f = parseForm(await readBody(req, 16384), req.headers['content-type']);
      const db = oauthLoad(), h = sha(f.token || '');
      const t = db.access[h] || db.refresh[h];
      if (t) { revokeFamily(db, t.fam); oauthSave(db); audit('revoked', { client: t.client_id.slice(0, 8) }); }
      res.writeHead(200); return res.end();
    }

    // -- the MCP endpoint ------------------------------------------------------------------
    if (p !== '/mcp') { res.writeHead(404); return res.end(); }
    const challenge = (err) => `Bearer realm="shipmate", resource_metadata="${base}/.well-known/oauth-protected-resource"` +
      (err ? `, error="${err}"` : '');
    const m = String(req.headers.authorization || '').match(/^Bearer\s+([A-Za-z0-9_-]{20,})$/);
    if (!m) { res.writeHead(401, { 'WWW-Authenticate': challenge() }); return res.end(); }
    const tok = oauthLoad().access[sha(m[1])];
    if (!tok || tok.resource !== resource) {
      audit('mcp_refused', { why: tok ? 'wrong audience' : 'invalid or expired token' });
      res.writeHead(401, { 'WWW-Authenticate': challenge('invalid_token') }); return res.end();
    }
    if (req.method === 'GET') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
    if (req.method === 'DELETE') { res.writeHead(200); return res.end(); } // stateless
    if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
    const ctx = { scopes: tok.scope.split(' '), client: tok.client_id.slice(0, 8) };

    const body = await readBody(req, 1e6);
    let msg;
    try { msg = JSON.parse(body); }
    catch { return json(res, 400, { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); }
    const msgs = Array.isArray(msg) ? msg : [msg];
    const replies = (await Promise.all(msgs.map((x) =>
      handle(x, ctx).catch((e) => ({ jsonrpc: '2.0', id: x.id, error: { code: -32603, message: e.message } }))
    ))).filter(Boolean);
    if (!replies.length) { res.writeHead(202); return res.end(); }
    json(res, 200, Array.isArray(msg) ? replies : replies[0]);
  }
  server.listen(port, '127.0.0.1', () => {
    log(`serving Streamable HTTP + OAuth on http://127.0.0.1:${port}/mcp`);
    log('publish with:  tailscale funnel --bg ' + port);
  });
}

// ---- onboarding UI (tailnet-only) ---------------------------------------------------------

function tailscaleCmd(args) {
  return new Promise((resolve) => {
    const bins = ['tailscale', '/Applications/Tailscale.app/Contents/MacOS/Tailscale'];
    const attempt = (i) => {
      if (i >= bins.length) return resolve('');
      execFile(bins[i], args, { timeout: 10000 }, (err, stdout) =>
        err ? attempt(i + 1) : resolve((stdout || '').trim()));
    };
    attempt(0);
  });
}

function readNtfyTopic() {
  try {
    const env = fs.readFileSync(path.join(os.homedir(), '.shipmate', 'voice.env'), 'utf8');
    const m = env.match(/SHIPMATE_NTFY_TOPIC=([^\s'"]+)/);
    return m ? m[1] : '';
  } catch { return ''; }
}

function repoUrl() {
  return new Promise((resolve) => {
    execFile('git', ['-C', path.join(__dirname, '..'), 'remote', 'get-url', 'origin'],
      { timeout: 10000 }, (err, stdout) => resolve(err ? '' : (stdout || '').trim()));
  });
}

const SSH_KEY_RE = /^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$/;

function addAuthorizedKey(raw) {
  const key = String(raw || '').trim();
  if (!SSH_KEY_RE.test(key))
    return { ok: false, message: 'That does not look like an SSH public key (expected e.g. "ssh-ed25519 AAAA…").' };
  const file = process.env.SHIPMATE_AUTHORIZED_KEYS
    || path.join(os.homedir(), '.ssh', 'authorized_keys');
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  let existing = '';
  try { existing = fs.readFileSync(file, 'utf8'); } catch {}
  const keyBody = key.split(' ').slice(0, 2).join(' ');
  if (existing.split('\n').some((l) => l.trim().startsWith(keyBody)))
    return { ok: true, message: 'That key is already authorized — you are good to go.' };
  fs.appendFileSync(file, (existing && !existing.endsWith('\n') ? '\n' : '') + key + '\n', { mode: 0o600 });
  try { fs.chmodSync(file, 0o600); } catch {}
  return { ok: true, message: 'Key added. Run the Shortcut — the Mac trusts this device now.' };
}

// The Tailscale IP straight from the interfaces (100.64.0.0/10) — no CLI, which the GUI
// app's binary refuses to be under launchd.
function tailscaleIP() {
  const ifs = os.networkInterfaces();
  for (const name of Object.keys(ifs)) {
    for (const a of ifs[name] || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      const o = a.address.split('.').map(Number);
      if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) return a.address;
    }
  }
  return '';
}

async function serveOnboard(port) {
  // At boot, launchd may start us before Tailscale is up — wait for it rather than die.
  let ip = '';
  for (let i = 0; i < 24; i++) {
    ip = tailscaleIP();
    if (ip) break;
    if (i === 0) log('waiting for a Tailscale IPv4 address…');
    await new Promise((r) => setTimeout(r, 5000));
  }
  if (!ip) {
    log('no Tailscale IPv4 address after 2 minutes — refusing to serve onboarding anywhere else.');
    process.exit(1);
  }
  // Nice-to-have only: the MagicDNS name via the CLI, falling back to the IP.
  let tailnetName = ip;
  try {
    const dns = JSON.parse(await tailscaleCmd(['status', '--json']) || '{}');
    tailnetName = ((dns.Self || {}).DNSName || '').replace(/\.$/, '') || ip;
  } catch {}
  const html = fs.readFileSync(path.join(__dirname, 'onboard.html'));
  const info = {
    user: os.userInfo().username,
    tailnetName,
    bridgePath: '~/' + path.relative(os.homedir(), BRIDGE),
    ntfyTopic: readNtfyTopic(),
    repoUrl: await repoUrl(),
  };

  const APPROVALS = process.env.SHIPMATE_APPROVALS_DIR
    || path.join(os.homedir(), '.shipmate', 'approvals');
  const VOICE_STATE = process.env.SHIPMATE_VOICE_STATE
    || path.join(os.homedir(), '.shipmate', 'voice');
  const dashHtml = fs.readFileSync(path.join(__dirname, 'dashboard.html'));
  const deployCache = { ts: 0, entries: [] };

  const readFileSafe = (f) => { try { return fs.readFileSync(f, 'utf8'); } catch { return ''; } };
  const listDirs = (p) => { try { return fs.readdirSync(p).filter((n) => { try { return fs.statSync(path.join(p, n)).isDirectory(); } catch { return false; } }); } catch { return []; } };

  function dashboardData(cb) {
    const jobs = listDirs(path.join(VOICE_STATE, 'jobs')).map((id) => {
      const d = path.join(VOICE_STATE, 'jobs', id);
      return {
        id,
        project: path.basename(readFileSafe(path.join(d, 'project')).trim() || '?'),
        projectPath: readFileSafe(path.join(d, 'project')).trim(),
        status: readFileSafe(path.join(d, 'status')).trim() || 'unknown',
        task: readFileSafe(path.join(d, 'task')).trim().slice(0, 120),
        started: parseInt(readFileSafe(path.join(d, 'started')).trim(), 10) * 1000 || null,
      };
    }).sort((a, b) => Number(b.id) - Number(a.id));

    const approvals = [];
    for (const n of (() => { try { return fs.readdirSync(APPROVALS); } catch { return []; } })()) {
      const lines = readFileSafe(path.join(APPROVALS, n)).split('\n');
      if (lines[0] && lines[0].startsWith('pending'))
        approvals.push({ nonce: n, desc: (lines[1] || '').slice(0, 200) });
    }

    const queue = listDirs(path.join(VOICE_STATE, 'queue')).sort().map((id) => ({
      id,
      verb: readFileSafe(path.join(VOICE_STATE, 'queue', id, 'verb')).trim(),
      text: readFileSafe(path.join(VOICE_STATE, 'queue', id, 'text')).trim().slice(0, 120),
    }));

    const counsel = readFileSafe(path.join(VOICE_STATE, 'last-counsel.txt')).slice(-4000);
    const sessionProject = readFileSafe(path.join(VOICE_STATE, 'session.project')).trim();

    // Deploy phases via do-app.sh, cached — doctl on every 5s refresh would be rude.
    const projects = [...new Set([sessionProject, ...jobs.map((j) => j.projectPath)]
      .filter((p) => p && fs.existsSync(path.join(p, '.do', 'app.yaml'))))];
    if (Date.now() - deployCache.ts < 60000 || projects.length === 0) {
      return cb({ jobs, approvals, queue, counsel, deploys: deployCache.entries, generated: Date.now() });
    }
    const appsh = path.join(__dirname, '..', 'skills', 'deploy', 'bin', 'do-app.sh');
    let pending = projects.length;
    const entries = [];
    projects.forEach((p) => {
      execFile('bash', [appsh, 'status', p], { timeout: 20000 }, (err, stdout) => {
        if (!err && stdout) {
          const get = (k) => ((stdout.match(new RegExp('^' + k + ':\\s*(.*)$', 'm')) || [])[1] || '').trim();
          entries.push({ project: path.basename(p), url: get('url'), deploy: get('deploy') });
        }
        if (--pending === 0) {
          deployCache.ts = Date.now(); deployCache.entries = entries;
          cb({ jobs, approvals, queue, counsel, deploys: entries, generated: Date.now() });
        }
      });
    });
  }

  http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (req.method === 'GET' && (url === '/' || url === '/index.html')) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(html);
    }
    // Tailnet-only: being on this page is the authority to add a passkey to the public sign-in.
    if (req.method === 'GET' && (url === '/passkey' || url === '/totp')) {
      const pub = publicUrl();
      if (!pub) { res.writeHead(503, { 'Content-Type': 'text/plain' }); return res.end('Public URL unknown yet: start Funnel and open the connector once, or set SHIPMATE_PUBLIC_URL.'); }
      res.writeHead(302, { Location: `${pub}${url}/enroll/${mintEnrollToken()}` }); return res.end();
    }
    if (req.method === 'GET' && url === '/dashboard') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(dashHtml);
    }
    if (req.method === 'GET' && url === '/api/dashboard') {
      return dashboardData((data) => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(data));
      });
    }
    // Tap-to-confirm: ntfy action buttons land here. Tailnet-only by construction —
    // this server never binds anywhere else — so reading the notification is not
    // enough to approve; you must be one of the user's own devices.
    // The 🚀 Ship it button on a plan push. Same trust model as approve: tailnet-only server,
    // single-use grant, 10-minute TTL — a stale or forged tap does nothing.
    const sh = url.match(/^\/ship\/([a-f0-9]{16,64})$/);
    if (sh) {
      const done = (code, msg) => { res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8' }); res.end(msg); };
      if (req.method !== 'POST') return done(405, 'POST only');
      const g = readGrant();
      if (!g || g.nonce !== sh[1]) return done(404, 'no armed plan for that button (already shipped, or expired)');
      if (Date.now() - g.ts > PLAN_TTL_MS) return done(410, 'that plan expired — ask for it again');
      const child = spawn('bash', [BRIDGE, 'ship it'],
        { env: { ...process.env, SHIPMATE_FORCE_DETACH: '1', SHIPMATE_CHANNEL: 'ship-button' }, detached: true, stdio: 'ignore' });
      child.unref();
      log(`ship-it tap for ${g.project} (nonce ${sh[1].slice(0, 8)}…)`);
      return done(200, `🚀 Shipping ${g.project} — I'll ping you when it's live.`);
    }
    const ap = url.match(/^\/(approve|deny)\/([a-f0-9]{16,64})$/);
    if (ap) {
      const file = path.join(APPROVALS, ap[2]);
      let lines;
      try { lines = fs.readFileSync(file, 'utf8').split('\n'); }
      catch { res.writeHead(404); return res.end('unknown or expired approval'); }
      const done = (msg) => { res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' }); res.end(msg); };
      if (!lines[0].startsWith('pending')) return done(`already ${lines[0].split(' ')[0]}`);
      const verdict = ap[1] === 'approve' ? 'approved' : 'denied';
      fs.writeFileSync(file, [`${verdict} ${Date.now()}`, ...lines.slice(1)].join('\n'), { mode: 0o600 });
      log(`approval ${ap[2].slice(0, 8)}…: ${verdict} (${(lines[1] || '').slice(0, 80)})`);
      return done(verdict === 'approved'
        ? '✅ Approved — shipmate will proceed.'
        : '❌ Denied — shipmate will stop and report.');
    }
    if (req.method === 'GET' && url === '/api/info') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(info));
    }
    if (req.method === 'POST' && url === '/api/add-key') {
      let body = '';
      req.on('data', (c) => { body += c; if (body.length > 65536) req.destroy(); });
      req.on('end', () => {
        let out;
        try { out = addAuthorizedKey(JSON.parse(body).key); }
        catch (e) { out = { ok: false, message: 'Bad request: ' + e.message }; }
        res.writeHead(out.ok ? 200 : 400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(out));
      });
      return;
    }
    res.writeHead(404); res.end();
  }).listen(port, ip, () => {
    log(`onboarding UI on http://${tailnetName}:${port} (tailnet only — bound to ${ip})`);
  });
}

// ---- main --------------------------------------------------------------------------------

const argv = process.argv.slice(2);
if (argv[0] === '--approve-login') cliLoginDecision(argv[1], 'approved');
else if (argv[0] === '--deny-login') cliLoginDecision(argv[1], 'denied');
else if (argv[0] === '--enroll-passkey') {
  const pub = publicUrl();
  if (!pub) { console.log('Public URL unknown: set SHIPMATE_PUBLIC_URL or open the connector once through Funnel.'); process.exit(1); }
  const link = `${pub}/passkey/enroll/${mintEnrollToken()}`;
  try { if (process.env.SHIPMATE_NO_CLIPBOARD) throw new Error('print'); require('child_process').execFileSync('pbcopy', { input: link }); console.log('Enrollment link copied to the clipboard (one use, 10 minutes). Open it on the device that will hold the passkey.'); }
  catch { console.log(link); }
} else if (argv[0] === '--enroll-totp') {
  const pub = publicUrl();
  if (!pub) { console.log('Public URL unknown: set SHIPMATE_PUBLIC_URL or open the connector once through Funnel.'); process.exit(1); }
  const link = `${pub}/totp/enroll/${mintEnrollToken()}`;
  try { if (process.env.SHIPMATE_NO_CLIPBOARD) throw new Error('print'); require('child_process').execFileSync('pbcopy', { input: link }); console.log('Authenticator enrollment link copied to the clipboard (one use, 10 minutes). Open it on a screen your phone can scan.'); }
  catch { console.log(link); }
} else if (argv[0] === '--totp-status') {
  const t = loadTotp();
  console.log(t && t.confirmed ? `authenticator app enrolled ${new Date(t.created * 1000).toISOString().slice(0, 10)}` : 'no authenticator app enrolled');
} else if (argv[0] === '--remove-totp') {
  try { fs.unlinkSync(TOTP_FILE); audit('totp_removed', {}); console.log('authenticator app removed'); } catch { console.log('no authenticator app enrolled'); }
} else if (argv[0] === '--passkeys') {
  const list = loadPasskeys();
  console.log(list.length ? list.map((k) => `${k.id.slice(0, 10)}  ${k.name}  ${k.alg === -7 ? 'ES256' : 'RS256'}  added ${new Date(k.created * 1000).toISOString().slice(0, 10)}  last used ${k.lastUsed ? new Date(k.lastUsed * 1000).toISOString().slice(0, 10) : 'never'}`).join('\n') : 'no passkeys — sign-in uses the phone tap');
} else if (argv[0] === '--remove-passkey') {
  const list = loadPasskeys(), keep = list.filter((k) => !argv[1] || !k.id.startsWith(argv[1]));
  if (!argv[1] || keep.length === list.length) { console.log('usage: --remove-passkey <id prefix from --passkeys>'); process.exit(1); }
  savePasskeys(keep); audit('passkey_removed', { passkey: argv[1].slice(0, 8) }); console.log(`removed ${list.length - keep.length} passkey(s)`);
} else if (argv[0] === '--revoke-all') {
  const db = oauthLoad(); const n = Object.keys(db.access).length + Object.keys(db.refresh).length;
  db.access = {}; db.refresh = {}; db.codes = {}; oauthSave(db); audit('revoke_all', { tokens: n });
  console.log(`revoked ${n} token(s); every client must sign in again`);
} else if (argv[0] === '--grants') {
  const db = oauthLoad(); const t = now();
  const rows = Object.values(db.refresh).map((r) => `${(db.clients[r.client_id] || {}).name || '?'}  scope=${r.scope}  expires in ${Math.round((r.exp - t) / 86400)}d`);
  console.log(rows.length ? rows.join('\n') : 'no active sign-ins');
} else if (argv[0] === '--http') serveHttp(parseInt(argv[1], 10) || 8787);
else if (argv[0] === '--onboard') serveOnboard(parseInt(argv[1], 10) || 8790);
else serveStdio();
