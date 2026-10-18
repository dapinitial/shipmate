# CLAUDE.md — shipmate operating protocols

shipmate is a natural-language deploy/ops assistant (Claude Code skills + helper scripts) that
touches **billed, irreversible, production infrastructure**. That makes the rules below non-
optional. The product vision is in [README.md](README.md); the secret doctrine in
[docs/SECRETS.md](docs/SECRETS.md); the plan in [docs/ROADMAP.md](docs/ROADMAP.md).

## Commit conventions
- Concise imperative subject + short body (what changed, why).
- **Never** add `Co-authored-by:` / `Generated with…` / any AI attribution. Human-authored.

## Safety doctrine (this IS the product)
- **Gate on cost changes, not every action.** Explicit confirm for creating billed resources or
  raising cost (new app, resize, scale). Cost-neutral redeploys proceed — but always chime the
  cost line. A mis-heard/ambiguous command must never create or bill on a guess.
- **Credentials stay with the user.** Resolve tokens in order: **env var → the platform CLI's own
  auth / OS keychain → clear error.** Never echo a secret, never put one in argv (`ps`-visible),
  never write one into a committed file. Transient secrets go in a `0600` temp file shredded via
  `trap`, or through stdin.
- **APIs, not UI automation.** Never script a dashboard's HTML. Where a provider has no API
  (e.g. SquareSpace DNS), say so and hand off the one manual step.
- **Honesty about gaps** over false magic.

## Authoring scripts & skills
- **Derive context per project/repo/user — never hardcode names.** GitHub owner from `gh`/git
  remote; project from the repo/dir; Supabase ref from the linked file or `.env.local`. Self-heal
  stale values.
- **Portable:** `#!/usr/bin/env bash`, `set -euo pipefail` (report-only scripts may relax `-e`).
  macOS bash 3.2 safe — **no** associative arrays / `readarray` / `mapfile` / `${x,,}`; use `awk`
  for maps. BSD *and* GNU `sed`/`awk`.
- **Degrade gracefully:** check for a tool before using it; prefer `python3` then `jq` for JSON;
  emit an actionable error, never a stack trace. `bin/doctor.sh` reports the dependency/auth state.
- **Security-critical logic lives in `skills/deploy/lib/` and MUST have tests** (`tests/`). The env
  classification (`GENERAL` vs encrypted `SECRET`) is the highest-risk code — a bug ships a secret
  in plaintext. **Run `tests/` before committing.**
- Every helper: a `--help`/usage, idempotent, and a **dry-run** where it deploys.

## Provider adapter contract
Each provider is a set of `bin/*-…sh` helpers with a stable shape: **provision** (create/update +
inject env safely), **url** (the live URL), **allowlist/auth** (wire the app's services), and a
**dry** mode. New providers implement the same verbs.

## Map
- `skills/deploy/SKILL.md` — the agent runbook (multi-provider, safety, DNS, post-deploy)
- `skills/deploy/bin/` — `doctor.sh`, `app.sh` (one set of lifecycle verbs for every provider:
  status, url, phase, check, rollback, roll-forward), `do-app.sh` + `vercel-app.sh` (the adapters
  behind it), `do-provision.sh`, `vercel-provision.sh`,
  `supabase-allowlist.sh`, `request-approval.sh` (tap-to-confirm for new spend),
  `deploy-card.sh` (derived "## Deploy (shipmate)" block for a repo's CLAUDE.md + fleet drift check),
  `preflight.sh` (deterministic checks before an execute turn), `install-hooks.sh` (the pre-push guard),
  `ledger.sh` (report/annotate the decision ledger; `report --dictation` lists the phrases that
  named no project, which is where dictation aliases come from), `sentinel.sh` (shipmate speaks
  first: site down, failed deploy, expiring cert — announced once, recovery once; observes only),
  `briefing.sh` (what needs you + what happened since the last morning briefing; facts only, no model)
- `skills/deploy/lib/provider.sh` — which host deploys a project (`provider:` in `.shipmate.yml`,
  else `.do/app.yaml`, else `.vercel/project.json`)
- `skills/deploy/lib/project.sh` — per-project `.shipmate.yml` (deploy remote, branch, file cap,
  protected paths, generated paths that don't count toward the cap, health URL) · `lib/pre-push.hook` — the guard installed per clone; an override
  names the rule it is skipping (`SHIPMATE_ALLOW=remote|max-files|protected`), and one that
  covered nothing is not recorded, so the ledger counts bypasses rather than habits ·
  `lib/ledger.sh` — every gate decision appended to `~/.shipmate/ledger.jsonl` (facts only;
  consequences are human notes added with `bin/ledger.sh annotate`, never inferred) ·
  `lib/sentinel.sh` — the sentinel's confirm-then-announce state machine; its transitions go to
  `~/.shipmate/sentinel.jsonl`, never the ledger · `lib/memory.sh` — what it remembers across
  channels (facts, reminders, learned names; the conversation log) — context for the model,
  never permission
- `skills/deploy/lib/envspec.sh` — the tested, security-critical env classifier
- `tests/` — run every `tests/test_*.sh` · `voice/` — the voice bridge (bridge + tested phrase
  parser in `voice/lib/`, which resolves a project by name, then alias, then how it sounds) · `mcp/` — the MCP server over the same engine (OAuth, passkeys, TOTP,
  the read-only glance + device pairing, and `/glance/ask`: questions from the glasses, transcribed
  on-host by whisper.cpp, run with `SHIPMATE_READONLY=1`) · `glasses/` — read-only Even G2 app (its own npm
  project; `npm test` there) · `docs/` —
  vision/secrets/roadmap
- `install.sh` — link skills into `~/.claude/skills` + enable the secret hook

## Before you commit
- [ ] every `tests/test_*.sh` green (env classifier, phrase parser, gate, deploy card, guardrails, MCP auth, ledger, providers, sentinel, briefing, memory, talk)
- [ ] `bash skills/deploy/bin/doctor.sh` sane on your machine
- [ ] no secret value in any committed file (the pre-commit hook enforces this)
- [ ] no hardcoded usernames/refs — derived from context
