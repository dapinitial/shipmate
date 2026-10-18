// api.ts — the only network code. Pairing trades a one-time code for a READ-ONLY token; the glance
// is fetched with it and refreshed on 401, and a question (spoken or typed) is asked with it.
// The server runs questions read-only, so nothing here can change anything on shipmate.
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

export interface Answer { heard: string; answer: string }

// Ask with words (typed on the phone) or with what the glasses' microphones heard: 16-bit mono
// PCM plus how long it lasted, from which the server works out the sample rate.
export async function ask(c: Creds, q: { text: string } | { pcm: Uint8Array; ms: number }): Promise<{ answer: Answer; creds: Creds }> {
  const send = (tok: string) => 'text' in q
    ? fetch(`${c.server}/glance/ask`, { method: 'POST', headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ text: q.text }) })
    : fetch(`${c.server}/glance/ask?ms=${Math.round(q.ms)}`, { method: 'POST', headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/octet-stream' }, body: new Blob([q.pcm as BlobPart]) });
  let r = await send(c.access), creds = c;
  if (r.status === 401) { creds = await refresh(c); r = await send(creds.access); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || `shipmate answered ${r.status}`);
  return { answer: j as Answer, creds };
}
