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
- [ ] Confirmation-by-voice for *reversible* actions only; irreversible/billable steps require an
      explicit out-of-band confirm (a tap, not a "yeah sure") — ntfy action buttons are the
      natural carrier.

## Phase 4 — Ecosystem (MCP)
The industry is heading toward providers exposing agent-callable tools (**MCP** —
Model Context Protocol; Cloudflare, Stripe, GitHub already ship servers).
- [x] **shipmate as an MCP server** (v0, stdio): plan/execute/status/jobs as tools, with the
      plan→confirm gate enforced in code (single-use, 10-minute grant). See [mcp/](../mcp/).
- [ ] Streamable HTTP transport (Tailscale serve/funnel + auth) → Claude-app custom connector;
      test whether the iOS app's voice mode can call it.
- [ ] Compose provider MCP servers instead of bespoke CLI glue.
- [ ] Invite registrars/hosts (NameSilo, Bluehost, Porkbun, DO, Cloudflare…) to publish skills;
      shipmate becomes the orchestration + safety layer on top, not the integration grind.

## Principles
- **APIs, not UI automation.** Never script a dashboard's HTML — it's brittle and can't run in CI.
  Where a provider has no API (SquareSpace), say so and hand off the one manual step.
- **Safety over magic.** Always show the plan + cost; gate irreversible/billable actions behind an
  explicit yes. A mis-heard "deploy" must never nuke prod or start spend.
- **Credentials stay with the user.** Tokens live in the user's own CLI config / keychain; shipmate
  never stores or transmits them.
