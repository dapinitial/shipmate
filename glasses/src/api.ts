// api.ts — the only network code. Pairing trades a one-time code for a READ-ONLY token; the glance
// is fetched with it and refreshed on 401. Nothing here can change anything on shipmate.
import type { Glance } from './view.ts';

export interface Creds { server: string; clientId: string; access: string; refresh: string }

export async function pair(server: string, code: string): Promise<Creds> {
  const base = new URL(server).origin;
  const r = await fetch(`${base}/device/pair`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ code }).toString(),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error_description || `pairing failed (${r.status})`);
  return { server: base, clientId: j.client_id, access: j.access_token, refresh: j.refresh_token };
}

async function refresh(c: Creds): Promise<Creds> {
  const r = await fetch(`${c.server}/token`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', client_id: c.clientId, refresh_token: c.refresh }).toString(),
  });
  if (!r.ok) throw new Error('signed out — pair again');
  const j = await r.json();
  return { ...c, access: j.access_token, refresh: j.refresh_token };
}

// Returns the glance and, when tokens rotated, the new credentials to store.
export async function glance(c: Creds): Promise<{ glance: Glance; creds: Creds }> {
  const get = (tok: string) => fetch(`${c.server}/glance`, { headers: { Authorization: `Bearer ${tok}` } });
  let r = await get(c.access), creds = c;
  if (r.status === 401) { creds = await refresh(c); r = await get(creds.access); }
  if (!r.ok) throw new Error(`shipmate answered ${r.status}`);
  return { glance: await r.json(), creds };
}
