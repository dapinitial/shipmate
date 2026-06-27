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
- Deploying **spends money and is outward-facing.** Show the plan + the cost, get an explicit
  "yes", then act. Never deploy on a guess. A mis-heard command must never bill or publish.
- **Credentials stay with the user** — in their own CLI config / keychain. Never echo a secret;
  never write one into a committed file. The pre-commit/secret hygiene of the target repo wins.

---

## Path A — DigitalOcean App Platform

**Preconditions** (check each; stop with the fix if missing):
1. `command -v doctl` — else: `brew install doctl && doctl auth init` (token from
   cloud.digitalocean.com/account/api/tokens). 2. `doctl account get` authed.
3. `gh auth status` logged in; repo pushed to `dapinitial/<name>` (DO builds from GitHub).
4. Working tree committed + pushed. 5. `npm run build` green.

**Spec** — generate/refresh `.do/app.yaml` (stack-aware):
- **Next.js**: `environment_slug: node-js`, `build_command: npm run build`,
  `run_command: npx next start -p 8080`, `http_port: 8080`.
- **Astro SSR**: `run_command: node dist/server/entry.mjs`, `http_port: 8080`.
- `github: { repo: dapinitial/<name>, branch: main, deploy_on_push: true }`,
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
  `vercel --prod`. Returns the live `https://<project>.vercel.app`.
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

## Verify
- Confirm the deployment is live (DO: poll `doctl apps get <id>`; Vercel: the CLI returns the URL).
- `curl -sI https://<domain>` → expect 200/301.
- Supabase magic-link apps: remind the user to add the prod URL to Supabase → Auth → URL
  Configuration (Site URL + `https://<domain>/**`), or sign-in fails in prod.

## After
- Pushes to `main` auto-redeploy (DO `deploy_on_push` / Vercel git integration).
- The unlock for the registrar gap: move the umbrella domain's DNS to the host (Mode A). Then
  every future subdomain is one command. Flag it whenever the user is in Mode B.
