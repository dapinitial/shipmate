// Writes app.json for the Even Hub packager. The network whitelist must name shipmate's exact
// public origin (Even Hub blocks every other host), so it is derived, never hardcoded:
// SHIPMATE_URL, else the origin the shipmate server recorded (~/.shipmate/mcp/public-url).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
let url = process.env.SHIPMATE_URL;
if (!url) {
  try { url = fs.readFileSync(path.join(os.homedir(), '.shipmate', 'mcp', 'public-url'), 'utf8').trim(); } catch {}
}
if (!url) { console.error('✗ set SHIPMATE_URL (e.g. https://your-mac.your-tailnet.ts.net)'); process.exit(1); }
const origin = new URL(url).origin;
const manifest = {
  package_id: 'dev.shipmate.glance',
  edition: '202601',
  name: 'shipmate',
  version: JSON.parse(fs.readFileSync('package.json', 'utf8')).version,
  min_app_version: '2.2.10',
  min_sdk_version: '0.0.16',
  entrypoint: 'index.html',
  permissions: [{ name: 'network', desc: 'Reads your shipmate server: deploy status, armed plans and recent gate decisions. Read-only.', whitelist: [origin] }],
  supported_languages: ['en'],
};
fs.writeFileSync('app.json', JSON.stringify(manifest, null, 2) + '\n');
console.log(`✓ app.json — network whitelist: ${origin}`);
