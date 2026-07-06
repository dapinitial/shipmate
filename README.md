# shipmate ⚓

**Tell your terminal to ship it.** A natural-language deploy & ops assistant that orchestrates
DigitalOcean, Vercel, and (soon) anywhere — you pick the destination, shipmate handles the build,
the host, the DNS, and the certificate. One command instead of an afternoon of dashboard clicking.

> It's a [Claude Code](https://claude.ai/code) skill — say *"deploy this"* and it runs the whole
> dance — and it's **voice**: *"Hey Siri, shipmate — deploy panogram… ship it"* from CarPlay, or a
> continuous conversation in the Claude app (via [MCP](mcp/)) while background agents build,
> test, and wait for your go.

## Why

Shipping a small app still means hand-clicking across three silos that don't talk to each other:

- the **host** (DigitalOcean / Vercel / …),
- the **DNS** (records, subdomains, certs),
- the **registrar** — and some, like SquareSpace, have **no API at all**.

Every new project, you redo the same manual ritual. shipmate is the brain that does it for you —
and, crucially, it **knows where the gaps are**. It tells you the one thing a provider won't let it
automate instead of pretending it can.

## What it does today

- **Deploys** the current project to **DigitalOcean App Platform** (GitHub deploy-on-push).
- Generates the right `.do/app.yaml` for your stack (Next.js, Astro SSR, …) with **no secrets in
  the repo**.
- Prints the exact DNS record to map your subdomain — or, when your DNS is hosted on the provider,
  maps it **automatically** (record + TLS cert, zero clicks).
- Has a **safety model**: it shows the plan *and the cost* and waits for your explicit yes before
  anything bills or goes live. Voice is a lovely demo and a terrible UI for irreversible infra — so
  confirmation is built in, not bolted on.

## Install

```bash
git clone git@github.com:dapinitial/shipmate.git
cd shipmate && ./install.sh        # links the skills into ~/.claude/skills
```

Then in Claude Code, from any project: **`/deploy`**.

Requires [`doctl`](https://docs.digitalocean.com/reference/doctl/) (DigitalOcean),
[`gh`](https://cli.github.com/), and a Claude Code session.

## Choose your destiny

| Provider | Status | Notes |
|---|---|---|
| DigitalOcean App Platform | ✅ live | ~$5/mo flat · commercial-OK · you size scaling |
| Vercel | ✅ beta | free Hobby (non-commercial) / $20 Pro · best Next.js DX · auto-scales |
| Cloudflare / Render / Fly.io | 💭 wishlist | |

`/deploy` detects the target (`.do/app.yaml` → DO, `.vercel/` → Vercel) or asks you inline.

The per-provider details and the full DNS story live in **[docs/PROVIDERS.md](docs/PROVIDERS.md)**.

## Roadmap

- [x] Provider-agnostic `/deploy` — pick DO or Vercel inline ("choose your destiny").
- [x] **Voice** v1 — conversational Apple Shortcut → headless-Claude bridge ("Hey Siri,
      shipmate, deploy panogram" … "do it"): persistent sessions, background agent jobs,
      push-back to CarPlay. Plan mode is code-enforced. See **[voice/](voice/)**.
- [ ] **DNS automation** — host the domain on the provider and subdomains become fully hands-off.
- [ ] **Alexa Skill** front-end (same bridge).
- [x] **MCP server** — the engine as agent-callable tools (plan/execute/status/jobs) with the
      plan→confirm gate enforced in code; drivable from the Claude iOS app's **voice mode** as a
      custom connector, with a tailnet-only **device onboarding page**. See **[mcp/](mcp/)**.
- [ ] **MCP ecosystem** — providers ship their *own* agent-callable skills (Cloudflare, Stripe,
      GitHub already do); shipmate becomes the orchestration + safety layer that composes them.

Full thinking in **[docs/ROADMAP.md](docs/ROADMAP.md)**.

## Status

Early, and dogfooded on the author's own fleet. The honest test: if running `/deploy` daily feels
like magic, the bigger thing is real.

## License

MIT © 2026 David Puerto
