# shipmate ⚓

**Tell your terminal to ship it.** A natural-language deploy & ops assistant that orchestrates
DigitalOcean, Vercel, and (soon) anywhere — you pick the destination, shipmate handles the build,
the host, the DNS, and the certificate. One command instead of an afternoon of dashboard clicking.

> Today it's a [Claude Code](https://claude.ai/code) skill: say *"deploy this"* and it runs the
> whole dance. The roadmap is **voice** — *"Hey shipmate, I'm ready to ship"* — across any provider.

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
| Vercel | 🛠 planned | free Hobby (non-commercial) / $20 Pro · best Next.js DX · auto-scales |
| Cloudflare / Render / Fly.io | 💭 wishlist | |

The per-provider details and the full DNS story live in **[docs/PROVIDERS.md](docs/PROVIDERS.md)**.

## Roadmap

- Provider-agnostic `/deploy` — pick DO or Vercel inline ("choose your destiny").
- **DNS automation** — host the domain on the provider and subdomains become fully hands-off.
- **Voice** — an Apple Shortcut and an Alexa Skill front-end ("Hey shipmate, deploy panogram").
- **MCP** — lean on the Model Context Protocol so providers can ship their *own* agent-callable
  skills, and shipmate composes them.

Full thinking in **[docs/ROADMAP.md](docs/ROADMAP.md)**.

## Status

Early, and dogfooded on the author's own fleet. The honest test: if running `/deploy` daily feels
like magic, the bigger thing is real.

## License

MIT © 2026 David Puerto
