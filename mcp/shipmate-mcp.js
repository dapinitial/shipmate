#!/usr/bin/env node
/*
 * shipmate-mcp — a zero-dependency MCP server (stdio, JSON-RPC 2.0) over the shipmate engine.
 *
 * Any MCP client (Claude Code, the Claude apps via a connector, …) gets these tools:
 *   shipmate_plan      — describe what a request would do + cost. Read-only, always safe.
 *   shipmate_execute   — act. STRUCTURALLY gated: only works within 10 minutes of a
 *                        shipmate_plan for the same project, and the grant is single-use.
 *                        A client cannot execute what was never planned.
 *   shipmate_status    — running/finished background jobs.
 *   shipmate_task_start / shipmate_task_result / shipmate_task_stop — background agent jobs
 *                        (branch-only, never deploy/bill — the bridge enforces the rules).
 *
 * It shells out to voice/shipmate-voice.sh's machine interface, so voice and MCP are two
 * mouths on one tested engine. Register for local use:
 *   claude mcp add --scope user shipmate -- node ~/Sites/shipmate/mcp/shipmate-mcp.js
 */
'use strict';

const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');

const BRIDGE = path.join(__dirname, '..', 'voice', 'shipmate-voice.sh');
const STATE_DIR = path.join(os.homedir(), '.shipmate', 'mcp');
const PLAN_GRANT = path.join(STATE_DIR, 'plan-grant.json');
const PLAN_TTL_MS = 10 * 60 * 1000;
const TURN_TIMEOUT_MS = 10 * 60 * 1000;

const log = (...a) => console.error('[shipmate-mcp]', ...a);

function bridge(args, cb) {
  execFile('bash', [BRIDGE, ...args],
    { timeout: TURN_TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024 },
    (err, stdout, stderr) => {
      // The bridge speaks errors on stdout by design; prefer its words over exit codes.
      const text = (stdout || '').trim() || (stderr || '').trim()
        || (err ? `shipmate bridge failed: ${err.message}` : '');
      cb(err && !stdout ? err : null, text);
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
];

function callTool(name, args, respond) {
  const a = args || {};
  const proj = a.project || '-';
  const text = (t, isError) => respond({ content: [{ type: 'text', text: t }], ...(isError ? { isError: true } : {}) });

  switch (name) {
    case 'shipmate_plan':
      return bridge(['--turn', 'plan', proj, a.request], (err, out) => {
        if (!err) grantPlan(a.project || '-');
        text(out, !!err);
      });
    case 'shipmate_execute': {
      const refusal = takeGrant(a.project || '-');
      if (refusal) return text(refusal, true);
      return bridge(['--turn', 'execute', proj, a.request], (err, out) => text(out, !!err));
    }
    case 'shipmate_status':
      return bridge(['--status-report'], (err, out) => text(out, !!err));
    case 'shipmate_task_start':
      return bridge(['--dispatch', proj, a.task], (err, out) => text(out, !!err));
    case 'shipmate_task_result':
      return bridge(['--result', ...(a.job_id != null ? [String(a.job_id)] : [])], (err, out) => text(out, !!err));
    case 'shipmate_task_stop':
      return bridge(['--stop', ...(a.job_id != null ? [String(a.job_id)] : [])], (err, out) => text(out, !!err));
    default:
      return respond(null, { code: -32602, message: `unknown tool: ${name}` });
  }
}

// ---- JSON-RPC over stdio ---------------------------------------------------------------

const out = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

function handle(msg) {
  const { id, method, params } = msg;
  const reply = (result) => id !== undefined && out({ jsonrpc: '2.0', id, result });
  const fail = (error) => id !== undefined && out({ jsonrpc: '2.0', id, error });

  switch (method) {
    case 'initialize':
      return reply({
        protocolVersion: (params && params.protocolVersion) || '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'shipmate', version: '0.1.0' },
      });
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return; // notifications get no response
    case 'ping':
      return reply({});
    case 'tools/list':
      return reply({ tools: TOOLS });
    case 'tools/call':
      return callTool(params.name, params.arguments, (result, error) =>
        error ? fail(error) : reply(result));
    default:
      return fail({ code: -32601, message: `method not found: ${method}` });
  }
}

readline.createInterface({ input: process.stdin, terminal: false }).on('line', (line) => {
  line = line.trim();
  if (!line) return;
  let msg;
  try { msg = JSON.parse(line); }
  catch { return out({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); }
  try { handle(msg); }
  catch (e) {
    log('handler error:', e.message);
    if (msg.id !== undefined) out({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: e.message } });
  }
});

log(`serving shipmate tools over stdio (bridge: ${BRIDGE})`);
