---
name: deploy
description: Deploy the current project to DigitalOcean App Platform (GitHub deploy-on-push) and print the exact SquareSpace DNS record to map its subdomain. Use when the user says "deploy this", "ship it", "set up the environment and deploy", "put this live", or asks to host a project on DO with a custom subdomain. Fleet tool — works from any project directory.
---

# /deploy — DigitalOcean App Platform + SquareSpace DNS

Deploys the project in the **current directory** to DO App Platform and hands the user the
exact CNAME to add at SquareSpace. SquareSpace has **no DNS API**, so that one step stays a
manual paste until the domain's DNS is migrated to an API provider (DO DNS or Cloudflare) —
call that out every run; it's the only thing not automated.

## Reality check first (don't skip)
- **DO App Platform is NOT free** — basic-xxs is ~$5/mo per app. (Vercel Hobby is the free
  alternative for Next.js; mention it if the user expected free.)
- This **spends money and is outward-facing**. Treat it like every irreversible action:
  show the plan, get an explicit "yes", then act. Never deploy on a guess.

## Preconditions — check each, stop with the fix if missing
1. `doctl` installed: `command -v doctl`. If missing → tell the user:
   `brew install doctl && doctl auth init` (needs a DO API token from
   cloud.digitalocean.com/account/api/tokens). Stop until done.
2. `doctl account get` succeeds (authed).
3. `gh auth status` logged in, and the repo is pushed to GitHub `dapinitial/<name>`
   (DO deploys from GitHub, not local).
4. Working tree committed and pushed (DO builds what's on `main`).
5. `npm run build` is green — run it; abort on failure.

## Gather the target (ask, don't assume)
- **Subdomain + umbrella domain** (e.g. `panogram.unakin.com`). The umbrella varies per
  brand — unakin.com, spacelabforever.com, davidpuerto.com, etc. Ask which.
- **Region** (default `nyc`).

## Build/refresh the `.do/app.yaml` spec (stack-aware)
Mirror the sibling projects' pattern. Detect the stack from the repo:
- **Next.js**: `environment_slug: node-js`, `build_command: npm run build`,
  `run_command: npx next start -p 8080`, `http_port: 8080`.
- **Astro SSR** (`@astrojs/node`): `run_command: node dist/server/entry.mjs`, `http_port: 8080`.
- `github: { repo: dapinitial/<name>, branch: main, deploy_on_push: true }`
- `instance_size_slug: basic-xxs`, `instance_count: 1`
- **Public env vars inline** (`NEXT_PUBLIC_*` / `PUBLIC_*`, publishable/anon keys are safe).
  Include `NEXT_PUBLIC_SITE_URL: https://<sub>.<umbrella>`.
- **Secrets NEVER in the spec** (it's committed). List them as comments to add encrypted in
  the dashboard: `SUPABASE_SECRET_KEY`, `RESEND_API_KEY`, any `*_PEPPER` (use a FRESH prod
  value, never the dev one).
- `domains: [{ domain: <sub>.<umbrella>, type: PRIMARY }]`

Commit the spec (human-authored message, no AI attribution — see the repo's CLAUDE.md) and push.

## Show the plan, get confirmation
Print: app name, region, instance size + **~$5/mo cost**, domain, and the list of encrypted
env vars the user must add. Wait for an explicit yes.

## Deploy
- New app: `doctl apps create --spec .do/app.yaml`
- Existing (find id: `doctl apps list`): `doctl apps update <id> --spec .do/app.yaml`
- Then have the user add the **encrypted** secrets in DO → app → Settings → Env, by name.
  (You cannot set encrypted secrets safely from the CLI without exposing them — keep them out.)

## DNS — pick the mode (this is the painpoint; default to Mode A)

**Mode A — DNS hosted on DO (RECOMMENDED, fully automatic).** If the domain's DNS is on
DigitalOcean, the app spec's `domains:` block makes DO **auto-create the subdomain record AND
provision the cert** — zero manual steps, no SquareSpace, ever. To get a domain onto DO DNS
(one-time per umbrella domain):
  1. `doctl compute domain create <umbrella>` (or for a brand-new domain, just this).
  2. **⚠ Recreate ALL existing records first** if the domain is already live (MX/email, other
     subdomains like `sedulous.unakin.com`) — moving nameservers without replicating records
     breaks email and existing sites. List the current records with the user before migrating.
  3. At the **registrar (SquareSpace)**, change nameservers to
     `ns1.digitalocean.com`, `ns2.digitalocean.com`, `ns3.digitalocean.com`. This is the ONLY
     manual SquareSpace action, done **once per domain, forever.**
  After propagation, every future subdomain for that domain is automatic via the app spec.
  - **Cleanest option for a new project:** a fresh dedicated domain straight onto DO DNS — no
    migration risk, no existing records to replicate.

**Mode B — DNS still at SquareSpace (fallback, manual once).** SquareSpace has no DNS API, so:
  - `doctl apps get <id> --format DefaultIngress` → `<app>.ondigitalocean.app`
  - Tell the user verbatim:
    > **SquareSpace → Domains → `<umbrella>` → DNS → add a CNAME:**
    > Host `<sub>` → Value `<app>.ondigitalocean.app`
  DO provisions the cert once DNS resolves.

**Mode C — no custom domain yet (fastest, free).** Skip DNS entirely: the app is live at
`<app>.ondigitalocean.app` the moment it deploys. Use this to dogfood end-to-end now and add a
custom domain later.

## Verify
- Poll `doctl apps get <id>` until the active deployment is `ACTIVE`.
- Once DNS resolves, `curl -sI https://<sub>.<umbrella>` → expect 200/301.
- For apps with magic-link auth (Supabase), remind: add the prod URL to Supabase →
  Authentication → URL Configuration (Site URL + `https://<sub>.<umbrella>/**`).

## After / the bigger picture
- Every `git push` to `main` now auto-redeploys (`deploy_on_push`).
- **The unlock:** migrate the umbrella domain's DNS off SquareSpace to **DO DNS** (or
  Cloudflare) — one-time nameserver change. Then the manual CNAME step becomes a
  `doctl compute domain records create` call and this whole flow is genuinely one command.
  Flag this to the user as the next investment whenever they deploy.
