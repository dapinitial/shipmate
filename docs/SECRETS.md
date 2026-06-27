# Secret handling — shipmate's doctrine

How shipmate gets secrets into a deployment **without ever leaking them**, and why the mechanism
differs per provider.

## The universal principle (true everywhere)
- Secrets are read from the project's **already-local `.env.local`** — no new exposure; we forward
  what's already on the machine.
- They **never** touch git, shell history (no values in argv), logs, stdout, or the LLM.
- The platform **encrypts at rest**.
- Anything written transiently (a temp spec) is `0600` in `$TMPDIR` and **shredded on exit**, even
  on error/interrupt.

## Two philosophies (this is the key mental model)

### 1. Value injection — PaaS
Push the secret *value* into the platform's encrypted env store.

| Platform | Mechanism | shipmate adapter |
|---|---|---|
| **DigitalOcean** | app-spec env, `type: SECRET` | `bin/do-provision.sh` — temp-spec-and-shred ✅ |
| **Vercel** | `vercel env add` reads value from **stdin** | pipe via stdin (no temp file needed) 🛠 |
| Render / Fly / Railway | CLI/API env set | same shape |

Good enough for small apps. The value lives in the platform.

### 2. Reference + identity — cloud-native (more secure)
The value lives in a dedicated vault; the app gets *permission to read it*, not a copy.

- **AWS** → Secrets Manager / SSM `SecureString` (KMS-encrypted), referenced **by ARN**, access via **IAM**.
- **Azure** → Key Vault + Key Vault references (`@Microsoft.KeyVault(...)`) + **Managed Identity**.
- **GCP** → Secret Manager, same shape.

Deploy config holds a *pointer*, never the secret. One audited, rotatable source of truth. This is
the north star shipmate grows toward.

## Terraform — the footgun
Terraform writes secrets in **plaintext to its state file**. Even clean injection (`TF_VAR_*`,
gitignored `.tfvars`) leaves them in state — so you **must** use an encrypted remote backend
(S3+KMS, Terraform Cloud) and ideally pull from a secrets manager at apply time. Never inline
secrets in `.tf`.

## What this means for shipmate
There is **no one-size injection** — each target needs its own adapter, and doing each one the
*right, safe way* is the hard, valuable part (not a thin wrapper). Roadmap: DO ✅ → Vercel stdin →
AWS/Azure vault-reference → Terraform encrypted-state. The endgame is Philosophy 2 everywhere:
"store it in your cloud's vault and reference it" instead of copying values around.
