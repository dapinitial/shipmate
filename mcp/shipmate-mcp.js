#!/usr/bin/env node
/*
 * shipmate-mcp — a zero-dependency MCP server over the shipmate engine.
 *
 * Transports:
 *   stdio (default)         claude mcp add --scope user shipmate -- node .../mcp/shipmate-mcp.js
 *   Streamable HTTP         node .../mcp/shipmate-mcp.js --http [port]     (default 8787)
 *     Binds 127.0.0.1 ONLY. Publish with Tailscale Funnel; the endpoint path embeds a long
 *     random token (~/.shipmate/mcp/http-token, minted on first run):  POST /mcp/<token>
 *     Anything else is 404. See mcp/README.md for the funnel + claude.ai connector steps.
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

const { execFile } = require('child_process');
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

function bridge(args) {
  return new Promise((resolve) => {
    execFile('bash', [BRIDGE, ...args],
      { timeout: TURN_TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024 },
      (err, stdout, stderr) => {
        // The bridge speaks errors on stdout by design; prefer its words over exit codes.
        const text = (stdout || '').trim() || (stderr || '').trim()
          || (err ? `shipmate bridge failed: ${err.message}` : '');
        resolve({ text, isError: !!err && !(stdout || '').trim() });
      });
  });
}

// ---- two-phase gate ------------------------------------------------------------------

function grantPlan(project) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(PLAN_GRANT, JSON.stringify({ project, ts: Date.now() }), { mode: 0o600 });
}

function takeGrant(project) { // valid + same project → consume it (single use); else reason string
  let g;
  try { g = JSON.parse(fs.readFileSync(PLAN_GRANT, 'utf8')); }
  catch { return 'No plan exists. Call shipmate_plan first — execute is only unlocked by a fresh plan.'; }
  if (Date.now() - g.ts > PLAN_TTL_MS)
    return 'The last plan is older than 10 minutes. Call shipmate_plan again to see (and unlock) what would happen.';
  if ((g.project || '-') !== (project || '-'))
    return `The last plan was for project "${g.project}", not "${project}". Plan this project first.`;
  try { fs.unlinkSync(PLAN_GRANT); } catch {}
  return null;
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
    description: 'Execute the previously planned request. Refuses unless shipmate_plan ran for ' +
      'the same project within the last 10 minutes (single-use grant). Cost-neutral steps ' +
      'proceed; new spend, resizes, and deletions still stop and describe themselves.',
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
    case 'shipmate_plan': {
      const r = await bridge(['--turn', 'plan', proj, a.request]);
      if (!r.isError) grantPlan(a.project || '-');
      return wrap(r);
    }
    case 'shipmate_execute': {
      const refusal = takeGrant(a.project || '-');
      if (refusal) return wrap({ text: refusal, isError: true });
      return wrap(await bridge(['--turn', 'execute', proj, a.request]));
    }
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

// ---- JSON-RPC core (transport-independent) ---------------------------------------------

// Returns the response object for a request, or null for a notification.
async function handle(msg) {
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
      try { return reply(await callTool(params.name, params.arguments)); }
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

// ---- Streamable HTTP transport ------------------------------------------------------------

function httpToken() {
  try {
    const t = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
    if (t.length >= 32) return t;
  } catch {}
  const t = crypto.randomBytes(24).toString('hex');
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(TOKEN_FILE, t + '\n', { mode: 0o600 });
  return t;
}

function serveHttp(port) {
  const token = httpToken();
  const endpoint = `/mcp/${token}`;
  const server = http.createServer((req, res) => {
    // Constant-ish path check; everything but the token path is a plain 404.
    if (req.url.split('?')[0] !== endpoint) { res.writeHead(404); return res.end(); }
    if (req.method === 'GET') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
    if (req.method === 'DELETE') { res.writeHead(200); return res.end(); } // stateless: nothing to tear down
    if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }

    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
    req.on('end', async () => {
      let msg;
      try { msg = JSON.parse(body); }
      catch {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }));
      }
      const msgs = Array.isArray(msg) ? msg : [msg];
      const replies = (await Promise.all(msgs.map((m) =>
        handle(m).catch((e) => ({ jsonrpc: '2.0', id: m.id, error: { code: -32603, message: e.message } }))
      ))).filter(Boolean);
      if (!replies.length) { res.writeHead(202); return res.end(); } // notifications only
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(Array.isArray(msg) ? replies : replies[0]));
    });
  });
  server.listen(port, '127.0.0.1', () => {
    log(`serving Streamable HTTP on http://127.0.0.1:${port}${endpoint}`);
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
if (argv[0] === '--http') serveHttp(parseInt(argv[1], 10) || 8787);
else if (argv[0] === '--onboard') serveOnboard(parseInt(argv[1], 10) || 8790);
else serveStdio();
