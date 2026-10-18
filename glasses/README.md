# shipmate on Even Realities G2

Read-only shipmate status on G2 glasses: your fleet's production deploys, anything the sentinel
has open (a site down, a failed deploy, a certificate about to lapse — listed first, with how long),
any armed plan, and the gate's recent decisions, in plain words. Built on the Even Hub SDK (a web app that runs inside the
Even app on your phone; the glasses render it and send gestures back).

| Fleet | Plan | Gate |
|---|---|---|
| ![fleet](docs/fleet.png) | ![plan](docs/plan.png) | ![gate](docs/gate.png) |

*Captured from the official Even Hub simulator against the live shipmate server.*

**Gestures:** press and hold to ask (see Talk) · swipe up/down moves between Fleet, Brief (the morning briefing as short lines), Plan and Gate · tap refreshes · double-tap
jumps to the fleet. It refreshes itself every minute.

**It can't ship.** The glasses pair with a read-only token (`shipmate:read`). There is no
gesture that changes anything; shipping stays a deliberate act by voice, the Claude app, the
phone's Ship it button, or the terminal, all through the same gate. A reconstructed ledger entry
shows `hst` instead of a fresh age, because its timestamp is when it was written down.

## Talk

**Press and hold** the touchpad, speak, **let go**. The glasses' microphones record while you
hold (up to 30 s); the question goes to your shipmate host, becomes words there with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (on-device; the audio is deleted as soon as
it's transcribed and never leaves the host), and the answer comes back on the display. Swipe to
page a long answer; tap to go back to the glance. The phone page has a box to type a question too.

| Listening | Answer |
|---|---|
| ![listening](docs/listening.png) | ![answer](docs/talk.png) |

*Captured in the Even Hub simulator: the Mac's `say` voice was routed through a loopback audio
device into the simulated glasses microphone, then through the live server, whisper and the bridge.*

**Read-only, like everything here.** The glasses' token is `shipmate:read`, so a spoken question
gets what the read scope means everywhere else: *"good morning"*, *"status"*, *"where did we leave
off"*, *"what do you remember"*, *"deploy panogram"* (a plan, which still pushes the 🚀 Ship it
button to your phone). *"…ship it"*, *"remember …"*, *"work on …"* are refused in code, out loud,
and the refusal is written to the ledger (`scope refused`, channel `glasses`).

**Set up once on the host:** `brew install whisper-cpp`, then the English base model:

```sh
mkdir -p ~/.shipmate/whisper && curl -L -o ~/.shipmate/whisper/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
shasum -a 256 ~/.shipmate/whisper/ggml-base.en.bin
# a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002 (as published by the model repo)
```

`doctor` reports it. A warm transcription takes ~0.2 s on Apple Silicon. Overrides:
`SHIPMATE_WHISPER` (the binary), `SHIPMATE_WHISPER_MODEL`.

**Audio format.** The SDK doesn't document it; in the simulator the frames are 16 kHz, 16-bit mono
PCM, 100 ms (3,200 bytes) each. The app sends the bytes and how long you held, and the server
works the rate out from those (snapped to a real rate), so a different rate on the hardware still
transcribes. To verify on the G2s: the console logs `[shipmate] heard N bytes in M ms`.

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

`GET /glance` (bearer, `shipmate:read`), `POST /glance/ask` (the same token; JSON `{text}` or raw
PCM with `?ms=`; 30 questions per 10 minutes; 3 MB max) and `POST /device/pair` live in
`mcp/shipmate-mcp.js`;
CORS is open on those three and `/token` only, since they're bearer- or code-authenticated, never
cookie-authenticated. The feed's `alerts` (and each fleet entry's `alert`) are what
`skills/deploy/bin/sentinel.sh` has open. Tests: `tests/test_mcp_auth.sh` (pairing, throttling, read-only scope,
feed shape) and `glasses/test/view.test.ts` (rendering).
