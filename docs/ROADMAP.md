# Roadmap

The arc: a single deploy skill → a provider-agnostic ops assistant → voice → an ecosystem where
providers ship their own agent-callable skills and shipmate composes them.

## Phase 1 — Deploy, one provider
- [x] DigitalOcean App Platform deploy skill (`/deploy`), stack-aware (Next.js, Astro SSR).
- [x] DNS modes documented; safety/confirmation model.
- [x] Dogfood end-to-end on a real fleet; capture the rough edges. (The first voice-driven
      production ship — a feature built by a background agent, reviewed, then merged and
      deployed by voice — landed 2026-07.)

## Phase 2 — Choose your destiny (multi-provider)
- [x] `/deploy` asks (or detects) the target: **DigitalOcean** or **Vercel**.
- [x] Vercel path: `vercel` CLI / API, env sync, preview deploys. (beta)
- [ ] **DNS automation** — when the domain is on provider DNS, create subdomain + cert hands-off.
- [ ] One-time **DNS migration helper** (registrar → DO/Cloudflare) with a record-replication
      checklist so nothing breaks.

## Phase 3 — Voice
The brain (an LLM running CLIs/APIs) already exists — voice is a thin, easy front-end. The value
is the orchestration + safety underneath, not the wake word.
- [x] **Apple Shortcut**: "Hey Siri, shipmate…" → SSH into your own Mac, conversational
      sessions (`--resume`), background agent jobs, push-back via ntfy → CarPlay. Plan mode is
      code-enforced (`--permission-mode plan`); execute needs a trailing "confirm"/"ship it".
      See [voice/](../voice/).
- [ ] **Alexa Skill** equivalent.
- [x] Confirmation-by-voice for *reversible* actions only; billable steps require an explicit
      out-of-band confirm: `request-approval.sh` pushes ntfy **Approve/Deny buttons** that hit
      the tailnet-only server — a tap from your own device, not a "yeah sure". Fails closed.

## Phase 4 — Ecosystem (MCP)
The industry is heading toward providers exposing agent-callable tools (**MCP** —
Model Context Protocol; Cloudflare, Stripe, GitHub already ship servers).
- [x] **shipmate as an MCP server** (v0, stdio): plan/execute/status/jobs as tools, with the
      plan→confirm gate enforced in code (single-use, 10-minute grant). See [mcp/](../mcp/).
- [x] Streamable HTTP transport (`--http` + Tailscale Funnel, token-in-path auth) → registered
      as a claude.ai custom connector. **Confirmed 2026-07: the Claude iOS app's voice mode
      can call the tools** — continuous voice conversation with plan→execute gating is real.
      (Hardening next: LaunchAgent so the server survives reboots; OAuth instead of the
      bearer URL.)
- [ ] Compose provider MCP servers instead of bespoke CLI glue.
- [ ] Invite registrars/hosts (NameSilo, Bluehost, Porkbun, DO, Cloudflare…) to publish skills;
      shipmate becomes the orchestration + safety layer on top, not the integration grind.

## Phase 5 — It speaks first (the Jarvis arc, 2026-10)
Initiative without new authority: every piece observes, reminds or answers, and anything that
changes production still goes through the same plan → grant → execute gate.
- [x] **Sentinel** — site down (2 checks), failed deploy, expiring cert; pushed once, recovery
      once; observes only (`bin/sentinel.sh`).
- [x] **Morning briefing** — what needs you + what happened since the last one; facts only, no
      model; 07:30 push, "good morning", the Claude app, the glasses (`bin/briefing.sh`).
- [x] **It remembers** — facts, reminders, learned names, and the conversation thread across
      Siri, the Claude app and the terminal; notes for the model, never permissions.
- [x] **Talk on the glasses** — hold, speak, let go; whisper.cpp on the host; read-only.
      Verified in the Even Hub simulator; hardware pending.

## Next (queued, in order)
1. **Always-on host: revive the iMac.** Move the servers, Funnel, the LaunchAgents and
   `~/.shipmate`; repack the glasses (the manifest whitelists the public origin). With it:
   - an **outside dead-man's switch** (a free uptime check on the Funnel URL that pushes when the
     host itself goes dark — the sentinel can't report its own death);
   - a **backup + tested restore** of `~/.shipmate` (ledger, memory, OAuth/passkeys, aliases).
2. **Make the ledger credible.** The portfolio's guard was overridden 19 times in one evening
   with the catch-all `SHIPMATE_ALLOW=1` (plus one entry filed under "hotfix"). Fit
   `.shipmate.yml`'s cap/protected list to how that repo is really worked, or have the session
   name the rule it skips; assess the overrides with `ledger.sh annotate`.
3. **One-tap rollback from the sentinel.** When the sentinel confirms a site down and the host
   has a previous good deployment, the push carries **Roll back** (tailnet-only button, like
   Ship it). Design:
   - the sentinel stays an observer: it reports the candidate; the bridge decides and mints a
     **single-use offer** (`lib/offer.sh`, ~30-minute TTL, bound to the project);
   - on tap (`POST /rollback/<nonce>` on the onboard server): consume the offer, **re-probe** —
     if the site answers again, do nothing and say so — else roll back through `verb_rollback`
     (channel `rollback-button`, ledger `rollback executed`), then re-run the sentinel so the
     🟢 recovery push follows; on Vercel, say that new pushes are held until roll-forward;
   - only for "site down", never for a failed deploy (the old version is still serving) or a cert.
4. **G2 hardware.** Sideload; confirm long-press (touchpad and ring) starts listening, the audio
   rate (`[shipmate] heard N bytes in M ms`), and the layout on the real display.

**Paused:** YC (installer for strangers, outside users). Revisit after 1–3.

## Principles
- **APIs, not UI automation.** Never script a dashboard's HTML — it's brittle and can't run in CI.
  Where a provider has no API (SquareSpace), say so and hand off the one manual step.
- **Safety over magic.** Always show the plan + cost; gate irreversible/billable actions behind an
  explicit yes. A mis-heard "deploy" must never nuke prod or start spend.
- **Credentials stay with the user.** Tokens live in the user's own CLI config / keychain; shipmate
  never stores or transmits them.
