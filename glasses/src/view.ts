// view.ts — turn a shipmate glance into the text the G2 shows. Pure: no SDK, no network, so it
// is tested in Node and behaves the same in the simulator and on the glasses.
//
// The display is 576×288, monochrome green. One full-screen text container; LINE_CHARS and
// MAX_LINES keep every view inside it. Views: fleet → plan → recent decisions (swipe to move).

export type Phase = 'LIVE' | 'SUPERSEDED' | 'BUILDING' | 'PENDING' | 'FAILED' | 'UNKNOWN' | string;
export interface Glance {
  generated: string;
  fleet: { name: string; provider: string; phase: Phase }[];
  plan: { project: string; minutesLeft: number } | null;
  events: { ts: string; policy: string; outcome: string; project: string; detail: string; reconstructed?: boolean }[];
}

export const LINE_CHARS = 44; // the G2 font is proportional: ~55 narrow chars fit; 44 leaves room for wide ones
export const MAX_LINES = 10; // ~27 px per line in 288 px
export const VIEWS = ['fleet', 'plan', 'events'] as const;
export type View = (typeof VIEWS)[number];

const clip = (s: string, n = LINE_CHARS) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const mark = (p: Phase) => ({ LIVE: 'ok', SUPERSEDED: 'ok', BUILDING: '..', PENDING: '..', FAILED: '!!' } as Record<string, string>)[p] ?? '??';

export function ago(iso: string, now: Date): string {
  const s = Math.max(0, Math.round((now.getTime() - new Date(iso).getTime()) / 1000));
  if (s < 90) return 'now';
  if (s < 5400) return `${Math.round(s / 60)}m`;
  if (s < 129600) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
}

// Plain words for what a gate did; the glasses never show raw policy codes.
export function says(e: Glance['events'][number]): string {
  const k = `${e.policy}:${e.outcome}`;
  const words: Record<string, string> = {
    'ship:executed': 'shipped', 'verify-live:live': 'live', 'verify-live:failed': 'NOT live',
    'verify-live:warned': 'live, check it', 'plan-grant:downgraded': 'planned first', 'preflight:refused': 'preflight stop',
    'approval:approved': 'spend approved', 'approval:denied': 'spend denied', 'approval:timeout': 'spend not approved',
    'scope:refused': 'blocked (read-only)', 'rollback:executed': 'rolled back', 'roll-forward:executed': 'rolled forward',
    'pre-push:override:overridden': 'guard overridden', 'phrase-parser:downgraded': 'garbled, planned',
    'none:missed': 'missed (no gate yet)', 'rollback:failed': 'rollback FAILED', 'roll-forward:failed': 'roll-forward FAILED',
  };
  if (words[k]) return words[k];
  if (e.policy.startsWith('pre-push:')) return 'push blocked';
  return `${e.policy} ${e.outcome}`;
}

export function render(g: Glance | null, view: View, now = new Date(), error = ''): string {
  const head = (t: string) => `SHIPMATE · ${t}`;
  if (error) return [head('OFFLINE'), '', clip(error), '', 'tap to retry'].join('\n');
  if (!g) return [head('…'), '', 'loading'].join('\n');
  const lines: string[] = [];
  if (view === 'fleet') {
    const bad = g.fleet.filter((a) => a.phase === 'FAILED').length;
    const busy = g.fleet.filter((a) => a.phase === 'BUILDING' || a.phase === 'PENDING').length;
    lines.push(head(`FLEET ${g.fleet.length}`));
    lines.push(bad ? `${bad} FAILED` : busy ? `${busy} deploying` : 'all live');
    const order = (a: Glance['fleet'][number]) => (a.phase === 'FAILED' ? 0 : a.phase === 'BUILDING' || a.phase === 'PENDING' ? 1 : 2);
    const shown = [...g.fleet].sort((a, b) => order(a) - order(b) || a.name.localeCompare(b.name));
    const room = MAX_LINES - lines.length;
    for (const a of shown.slice(0, shown.length > room ? room - 1 : room)) lines.push(clip(`${mark(a.phase)} ${a.name}`));
    if (shown.length > room) lines.push(`+${shown.length - (room - 1)} more`);
  } else if (view === 'plan') {
    lines.push(head('PLAN'));
    if (g.plan) {
      lines.push('', clip(g.plan.project), `armed · ${g.plan.minutesLeft} min left`, '', 'ship from phone or voice');
    } else {
      lines.push('', 'nothing armed');
    }
  } else {
    lines.push(head('GATE'));
    if (!g.events.length) lines.push('', 'no decisions yet');
    // A reconstructed entry's timestamp is when it was written down, not when it happened.
    for (const e of g.events.slice(0, MAX_LINES - 1)) lines.push(clip(`${e.reconstructed ? 'hst' : ago(e.ts, now).padStart(3)} ${e.project} ${says(e)}`));
  }
  return lines.slice(0, MAX_LINES).map((l) => clip(l)).join('\n');
}

export const nextView = (v: View, step: 1 | -1): View => VIEWS[(VIEWS.indexOf(v) + step + VIEWS.length) % VIEWS.length];
