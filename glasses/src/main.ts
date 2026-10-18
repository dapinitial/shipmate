// main.ts — wires the glance to the G2 through the Even Hub bridge.
// Glasses: swipe up/down moves between views, tap refreshes, double-tap jumps to the fleet.
// Talk: press and hold, speak, let go — the answer comes back on the display (swipe to page).
// Phone (this WebView page): one-time pairing with a code from shipmate's onboarding page.
// There is deliberately no way to change anything on shipmate from here: the token is read-only,
// the server runs spoken questions read-only (ask, brief, recall, plan), and shipping stays a
// deliberate act on the phone or by voice.
import {
  AudioInputSource, CreateStartUpPageContainer, OsEventTypeList, StartUpPageCreateResult, TextContainerProperty, TextContainerUpgrade, waitForEvenAppBridge,
  type EvenAppBridge, type EvenHubEvent,
} from '@evenrealities/even_hub_sdk';
import { ask, glance, pair, type Creds } from './api.ts';
import { answerPages, nextView, render, renderTalk, type Glance, type Talk, type View } from './view.ts';

const TEXT = { containerID: 1, containerName: 'glance' };
const REFRESH_MS = 60_000;
let bridge: EvenAppBridge | null = null;
let creds: Creds | null = null;
let view: View = 'fleet';
let last: Glance | null = null;
let error = '';
let talk: Talk | null = null;       // while talking, the display belongs to the conversation
let listening = false, listenStart = 0, listenTick: ReturnType<typeof setInterval> | null = null;
let frames: Uint8Array[] = [];
const LISTEN_MAX_S = 30;

// ---- storage: the bridge's when inside the Even app, the browser's otherwise ----------------
const store = {
  async get(k: string) { return bridge ? bridge.getLocalStorage(k) : localStorage.getItem(k) ?? ''; },
  async set(k: string, v: string) { if (bridge) await bridge.setLocalStorage(k, v); else localStorage.setItem(k, v); },
};
const saveCreds = (c: Creds | null) => store.set('shipmate.creds', c ? JSON.stringify(c) : '');

// ---- drawing ---------------------------------------------------------------------------------
async function draw() {
  const text = talk ? renderTalk(talk) : render(last, view, new Date(), error);
  (document.getElementById('preview') as HTMLElement).textContent = text; // the phone shows the same
  if (bridge) await bridge.textContainerUpgrade(new TextContainerUpgrade({ ...TEXT, content: text }));
}

async function refresh() {
  if (!creds) { error = 'not paired — open the app on your phone'; return draw(); }
  try {
    const out = await glance(creds);
    last = out.glance; error = '';
    if (out.creds !== creds) { creds = out.creds; await saveCreds(creds); }
  } catch (e) {
    error = (e as Error).message;
    if (/pair again/.test(error)) { creds = null; await saveCreds(null); showPairing(true); }
  }
  await draw();
}

// ---- talking: hold to speak, let go to ask --------------------------------------------------
async function startListening() {
  if (!bridge || !creds || listening) return;
  frames = []; listening = true; listenStart = Date.now();
  talk = { state: 'listening', seconds: 0 }; await draw();
  if (!(await bridge.audioControl(true, AudioInputSource.Glasses))) {
    listening = false; talk = { state: 'error', message: "the glasses' microphone didn't open" }; return void draw();
  }
  listenTick = setInterval(() => {
    const s = Math.floor((Date.now() - listenStart) / 1000);
    if (s >= LISTEN_MAX_S) return void stopListening();
    talk = { state: 'listening', seconds: s }; void draw();
  }, 1000);
}

async function stopListening() {
  if (!listening) return;
  listening = false;
  if (listenTick) clearInterval(listenTick);
  await bridge?.audioControl(false);
  const ms = Date.now() - listenStart;
  const pcm = new Uint8Array(frames.reduce((n, f) => n + f.length, 0));
  let o = 0; for (const f of frames) { pcm.set(f, o); o += f.length; }
  console.log(`[shipmate] heard ${pcm.length} bytes in ${ms} ms over ${frames.length} frames`);
  frames = [];
  await askAndShow({ pcm, ms });
}

async function askAndShow(q: { text: string } | { pcm: Uint8Array; ms: number }) {
  if (!creds) return;
  talk = { state: 'thinking', ...('text' in q ? { heard: q.text } : {}) }; await draw();
  try {
    const out = await ask(creds, q);
    if (out.creds !== creds) { creds = out.creds; await saveCreds(creds); }
    talk = { state: 'answer', heard: out.answer.heard, answer: out.answer.answer, page: 0 };
  } catch (e) { talk = { state: 'error', message: (e as Error).message }; }
  await draw();
}

function onTalkEvent(t: number | undefined): boolean { // true when the conversation took the event
  if (!talk || talk.state === 'listening' || talk.state === 'thinking') return !!talk;
  if (t === OsEventTypeList.SCROLL_BOTTOM_EVENT && talk.state === 'answer' && talk.page + 1 < answerPages(talk.answer)) {
    talk = { ...talk, page: talk.page + 1 }; void draw(); return true;
  }
  if (t === OsEventTypeList.SCROLL_TOP_EVENT && talk.state === 'answer' && talk.page > 0) {
    talk = { ...talk, page: talk.page - 1 }; void draw(); return true;
  }
  // a tap, a double-tap, or swiping past the end goes back to the glance
  talk = null; if (t === OsEventTypeList.DOUBLE_CLICK_EVENT) view = 'fleet';
  void refresh(); return true;
}

function onEvent(ev: EvenHubEvent) {
  if (ev.audioEvent) { if (listening) frames.push(new Uint8Array(ev.audioEvent.audioPcm)); return; }
  const t = ev.textEvent?.eventType ?? ev.sysEvent?.eventType;
  if (!ev.textEvent && !ev.sysEvent) return;
  if (t === OsEventTypeList.LONG_PRESS_EVENT) return void startListening();
  if (t === OsEventTypeList.LONG_PRESS_RELEASE_EVENT) return void stopListening();
  if (onTalkEvent(t)) return;
  switch (t) {
    case OsEventTypeList.SCROLL_BOTTOM_EVENT: view = nextView(view, 1); return void draw();
    case OsEventTypeList.SCROLL_TOP_EVENT: view = nextView(view, -1); return void draw();
    case OsEventTypeList.DOUBLE_CLICK_EVENT: view = 'fleet'; return void refresh();
    case OsEventTypeList.CLICK_EVENT:
    case undefined: return void refresh(); // a tap is event 0, which payloads often omit
    case OsEventTypeList.FOREGROUND_ENTER_EVENT: return void refresh();
  }
}

// ---- phone-side pairing ------------------------------------------------------------------------
function showPairing(on: boolean) {
  (document.getElementById('pair') as HTMLElement).hidden = !on;
  (document.getElementById('paired') as HTMLElement).hidden = on;
}
(document.getElementById('pair-form') as HTMLFormElement).addEventListener('submit', async (e) => {
  e.preventDefault();
  const msg = document.getElementById('pair-msg') as HTMLElement;
  const server = (document.getElementById('server') as HTMLInputElement).value.trim();
  const code = (document.getElementById('code') as HTMLInputElement).value.trim();
  msg.textContent = 'Pairing…';
  try {
    creds = await pair(server, code);
    await saveCreds(creds);
    msg.textContent = ''; showPairing(false); await refresh();
  } catch (err) { msg.textContent = (err as Error).message; }
});
(document.getElementById('ask-form') as HTMLFormElement).addEventListener('submit', async (e) => {
  e.preventDefault();
  const box = document.getElementById('ask-text') as HTMLInputElement;
  const text = box.value.trim(); if (!text) return;
  box.value = ''; await askAndShow({ text });
});
(document.getElementById('unpair') as HTMLButtonElement).addEventListener('click', async () => {
  creds = null; last = null; await saveCreds(null); showPairing(true); await draw();
});

// ---- boot ----------------------------------------------------------------------------------
async function boot() {
  (document.getElementById('server') as HTMLInputElement).value = import.meta.env.VITE_SHIPMATE_URL ?? '';
  try {
    bridge = await Promise.race([waitForEvenAppBridge(), new Promise<null>((r) => setTimeout(() => r(null), 3000))]);
  } catch { bridge = null; }
  if (bridge) {
    const ok = await bridge.createStartUpPageContainer(new CreateStartUpPageContainer({
      containerTotalNum: 1,
      textObject: [new TextContainerProperty({ ...TEXT, xPosition: 0, yPosition: 0, width: 576, height: 288,
        paddingLength: 8, isEventCapture: 1, content: render(null, view), textColor: 4 })],
    }));
    if (ok !== StartUpPageCreateResult.success) console.warn('glasses page not created:', ok);
    bridge.onEvenHubEvent(onEvent);
  }
  const saved = await store.get('shipmate.creds');
  creds = saved ? (JSON.parse(saved) as Creds) : null;
  // A pairing link (#pair=CODE&server=URL, e.g. from a QR code) fills the form and pairs once.
  const link = new URLSearchParams(location.hash.slice(1));
  if (link.get('pair')) {
    (document.getElementById('code') as HTMLInputElement).value = link.get('pair') ?? '';
    if (link.get('server')) (document.getElementById('server') as HTMLInputElement).value = link.get('server') ?? '';
    history.replaceState(null, '', location.pathname); // the code is single-use; don't keep it around
    showPairing(true);
    (document.getElementById('pair-form') as HTMLFormElement).requestSubmit();
    return void setInterval(refresh, REFRESH_MS);
  }
  showPairing(!creds);
  await refresh();
  setInterval(refresh, REFRESH_MS);
}
boot();
