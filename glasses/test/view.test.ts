// Node's built-in test runner (types are stripped natively). The view is the whole display
// contract, so every line it can emit is checked against the G2's limits.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LINE_CHARS, MAX_LINES, ago, answerPages, nextView, render, renderTalk, says, wrap, type Glance } from '../src/view.ts';

const now = new Date('2026-10-14T12:00:00Z');
const g = (over: Partial<Glance> = {}): Glance => ({
  generated: now.toISOString(),
  fleet: [
    { name: 'unakin', provider: 'do', phase: 'LIVE' },
    { name: 'rillet-case-study', provider: 'vercel', phase: 'LIVE' },
    { name: 'panogram', provider: 'do', phase: 'BUILDING' },
  ],
  plan: null, events: [], ...over,
});
const fits = (s: string) => {
  const lines = s.split('\n');
  assert.ok(lines.length <= MAX_LINES, `too many lines: ${lines.length}`);
  for (const l of lines) assert.ok([...l].length <= LINE_CHARS, `line too long: "${l}"`);
};

test('fleet: summary, problems first, fits', () => {
  const out = render(g(), 'fleet', now);
  assert.match(out, /^SHIPMATE · FLEET 3\n1 deploying\n\.\. panogram/);
  fits(out);
  const failed = render(g({ fleet: [...g().fleet, { name: 'sedulous', provider: 'do', phase: 'FAILED' }] }), 'fleet', now);
  assert.match(failed, /\n1 FAILED\n!! sedulous/);
});

test('fleet: sentinel alerts lead, with how long', () => {
  const out = render(g({
    fleet: [...g().fleet, { name: 'unakin-portal', provider: 'do', phase: 'LIVE', alert: 'down', since: '2026-10-14T11:40:00Z' }],
    alerts: [{ project: 'unakin-portal', what: 'down', since: '2026-10-14T11:40:00Z' }, { project: 'ghost', what: 'cert 9d', since: '2026-10-13T12:00:00Z' }],
  }), 'fleet', now);
  const lines = out.split('\n');
  assert.equal(lines[1], '2 NEED YOU');
  assert.equal(lines[2], '!! ghost cert 9d 24h');       // not in the fleet (status timed out): still shown
  assert.equal(lines[3], '!! unakin-portal down 20m');
  assert.equal(lines[4], '.. panogram');
  fits(out);
  assert.match(render(g({ alerts: [{ project: 'unakin', what: 'deploy failed', since: now.toISOString() }] }), 'fleet', now), /\n1 NEEDS YOU\n!! unakin deploy failed now/);
});

test('fleet: all live', () => {
  assert.match(render(g({ fleet: [{ name: 'a', provider: 'do', phase: 'LIVE' }] }), 'fleet', now), /all live\nok a/);
});

test('fleet: overflow collapses to "+N more" and still fits', () => {
  const many = Array.from({ length: 12 }, (_, i) => ({ name: `app-${i}`, provider: 'do', phase: 'LIVE' }));
  const out = render(g({ fleet: many }), 'fleet', now);
  fits(out);
  assert.match(out, /\+\d+ more$/);
  const shown = out.split('\n').filter((l) => l.startsWith('ok ')).length;
  assert.equal(shown + Number(out.match(/\+(\d+) more/)![1]), 12);
});

test('long names are clipped, never overflow', () => {
  const out = render(g({ fleet: [{ name: 'an-extraordinarily-long-project-name-indeed', provider: 'do', phase: 'LIVE' }] }), 'fleet', now);
  fits(out); assert.match(out, /…/);
});

test('plan view: armed and empty, and it never offers to ship', () => {
  const armed = render(g({ plan: { project: 'rillet-case-study', minutesLeft: 8 } }), 'plan', now);
  assert.match(armed, /rillet-case-study\narmed · 8 min left/);
  assert.match(armed, /ship from phone or voice/);
  fits(armed);
  assert.match(render(g(), 'plan', now), /nothing armed/);
});

test('gate view: plain words, ages, newest first as given', () => {
  const out = render(g({ events: [
    { ts: '2026-10-14T11:59:30Z', policy: 'verify-live', outcome: 'live', project: 'rillet', detail: '' },
    { ts: '2026-10-14T11:40:00Z', policy: 'pre-push:remote', outcome: 'refused', project: 'unakin', detail: '' },
    { ts: '2026-10-13T08:00:00Z', policy: 'plan-grant', outcome: 'downgraded', project: 'portfolio', detail: '' },
  ] }), 'events', now);
  assert.equal(out.split('\n')[1], 'now rillet live');
  assert.equal(out.split('\n')[2], '20m unakin push blocked');
  assert.equal(out.split('\n')[3], '28h portfolio planned first');
  fits(out);
});

test('reconstructed history is labeled, never given a fresh age', () => {
  const out = render(g({ events: [{ ts: '2026-10-14T11:59:00Z', policy: 'verify-live', outcome: 'failed', project: 'unakin', detail: 'Reconstructed …', reconstructed: true }] }), 'events', now);
  assert.equal(out.split('\n')[1], 'hst unakin NOT live');
});

test('says: unknown policies fall back to their raw words', () => {
  assert.equal(says({ ts: '', policy: 'scope', outcome: 'refused', project: '', detail: '' }), 'blocked (read-only)');
  assert.equal(says({ ts: '', policy: 'new-thing', outcome: 'odd', project: '', detail: '' }), 'new-thing odd');
});

test('error and loading states fit', () => {
  const err = render(null, 'fleet', now, 'shipmate answered 503 because the host is asleep and offline');
  fits(err); assert.match(err, /OFFLINE[\s\S]*tap to retry/);
  fits(render(null, 'events', now));
});

test('ago buckets', () => {
  assert.equal(ago('2026-10-14T11:59:00Z', now), 'now');
  assert.equal(ago('2026-10-14T11:00:00Z', now), '60m');
  assert.equal(ago('2026-10-14T06:00:00Z', now), '6h');
  assert.equal(ago('2026-10-10T12:00:00Z', now), '4d');
});

test('brief view: the window in the header, then the lines, and it fits', () => {
  const out = render(g({ brief: ['since yday 7:30 AM', '!! unakin down 2h', 'shipped rillet, unakin x2', ...Array(12).fill('job 9 an-extraordinarily-long-project-name-indeed done')] }), 'brief', now);
  const lines = out.split('\n');
  assert.equal(lines[0], 'SHIPMATE · BRIEF since yday 7:30 AM');
  assert.equal(lines[1], '!! unakin down 2h');
  fits(out);
  assert.match(render(g({ brief: ['since 7:30 AM'] }), 'brief', now), /nothing to report/);
  assert.match(render(g(), 'brief', now), /no briefing yet/);
});

test('views cycle both ways', () => {
  assert.equal(nextView('fleet', 1), 'brief');
  assert.equal(nextView('brief', 1), 'plan');
  assert.equal(nextView('events', 1), 'fleet');
  assert.equal(nextView('fleet', -1), 'events');
});

test('wrap: words to the line width, long words cut', () => {
  assert.deepEqual(wrap('the quick brown fox', 9), ['the quick', 'brown fox']);
  assert.deepEqual(wrap('a\n\nb', 9), ['a', 'b']);
  assert.equal(wrap('x'.repeat(60))[0].length, LINE_CHARS);
});

test('talking: listening, thinking, errors, and paged answers all fit', () => {
  fits(renderTalk({ state: 'listening', seconds: 3 }));
  assert.match(renderTalk({ state: 'listening', seconds: 3 }), /LISTENING[\s\S]*3s/);
  fits(renderTalk({ state: 'thinking', heard: 'what did i miss '.repeat(10) }));
  fits(renderTalk({ state: 'error', message: 'Speech isn\'t set up on the host: brew install whisper-cpp, then put ggml-base.en.bin in ~/.shipmate/whisper (see glasses/README.md).' }));
  const answer = 'Since yesterday at 9 PM: '.padEnd(60, '.') + ' ' + Array.from({ length: 40 }, (_, i) => `word${i}`).join(' ');
  const pages = answerPages(answer);
  assert.ok(pages > 1);
  const first = renderTalk({ state: 'answer', heard: 'good morning', answer, page: 0 });
  assert.match(first, new RegExp(`^SHIPMATE · ANSWER 1/${pages}\n> good morning\n`));
  fits(first);
  const last = renderTalk({ state: 'answer', heard: 'good morning', answer, page: 99 }); // clamped
  assert.match(last, new RegExp(`ANSWER ${pages}/${pages}`));
  fits(last);
  assert.match(renderTalk({ state: 'answer', heard: 'status', answer: 'All quiet.', page: 0 }), /^SHIPMATE · ANSWER\n> status\nAll quiet\.$/);
});
