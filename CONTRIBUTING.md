# Contributing to shipmate

shipmate touches **billed, irreversible, production infrastructure**, so the bar is: *safe,
portable, and honest about gaps*. Read [CLAUDE.md](CLAUDE.md) — it's the operating contract.

## Setup
```bash
git clone git@github.com:dapinitial/shipmate.git
cd shipmate && ./install.sh                 # links skills into ~/.claude/skills, enables the secret hook
bash skills/deploy/bin/doctor.sh            # check your tools + auth
```

## Before every commit
- `bash tests/test_envspec.sh` — **green** (the env classifier is security-critical).
- `bash skills/deploy/bin/doctor.sh` — sane on your machine.
- No secret value in any committed file (the pre-commit hook enforces it).
- No hardcoded usernames/refs — derive from context (`gh`/git remote, `.env.local`, `.shiprc`).
- Commit messages: human-authored, **no AI/co-author attribution**.

## Portability rules
- `#!/usr/bin/env bash`, `set -euo pipefail` (report-only scripts may relax `-e`).
- **macOS bash 3.2 safe**: no associative arrays / `readarray` / `mapfile` / `${x,,}` — use `awk`.
- Works with **BSD and GNU** `sed`/`awk`. Prefer `python3`, fall back to `jq`, for JSON.
- Every helper: a `--help`, idempotent, and a **dry-run** where it deploys.

## Secrets (non-negotiable)
- Resolve tokens in order: **env var → CLI auth / OS keychain → clear error** (`lib/secrets.sh`).
- Never echo a secret, never put one in argv. Use a `0600` temp file shredded via `trap`, or stdin.
- The `GENERAL` vs `SECRET` classifier (`lib/envspec.sh`) is the highest-risk code — change it only
  with tests.

## Adding a provider (the adapter contract)
A provider is a set of `skills/deploy/bin/<provider>-*.sh` helpers implementing the same shape:

| Verb | Does | Example |
|---|---|---|
| **provision** | create/update the app + inject env **safely** | `do-provision.sh`, `vercel-provision.sh` |
| **url** | print the live URL | `do-app.sh url` |
| **lifecycle** | status / logs / redeploy / destroy (destroy gated by `--yes`) | `do-app.sh` |
| **auth/allowlist** | wire the app's backing services (e.g. Supabase redirect URLs) | `supabase-allowlist.sh` |

Then add a path to `skills/deploy/SKILL.md` and a row to `docs/PROVIDERS.md`. Reuse `lib/envspec.sh`
(env merge/classify), `lib/secrets.sh` (tokens), `lib/json.sh` (JSON). Add tests for any new
security-critical logic. Cost-changing actions get an explicit confirm; cost-neutral ones just
chime the cost.
