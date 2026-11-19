# shipmate — the fleet view (case study brief)

For "Portals, admin and security, across every domain" on davidpuerto.com. Written from the code,
config and local logs on 2026-11-19. Planned work is marked **PLANNED**; a figure not in the repo
or a local log is "not measured". No live production data, secrets, tailnet hostnames or
customer details are used here.

## 1. What it is, and who uses it

shipmate is the deploy and ops layer across my sites: it ships them, refuses risky pushes,
watches them in production and tells me what happened. One user, me, by terminal, Siri, the
Claude app and Even G2 glasses. Crew, clients, testers and the public never touch it; they only
feel it when a site stays up.

## 2. Stack, and why

- **Bash 3.2 + python3 helpers, no framework.** It runs on any Mac as shipped, and the logic that
  decides what may ship stays small enough to test line by line.
- **Node MCP server with no dependencies** (`mcp/shipmate-mcp.js`). The Claude app connects to it
  as a custom connector. No packages means nothing to update or compromise underneath the gate.
- **Hosts it deploys to:** DigitalOcean App Platform (~$5/month a site, commercial use allowed)
  and Vercel (free Hobby for non-commercial work), behind one set of verbs, so every gate works
  the same on both.
- **Where it runs:** my laptop, reachable over Tailscale; the Claude-app endpoint is published
  through Tailscale Funnel. An always-on iMac host is **PLANNED**.
- **Database:** none. Append-only JSON-lines files in `~/.shipmate` (ledger, sentinel log, memory,
  timings), `0600`. Every record is greppable and nothing can be edited in place.
- **Auth:** OAuth 2.1 with PKCE for the Claude app (1-hour access tokens, rotating 30-day
  refresh tokens with reuse detection, stored only as hashes), signed in with a **passkey**, an
  **authenticator code** (TOTP) or a tap from my own device. Two scopes: `read` and `execute`. Glasses pair with a one-time
  8-character code and get `read` only. Siri comes in over SSH with a per-device key. Spacelab Lock
  is not used here.
- **Notifications:** ntfy (free, no account).
- **Speech:** whisper.cpp on the host, so audio from the glasses never leaves the Mac.

## 3. Admin and portal screens

- **Sign-in page** (`/authorize`): a passkey or authenticator code, or an Approve / Deny tap
  that only a device on my tailnet can press. Along with the MCP endpoint itself, it's the only
  thing reachable from the internet.
- **Onboarding page** (tailnet only, port 8790): per-device setup for an iPhone (the Siri
  Shortcut, adding its SSH key), a laptop, or a new host Mac, plus glasses pairing codes.
- **Mission control** (`/dashboard`, tailnet only): live background jobs, production deploy
  phases, the dead-zone queue, the last counsel transcript, and **pending spend approvals with
  Approve / Deny** buttons.
- **The Ship-it button**: a push notification on a plan, with a tailnet-only button that executes
  that one plan.
- **Glasses** (Even G2, read-only): Fleet (deploy phase per site, open problems first), Brief (the
  7:30 lines), Plan (an armed plan), Gate (the last five ledger decisions), and Talk
  (press and hold, ask, read the answer).

## 4. Analytics

shipmate records nothing about visitors: no pages, clicks, devices, browsers, locales, countries,
referrers, bots, funnels or sell-through. Those belong to each site, so here they are **not
measured**. What it does record, all on the host:

| Record | What | Kept |
|---|---|---|
| `ledger.jsonl` | every gate decision (refused, overridden, executed, live or not), with project, channel and counts; my notes added by hand | forever, append-only |
| `sentinel.jsonl` | when a problem opened and cleared, per site and check | forever, append-only |
| `sentinel/.timings.jsonl` | each site check's time to first byte and full load | 8 days |
| `heard.jsonl` | what I said and what it answered, any channel | newest 500 exchanges |
| `memory.jsonl` | facts, reminders and names I asked it to keep | until I say forget or done |

From those logs: **115 gate decisions** from 2026-10-14 to today, including **61 push-guard
overrides**. 52 are judged by hand and 9 since 20 October are not yet. Also **85 sentinel
transitions** since 2026-10-19.

It never records: secrets or `.env` values, audio (deleted after transcription), the query
string of a spoken question, or any page content beyond whether `expect_text` was found.

## 5. Failure watching

The sentinel runs every 5 minutes from a launchd timer. Each problem is announced once, after it's
confirmed, and its recovery once, by push and in the briefing. It only reads; a fix it suggests is
a phrase for the usual gate (*"roll back unakin, confirm"*).

**What it watches today.** Every git repo under `~/Sites` with a deploy target; a git worktree of
one of them is skipped, since it's the same app:

| Site | Repo | Host | URL checked (site, timing, cert) | Security check |
|---|---|---|---|---|
| davidpuerto.com | `davidpuerto.com-portfolio` | DigitalOcean | https://davidpuerto.com | headers; a third-party host the page needs; mail records for davidpuerto.com |
| davidpuerto.com (again) | `davidpuerto.com` (a new clone, 2026-11-19) | DigitalOcean | https://davidpuerto.com | the same |
| panogram | `panogram` | DigitalOcean | the production URL the host reports (no custom domain in its spec) | headers; `/embed/x` must stay embeddable |
| Sedulous | `sedulous` | DigitalOcean | the production URL the host reports | headers |
| shotgundetour.com | `shotgundetour` | DigitalOcean | https://shotgundetour.com | headers; a third-party host the page needs |
| spacelabforever.com + Studio | `spacelabstudio` | DigitalOcean | https://spacelabforever.com (the static site) | run on studio.spacelabforever.com (the app): headers; mail records for spacelabforever.com |
| unakin.com | `unakin` | DigitalOcean | https://unakin.com | headers; a third-party host; mail records for unakin.com |
| portal.unakin.com | `unakin-portal` | DigitalOcean | https://portal.unakin.com/api/health, must contain `ok` | run on portal.unakin.com: headers; a third-party host; mail records for unakin.com |
| Rillet case study | `rillet/rillet-case-study` | Vercel | https://rillet-invoice-workspace.vercel.app | headers |

That's eight distinct sites through nine repos. The second davidpuerto.com entry means its alerts
would arrive twice until one checkout is retired or the sentinel learns to dedupe.

**The four checks on each:**
- **site**: answers 2xx/3xx (and contains `expect_text` where one is set), two checks in a row
  before it says so. The same request's **time to first byte and full load** are recorded.
- **deploy**: the newest production deployment didn't fail; a build in progress is no verdict.
- **cert**: the TLS certificate of the URL's host is valid for more than 14 days.
- **security**: the shared site-hardening kit's live check: the six security headers and no
  server or framework disclosure on every site, plus third-party hosts, SPF/DMARC and embeds
  where a project sets them. Three consistent sightings, never while a deploy is in flight, and
  **never posting a form** (see 11). Projects list a `security_form` for the hand-run check only.

**Slow pages** (added 2026-11-19): the 7:30 briefing names a site whose typical time to first byte
or full load since the last briefing was over 3 s, or at least twice its own 7-day median. "Full
load" is the health URL's document, not a browser render with images and scripts. No history
existed before today, so no slowdown has been flagged yet: **not measured**.

**How I hear first:** a push the moment a problem is confirmed; the 7:30 briefing (what needs me,
then what happened); *"status"* to Siri leads with anything open; the glasses list it first.

**Not watched:**
- application errors inside a site (each app's own logs);
- whether email actually arrives (only that the mail records exist);
- the host shipmate runs on. If the laptop is offline, nothing is checked, and it can't report
  its own absence. An outside dead-man's switch is **PLANNED**.

The log shows the cost of that: 30 of the 32 "down" alerts since October were "doesn't answer",
often several sites at once, which looks like the laptop's own connection rather than the sites.
The sentinel can't tell those apart yet.

## 6. Security

shipmate's own surface:
- Only the MCP endpoint and its sign-in are public (Funnel). The onboarding page, mission
  control, approvals and Ship-it buttons bind to the Tailscale interface: joining my tailnet is
  the login.
- Sign-in pages send `Content-Security-Policy` (`default-src 'none'`, nonce'd scripts),
  `X-Frame-Options: DENY` and `Referrer-Policy: no-referrer`.
- Rate limits: 5 wrong pairing codes per 10 minutes; 30 glasses questions per 10 minutes; 3 MB per
  spoken question.
- **The gate:** executing needs a single-use plan grant (10 minutes, same project), enforced in
  code. Plan turns run read-only. Background agents work on a fresh branch with no deploy
  credentials. New spend needs a tap from my own device. The glasses and the R1 ring can never
  ship.
- **The push guard** on every clone refuses the wrong remote, protected paths (`.env*` by
  default, plus NDA case-study folders per project) and changes over a file cap (40). An override
  must name the rule it skips, and lands in the ledger.
- **Secrets:** read from the project's local env file and sent to the host's encrypted store
  through a shredded `0600` temp file (DigitalOcean) or stdin (Vercel), never argv, logs or git. A
  pre-commit hook blocks secret values.

What comes from the shared site-hardening kit: the sentinel's **security check** is the kit's
`check.mjs`. Headers, CSP, rate limits, the blocklist, form bot gates and the forensic log on each
**site** are the kit's `shield.mjs`, applied in those repos, not here. shipmate's own server does
not use `shield.mjs`.

## 7. Editing

- **Code and copy:** in Claude Code, or in a background job (*"work on dark mode for unakin"*)
  that builds on its own branch and comes back as a proposal.
- **Shipping it:** the same gate by terminal, Siri, the Claude app or a Ship-it tap.
- **Logs:** *"log to unakin …"* appends and commits a captain's-log entry verbatim, and pushes only
  on *"ship it"*.
- **Commits** follow this repo's convention: an imperative subject, a body that says what changed
  and why, and no AI attribution.
- The in-browser CMS belongs to the portfolio repo; shipmate has none. Its guard is what keeps a
  CMS rebuild (`content-locked/`, about 280 generated files) from tripping the file cap: generated
  paths aren't counted.

## 8. Release pipeline

shipmate has no store release.
- **Install:** `git clone` and `./install.sh` (links the skill into Claude Code); LaunchAgents keep
  the servers up.
- **Before every commit:** 13 shell suites (687 checks) and 16 glasses tests.
- **Glasses app:** `npm run pack` builds the `.ehpk`, sideloaded through Even Hub. Verified in the
  simulator; on the real G2 and R1 it's **PLANNED**.
- **For the sites it ships:** push to `main` → the host builds → the live check confirms the
  commit is serving → rollback is a phrase (*"roll back X, confirm"*), deterministic, with no
  model in the loop. One-tap rollback from a sentinel push is **PLANNED**.

## 9. Data for decisions

- **The file cap:** the ledger showed the overrides were nearly all one cause. Every portfolio
  commit over the cap since 10 October was over it because of CMS relocks, and authored changes
  never passed 28 files a commit. So the cap stayed at 40, and generated paths stopped counting.
- **Judging overrides:** reading all 52 against the commit history found no harm, and found a
  naming bug (a worktree push filed under its folder name), now fixed.
- **Dictation:** `ledger.sh report --dictation` lists what Siri heard when no project matched;
  those became name aliases.
- **Cost:** every plan states its cost line before anything bills. Spending and CRM numbers don't
  flow through shipmate: **not measured**.

## 10. Three screens worth filming

Full staging in [DEMO-SHOTS.md](DEMO-SHOTS.md). All three run on throwaway data with no keys:

1. **The push guard says no:** a terminal pushing 60 files and a `.env` to a local fake remote,
   then the named override, then `ledger.sh report`. Seed: the demo repo in DEMO-SHOTS. Blur:
   nothing, it's all demo.
2. **The sentinel, then "good morning":** a local web server stopped and restarted, the 🔴 and 🟢
   lines, then the briefing read aloud. Seed: the one-project demo fleet. Blur: nothing; if the
   phone is in shot, use a throwaway ntfy topic.
3. **Ask the glasses:** the Even Hub simulator, a long press, *"what do you remember?"*, then
   *"ship it"* refused on the display. Seed: a demo home and a demo pairing. Blur: the pairing code
   and any tailnet address. Never use the real Gate view or `glasses/docs/gate.png` (it shows
   test entries).

## 11. One thing that went wrong

The security check I added on 26 October posted to each site's contact form on every pass, to
prove a cross-site post was refused. Each probe spent the form's real rate limit, wrote a row in
its attempt log and counted toward its alerts. The same day it locked this Mac out of my own
portfolio contact form. The fix: the sentinel never posts a form; that check runs by hand after a
deploy. The lesson, now a design rule: watching must not cost the thing watched.
