# Providers

shipmate's job is to span **host + DNS + registrar** so you don't hand-click across three
dashboards. This is the per-provider reality — capabilities, costs, and where the automation
stops.

## DigitalOcean App Platform — ✅ live

- **Cost:** ~$5/mo flat (basic-xxs, always-on container). No commercial restriction — fine to run
  a real product in the wild.
- **Scaling:** you choose the instance size / count. A single small box won't absorb an
  uncontrolled traffic spike — size up before a big launch.
- **Deploy:** `.do/app.yaml` spec + `doctl apps create/update`, GitHub deploy-on-push.
- **Secrets:** never in the committed spec. Public build-time vars can be inline; secrets go in the
  DO dashboard as **Encrypted** env vars.

## Vercel — 🛠 planned

- **Cost:** **Hobby is free but non-commercial only.** A funded/commercial product must use **Pro
  ($20/mo)** + bandwidth.
- **Scaling:** serverless / edge — auto-scales under spikes with no config.
- **DX:** best-in-class for Next.js (made by the Next team) — zero-config, per-PR preview URLs.

### Picking between them
- **Prototype / demo:** Vercel (free, best DX, shareable preview links).
- **Real product, cost-sensitive:** DigitalOcean ($5 flat beats Pro's $20 and is commercial-clean).
- Both map apex domains **and** subdomains equally well.

## DNS — the three modes

DNS is the actual painpoint, and the fix is *where DNS lives*, not "automate the registrar."

- **Mode A — DNS on the provider (DO DNS / Vercel DNS / Cloudflare): fully automatic.** Point the
  domain's nameservers at the provider once; from then on every subdomain + cert is created from
  the deploy spec. Zero manual steps, forever.
- **Mode B — DNS at the registrar (e.g. SquareSpace): manual once.** SquareSpace has **no DNS API**
  — shipmate prints the exact CNAME, you paste it. Unavoidable until you migrate DNS off it.
- **Mode C — no custom domain yet:** ship to the provider's default URL
  (`<app>.ondigitalocean.app`) and add a domain later.

> ⚠ Migrating an *existing* domain's nameservers (Mode B → A) means recreating ALL its current
> records (email/MX, other subdomains) on the new provider first, or those services break. A fresh
> dedicated domain straight onto provider DNS avoids the migration entirely.

## The registrar gap (and why it's the interesting part)

PaaS platforms own the host. Nobody owns the seam across host **and** DNS **and** registrar —
especially registrars with no API. That gap, plus a safety model for letting an agent touch
irreversible/billable infra, is the part worth building.
