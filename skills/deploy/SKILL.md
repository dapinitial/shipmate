---
name: deploy
description: Deploy the current project to DigitalOcean App Platform OR Vercel — you choose the destination — and map a custom subdomain (automatically when DNS is on the host, or by printing the exact record when it's at a registrar like SquareSpace). Use when the user says "deploy this", "ship it", "set up the environment and deploy", "put this live". Fleet tool — works from any project directory.
---

# /deploy — ship to DigitalOcean or Vercel

Deploys the project in the **current directory** to whichever host the user picks, sets env,
and maps the domain. Same safety model and DNS story for both. shipmate's whole point: do the
host + DNS + registrar dance from one command, and be honest about the one step a provider
won't let you automate.

## 0. Pick the destination (ask or detect)
- Detect: `.do/app.yaml` → DigitalOcean. `vercel.json` / `.vercel/` → Vercel. Else **ask**.
- Help them choose if unsure (full table: docs/PROVIDERS.md):
  - **Prototype / demo** → **Vercel** (free Hobby, best Next.js DX, per-PR preview URLs).
  - **Real product, cost-sensitive** → **DigitalOcean** (~$5/mo flat, commercial-OK; Vercel
    commercial use needs Pro at $20/mo). DO scaling is manual; Vercel auto-scales.

## Safety model (applies to BOTH — this is the product, not a footnote)
- **Outward-facing + costs money, so gate on COST CHANGES, not every action:**
  - **Require an explicit yes** for anything that creates a billed resource or raises cost — a new
    app (`apps create`), an instance resize, more instances, a new add-on. Show the **monthly cost
    and the delta** in the plan, and present it as a clear prompt.
  - **Don't re-gate cost-neutral deploys** — redeploying an existing app, env/spec updates,
    `deploy_on_push`: same instance, no new charge. Proceed, but **always chime the cost line**
    (e.g. *"redeploy — still ~$5/mo, no change"*) so the user sees what they're running every time.
  - A mis-heard or ambiguous command must never create or bill on a guess.
- **Credentials stay with the user** — in their own CLI config / keychain. Never echo a secret;
  never write one into a committed file. The target repo's secret hygiene wins.

---

## Detect context — per project/repo/user (NEVER hardcode names)
Derive everything from the current project + environment so the skill works for *anyone*, and
self-corrects when moved between repos/users/machines:
- **GitHub owner/repo:** `gh repo view --json nameWithOwner -q .nameWithOwner` (fallback: parse
  `git -C <dir> remote get-url origin`). Use this `<owner>/<name>` in the spec — **never a literal
  username**. If an existing `.do/app.yaml`'s `repo:` owner ≠ the current git remote, **fix it
  (self-heal)** before deploying.
- **Per-project config:** if the project has a **`.shiprc`** (see `.shiprc.example`), source it and
  let its `PROVIDER` / `REGION` / `INSTANCE_SIZE` / `APP_NAME` override the skill defaults — user
  values always win.
- **App / project name:** `.shiprc` `APP_NAME`, else the repo name (or dir basename). **Region:**
  `.shiprc` `REGION`, else `nyc`.
- **Supabase ref:** `supabase/.temp/project-ref`, else the `<ref>` in `.env.local`'s SUPABASE_URL.
- **Tokens:** prefer an **env var** (`SUPABASE_ACCESS_TOKEN`, `DIGITALOCEAN_ACCESS_TOKEN`) → then
  the CLI's own stored auth / OS keychain → then a clear error. Never assume a keychain name.
  (`bin/*.sh` already follow this order and auto-derive.)

---

## Path A — DigitalOcean App Platform

**Preconditions** (check each; stop with the fix if missing):
1. `command -v doctl` — else: `brew install doctl && doctl auth init` (token from
   cloud.digitalocean.com/account/api/tokens). 2. `doctl account get` authed.
3. `gh auth status` logged in; repo pushed to GitHub (DO builds from GitHub) — use the derived `<owner>/<name>`.
4. Working tree committed + pushed. 5. `npm run build` green.

**Spec** — generate/refresh `.do/app.yaml` (stack-aware):
- **Next.js**: `environment_slug: node-js`, `build_command: npm run build`,
  `run_command: npx next start -p 8080`, `http_port: 8080`.
- **Astro SSR**: `run_command: node dist/server/entry.mjs`, `http_port: 8080`.
- `github: { repo: <owner>/<name>, branch: main, deploy_on_push: true }`  ← `<owner>` **derived**, never hardcoded,
  `instance_size_slug: basic-xxs`, `instance_count: 1`.
- **No secrets in the spec** (it's committed). Put a `# shipmate:envs` marker where env vars go;
  `bin/do-provision.sh` injects them from `.env.local` at deploy time (below).
- Add `domains: [{ domain: <sub>.<umbrella>, type: PRIMARY }]` only in DNS Mode A (below).

**Deploy (env auto-injected, secrets safe):** show plan (name, region, **~$5/mo**, domain) → on
yes, run `bash "$HOME/.claude/skills/deploy/bin/do-provision.sh" <project-dir>`. It reads
`.env.local`, splices vars into a **0600 temp spec** (`NEXT_PUBLIC_*`/`PUBLIC_*` plaintext, the
rest `type: SECRET`), runs `doctl apps create/update`, then shreds the temp — secrets never touch
git, shell history, logs, or the model. Get the URL: `doctl apps get <id> --format DefaultIngress`.
*(Fallback with no `.env.local`: add vars in the DO dashboard manually.)*

---

## Path B — Vercel

**Preconditions:**
1. `command -v vercel` — else `npm i -g vercel`. 2. `vercel whoami` authed — else `vercel login`.
3. `npm run build` green.

**Deploy:**
- Link the project: `vercel link` (creates `.vercel/`, ties this dir to a Vercel project).
- **Env vars** — add per environment. Public ones can be piped; for **secrets**, run
  `vercel env add <NAME> production` and let the user paste the value at the prompt (it never
  enters shell history). Mirror `.env.local`:
  `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `NEXT_PUBLIC_SITE_URL`,
  `SUPABASE_SECRET_KEY`, `RESEND_API_KEY`.
- Show plan (project, **Hobby = free non-commercial / Pro $20 commercial**, domain) → on yes:
  `bin/vercel-provision.sh <project-dir>` (links, pushes env from `.env.*` via stdin, deploys —
  **beta**) or plain `vercel --prod`. Returns the live `https://<project>.vercel.app`.
- **Auto-deploy:** prefer connecting the GitHub repo in the Vercel dashboard (Import Project) so
  every push deploys + PRs get preview URLs — note this to the user as the durable setup.

---

## DNS — same three modes for either host (the painpoint)
The fix is *where DNS lives*, not "automate the registrar."
- **Mode A — DNS on the host (DO DNS / Vercel DNS / Cloudflare): fully automatic.** Point the
  domain's nameservers at the host once; subdomain record + TLS cert are then created from the
  deploy config. Zero manual steps, forever. (DO: `doctl compute domain create <umbrella>` +
  set nameservers `ns1/ns2/ns3.digitalocean.com`. Vercel: add domain in project → use Vercel
  nameservers.) ⚠ Migrating an existing domain means **recreating all its records** (MX, other
  subdomains) on the new DNS first, or email/sites break — a fresh dedicated domain avoids this.
- **Mode B — DNS at a registrar with no API (SquareSpace): manual once.** Print the exact record:
  DO → `CNAME <sub> → <app>.ondigitalocean.app`; Vercel → the A/CNAME it shows on domain add.
- **Mode C — no custom domain yet:** ship to the host's default URL and add a domain later.

## Post-deploy — wire the follow-ups automatically (don't leave these manual)
- **Self-referencing URL (the chicken-egg):** if the app needs its own public URL
  (`NEXT_PUBLIC_SITE_URL` / `SITE_URL` / `PUBLIC_SITE_URL`), it can't be known until AFTER the first
  create. So: capture `DefaultIngress`, write it into **`.env.production`** (the gitignored prod
  overlay), and run a **cost-neutral `update`** to bake it in. Never ask the user to paste their
  own URL — resolve it.
- **Local vs prod divergence:** shared values live in `.env.local`; prod-only values (the live URL,
  prod-only keys) go in **`.env.production`**, which `do-provision.sh` layers on top. This matches
  Next.js's own model (dev → `.env.local`, prod build → `.env.production`).
- **Supabase magic-link apps:** the deployed URL must be allow-listed or sign-in breaks. Run
  `bin/supabase-allowlist.sh <project-dir> <url>` (ref + token auto-derived) — it sets Site URL and
  **non-destructively merges** `<url>/**` into the redirect allow-list via the Supabase Management
  API (token from the keychain, never echoed/argv). This changes **production auth config**, so it
  needs an **explicit confirm** (it'll be gated like any prod change). Manual fallback: Supabase →
  Auth → URL Configuration.

## Verify
- Confirm the deployment is live (DO: poll `doctl apps get <id>`; Vercel: the CLI returns the URL).
- `curl -sI https://<domain>` → expect 200/301.
- Supabase magic-link apps: remind the user to add the prod URL to Supabase → Auth → URL
  Configuration (Site URL + `https://<domain>/**`), or sign-in fails in prod.

## Lifecycle (after it's live)
- DO: `bin/do-app.sh <status|url|logs|redeploy|rollback|destroy> <project-dir>`. `rollback` reverts
  to the previous successful deployment via the DO API; `rollback` and `destroy` need `--yes`.

## After
- Pushes to `main` auto-redeploy (DO `deploy_on_push` / Vercel git integration).
- The unlock for the registrar gap: move the umbrella domain's DNS to the host (Mode A). Then
  every future subdomain is one command. Flag it whenever the user is in Mode B.
