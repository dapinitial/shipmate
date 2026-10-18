# shipmate on Even Realities G2

Read-only shipmate status on G2 glasses: your fleet's production deploys, anything the sentinel
has open (a site down, a failed deploy, a certificate about to lapse — listed first, with how long),
any armed plan, and the gate's recent decisions, in plain words. Built on the Even Hub SDK (a web app that runs inside the
Even app on your phone; the glasses render it and send gestures back).

| Fleet | Plan | Gate |
|---|---|---|
| ![fleet](docs/fleet.png) | ![plan](docs/plan.png) | ![gate](docs/gate.png) |

*Captured from the official Even Hub simulator against the live shipmate server.*

**Gestures:** swipe up/down moves between Fleet, Brief (the morning briefing as short lines), Plan and Gate · tap refreshes · double-tap
jumps to the fleet. It refreshes itself every minute.

**It can't ship.** The glasses pair with a read-only token (`shipmate:read`). There is no
gesture that changes anything; shipping stays a deliberate act by voice, the Claude app, the
phone's Ship it button, or the terminal, all through the same gate. A reconstructed ledger entry
shows `hst` instead of a fresh age, because its timestamp is when it was written down.

## Pair

1. On your phone (Tailscale on), open shipmate's onboarding page → **Pair your glasses**, or on the
   Mac run `node mcp/shipmate-mcp.js --pair-device "G2"`. You get an 8-character code: one use,
   10 minutes.
2. Open shipmate in the Even app, enter your shipmate server address and the code, tap **Pair**.

Unpair from the app, or sign the glasses out on the Mac: `--grants`, then `--revoke-client <id>`.

## Develop

```bash
cd glasses
npm install
npm test                                   # the display contract: every view fits 576×288
VITE_SHIPMATE_URL=https://<host>.ts.net npm run dev -- --port 5174
npx evenhub-simulator http://localhost:5174/ --automation-port 9898
```

The simulator can't type, so a pairing link fills the form: open
`http://localhost:5174/#pair=ABCD-EFGH&server=https://<host>.ts.net` (the code is cleared from
the URL after use). The automation port gives screenshots of the glasses and touchpad input:
`curl -X POST -d '{"action":"down"}' localhost:9898/api/input`, `curl localhost:9898/api/screenshot/glasses`.

## Ship to the glasses

`npm run pack` writes `app.json` and builds `shipmate-glance.ehpk`. Even Hub only lets an app talk
to origins it declares, so the manifest's network whitelist is derived from `SHIPMATE_URL` (or the
address the shipmate server recorded); repack when shipmate moves hosts. Sideload with the
`evenhub` CLI's QR code, or upload the `.ehpk` in the Even Hub developer portal.

## Server side

`GET /glance` (bearer, `shipmate:read`) and `POST /device/pair` live in `mcp/shipmate-mcp.js`;
CORS is open on those two and `/token` only, since they're bearer- or code-authenticated, never
cookie-authenticated. The feed's `alerts` (and each fleet entry's `alert`) are what
`skills/deploy/bin/sentinel.sh` has open. Tests: `tests/test_mcp_auth.sh` (pairing, throttling, read-only scope,
feed shape) and `glasses/test/view.test.ts` (rendering).
