# shipmate ⚓

**Tell your terminal to ship it.** A natural-language deploy & ops assistant that orchestrates
DigitalOcean, Vercel, and (soon) anywhere — you pick the destination, shipmate handles the build,
the host, the DNS, and the certificate. One command instead of an afternoon of dashboard clicking.

> It's a [Claude Code](https://claude.ai/code) skill — say *"deploy this"* and it runs the whole
> dance — and it's **voice**: *"Hey Siri, shipmate — deploy panogram… ship it"* from CarPlay, a
> continuous conversation in the Claude app (via [MCP](mcp/)), or a question asked into a pair of
> Even G2 glasses ([glasses/](glasses/)) — while background agents build, test, and wait for your
> go. And it speaks first: it watches every live site (up, deploying, certificate, security
> baseline), briefs you at 7:30, and remembers across channels. None of that adds a way to ship.

## What it is, and what it isn't

shipmate **ships and runs** websites you already have: it deploys them, maps their domains,
guards every push, watches them in production, and rolls them back. It is not a site builder.
The building happens where it always did — in Claude Code, or in a background agent shipmate
starts on a throwaway branch with no deploy credentials — and comes back as a proposal that
has to pass the same gate as anything you'd push yourself.

## Why

Shipping a small app still means hand-clicking across three silos that don't talk to each other:

- the **host** (DigitalOcean / Vercel / …),
- the **DNS** (records, subdomains, certs),
- the **registrar** — and some, like SquareSpace, have **no API at all**.

Every new project, you redo the same manual ritual. shipmate is the brain that does it for you —
and, crucially, it **knows where the gaps are**. It tells you the one thing a provider won't let it
automate instead of pretending it can.

## Design — why this isn't vibe coding

shipmate separates **brains from authority**. Agents can read state, plan work, and build on
throwaway branches with zero credentials; nothing reaches production except through one gate.
The interesting problem was never getting an LLM to run `doctl` — it's an authority model
where you can hand agents your infrastructure and sleep.

- **Authority is structural, not conversational.** Executing requires a fresh **single-use
  grant** minted by a plan step (10-minute TTL, enforced in code). An agent that never
  planned *cannot* execute — no prompt injection, mishearing, or hallucination changes that.
- **Read-only means enforced read-only** — plan turns run under Claude Code's
  `--permission-mode plan`, not under "please don't write anything."
- **Workers are untrusted by design.** Background agents get a fresh branch, no deploy
  credentials, and can't touch the default branch. Their output is *proposals*; merge and
  deploy pass back through the gate.
- **Thin clients, one engine.** Siri/SSH, the Claude app's voice mode (via [MCP](mcp/)), the
  glasses and the terminal are interchangeable mouths on the same tested core — adding a
  front-end adds **zero new authority**.
- **Tests where bugs are catastrophic.** The env secret-classifier and the parser that
  decides plan-vs-execute are the two places a bug ships a plaintext secret or executes a
  misheard command; both have suites, and so do the gate, the guard, the sign-in, the ledger,
  the sentinel, the briefing, memory and the glasses (`tests/`, `glasses/test/`).
- **Count what it let through.** Every gate decision — allowed ones included — is one line in
  an append-only ledger. Facts only; whether a refusal mattered is a human note, never inferred.
- **The cheapest gesture gets the least authority.** The glasses and the R1 ring can watch and
  ask, never ship; approvals stay on the phone, where the plan is on the screen.
- **Watching must not cost the thing watched.** The sentinel only reads. Its security check
  never posts to a form (each probe would spend the form's real rate limit — it once locked this
  Mac out of a contact form) and never judges a site mid-deploy.
- **Deliberation is a toggle, not a lifestyle.** `counsel off` (default): the single default
  Anthropic model answers — fast, and frankly the best. `counsel on`: questions fan out to a
  multi-model panel in parallel and a chair synthesizes, *required to name the dissent*.
  Always read-only either way.
- **Honest gaps over false magic.** No provider API → shipmate says so and hands you the one
  manual step.

## What it does today

- **Deploys** the current project to **DigitalOcean App Platform** or **Vercel** (GitHub
  deploy-on-push), behind one set of lifecycle verbs — status, url, phase, check, rollback,
  roll-forward — so the gate, the checks and the ledger behave the same on both.
- Generates the right `.do/app.yaml` for your stack (Next.js, Astro SSR, …) with **no secrets in
  the repo**; secrets go to the host's encrypted store through a shredded temp file (DO) or stdin
  (Vercel), never argv.
- Prints the exact DNS record to map your subdomain — or, when your DNS is hosted on the provider,
  maps it **automatically** (record + TLS cert, zero clicks).
- Has a **safety model**: it shows the plan *and the cost* and waits for your explicit yes before
  anything bills or goes live. Voice is a lovely demo and a terrible UI for irreversible infra — so
  confirmation is built in, not bolted on.
- **Speaks and listens**: Siri/CarPlay one-shots, or a continuous Claude-app voice conversation
  (via [MCP](mcp/)) — background agents build on jailed branches, push results to your phone, and
  wait for your go. New spend needs a **tap on a notification** (from your own tailnet), not a
  "yeah". *"Roll back panogram, confirm"* reverts a bad deploy with no model in the loop.
- **Deliberates on demand**: `counsel on` convenes a multi-model panel that must report its
  dissent; off (default), the single best Anthropic model answers.
- **Guards every push, from anyone**: a pre-push hook per clone refuses the wrong remote, a
  protected path, or a change bigger than the project's cap (generated build output doesn't count);
  a preflight runs before any execute; a live check reports when the commit is actually serving.
  An override must name the rule it skips, and lands in the ledger.
- **Signs you in properly**: the Claude-app connector uses OAuth 2.1 (PKCE, two scopes, rotating
  refresh tokens) with a passkey or an authenticator app.
- **Speaks first**: a sentinel checks every live site every five minutes and pushes once when a
  problem starts and once when it ends —
  - **site**: down, or up without its expected text (two checks in a row); the same request's
    time to first byte and full load are kept, so the briefing can say when a page got slow,
  - **deploy**: the newest production deploy failed (a build in progress is no verdict),
  - **cert**: invalid or expiring within 14 days,
  - **security**: drift from the [site-hardening](https://github.com/dapinitial/site-hardening) baseline —
    headers, dependencies, mail records, embeds — after three consistent sightings, never while
    a deploy is in flight, never by posting a form.

  A deterministic briefing arrives at 7:30 (*"good morning"* asks for it any time), and names any
  site whose pages were typically over 3 s or twice their own 7-day median;
  *"remember…"*, *"remind me to…"* and *"where did we leave off?"* work across Siri, the Claude
  app and the terminal — memory is notes for the model, never permissions.
- **Fits on your face**: a read-only glance on Even G2 glasses (fleet, briefing, plan, gate), and
  press-and-hold — on a temple or the R1 ring — to ask; speech is transcribed on your own machine
  with whisper.cpp and never kept.

## Install

```bash
git clone git@github.com:dapinitial/shipmate.git
cd shipmate && ./install.sh        # links the skills into ~/.claude/skills
```

Then in Claude Code, from any project: **`/deploy`**.

Requires [`doctl`](https://docs.digitalocean.com/reference/doctl/) (DigitalOcean) and/or the
[`vercel`](https://vercel.com/docs/cli) CLI, [`gh`](https://cli.github.com/), and a Claude Code
session. Optional: Tailscale (voice + the Claude app), ntfy (pushes), whisper.cpp (talking on the
glasses), Node + the site-hardening skill (the sentinel's security check; skipped when absent).
`bash skills/deploy/bin/doctor.sh` reports what's set up.

## Choose your destiny

| Provider | Status | Notes |
|---|---|---|
| DigitalOcean App Platform | ✅ live | ~$5/mo flat · commercial-OK · you size scaling |
| Vercel | ✅ live | free Hobby (non-commercial) / $20 Pro · best Next.js DX · auto-scales |
| Cloudflare / Render / Fly.io | 💭 wishlist | |

`/deploy` detects the target (`.do/app.yaml` → DO, `.vercel/` → Vercel) or asks you inline.

The per-provider details and the full DNS story live in **[docs/PROVIDERS.md](docs/PROVIDERS.md)**.

## Where it's headed

Done: provider-agnostic `/deploy`; voice (Siri/CarPlay); the MCP server and Claude-app voice
mode; OAuth 2.1 sign-in; the decision ledger (every historical override now judged by hand);
Vercel at parity; and the "it speaks first" arc — sentinel, briefing, memory, glasses and ring.

Next, in this order — no dates promised:

1. **An always-on host.** Move the servers off the laptop to an iMac, with an outside
   dead-man's switch (the sentinel can't report its own death) and a tested backup of
   `~/.shipmate`.
2. **One-tap rollback from the sentinel.** A confirmed "site down" push carries a **Roll back**
   button (single-use, tailnet-only); on tap it re-probes first and does nothing if the site is
   back. Designed, not built.
3. **G2 + R1 on the real hardware.** Everything on the glasses is verified in the Even Hub
   simulator today.

Later: DNS automation when the domain is on provider DNS, an Alexa front-end on the same bridge,
and composing providers' own MCP servers instead of CLI glue — shipmate as the orchestration and
safety layer on top. Opening it to outside users (an installer for strangers) is **paused**
until 1–3 are done.

Full thinking in **[docs/ROADMAP.md](docs/ROADMAP.md)**. Filming it: **[docs/DEMO-SHOTS.md](docs/DEMO-SHOTS.md)**.

## Status

Early, and dogfooded on the author's own fleet since July (eight live sites: seven on
DigitalOcean, one on Vercel). 698 shell checks and 16 glasses tests. The honest gaps: the host
is still a laptop; the glasses and ring are verified in the simulator, not on the hardware; the
sentinel's security check is exercised on the live fleet but has no test in the suite yet; and
Siri dictation remains the weakest link — which is why nothing executes on a single sentence.
The full story, numbers included: [unakin.com/case-studies/shipmate](https://www.unakin.com/case-studies/shipmate).

## License

MIT © 2026 David Puerto
