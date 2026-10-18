# shipmate-mcp

The shipmate engine as **MCP tools**, so any MCP client — Claude Code, and eventually the
Claude apps through a remote connector — can drive deploys and background agent jobs. Voice
(the Siri bridge) and MCP are two mouths on the same tested engine: both call
`voice/shipmate-voice.sh`.

Zero dependencies: plain Node, JSON-RPC 2.0 over stdio.

## Register (local, Claude Code)

```bash
claude mcp add --scope user shipmate -- node ~/Sites/shipmate/mcp/shipmate-mcp.js
```

Then from any session: "use shipmate_plan to see what deploying this would cost."

## HTTP transport (for the Claude apps as a custom connector)

```bash
node mcp/shipmate-mcp.js --http 8788        # binds 127.0.0.1 ONLY
tailscale funnel --bg 8788                  # public HTTPS via your tailnet name
```

The endpoint is `https://<your-mac>.<tailnet>.ts.net/mcp`. Add it at claude.ai → Settings →
Connectors → **Add custom connector**, and leave the sign-in option on **OAuth** (the default
it detects). Claude registers itself, then sends you to shipmate's sign-in page.

**Signing in needs you, on your own devices.** Enroll a passkey once: on your iPhone (Tailscale
on) open the onboarding page and tap **Add a passkey on this device**, or on the Mac run
`node mcp/shipmate-mcp.js --enroll-passkey` and open the copied link. Face ID or Touch ID creates it.
From then on the sign-in page has one button, **Sign in with passkey**. The browser signs a
one-time challenge with a key bound to this server's address, so a lookalike site can't use it,
and biometrics (or the device passcode) are required, not just a tap.

**Or an authenticator app.** Microsoft Authenticator, Google Authenticator or 1Password: open
`http://<tailnet-ip>:8790/totp` on your Mac (or run `--enroll-totp` and open the copied link), scan
the QR code with your phone, type one code to confirm. Sign-in then asks for the 6-digit code.
Codes allow ±30 s of clock drift, can't be reused, and five wrong ones cancel the sign-in. The
QR code is drawn on the server (`mcp/vendor/qrcode.js`, MIT, vendored) and the secret is shown
only on that one-time page. `--totp-status`, `--remove-totp`. A passkey is stronger (a fake page
can't phish it); the app is the choice when your factors already live there.

Until a passkey or an authenticator app exists, sign-in falls back to an **Approve / Deny** push whose buttons only work
from your tailnet. Once either exists, that push is off. On the Mac, this always works:

```bash
node mcp/shipmate-mcp.js --approve-login ABC-123
```

Passkeys: `--passkeys` lists them, `--remove-passkey <id>` deletes one. Attestation is "none":
the one-time enrollment link (tailnet page or Mac shell, 10 minutes, single use) is the root of
trust. A sign count that goes backwards (a cloned authenticator) is refused.

What the server enforces (OAuth 2.1, per the MCP authorization spec):

- **Discovery**: `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server`;
  a 401 from `/mcp` names the metadata URL.
- **Registration** only for Claude's connector callbacks (`https://claude.ai|claude.com/api/mcp/auth_callback`)
  and loopback (Claude Code). `SHIPMATE_OAUTH_REDIRECTS` adds others.
- **Authorization code + PKCE (S256 only)**, codes single-use and 5 minutes long.
- **Access tokens last 1 hour; refresh tokens 30 days and rotate.** A refresh token presented
  twice revokes every token from that sign-in. Tokens are stored as SHA-256 hashes.
- **Scopes**: `shipmate:read` (plan, status, doctor, counsel, results, rollback descriptions) and
  `shipmate:execute` (everything that changes something). A read-only sign-in can't ship.
- **Audit**: every registration, sign-in, refusal and revocation lands in `~/.shipmate/mcp/auth.log`.

Admin on the host: `--grants` lists sign-ins, `--revoke-all` signs every client out.
`tailscale funnel --https=443 off` removes public access entirely. The pre-OAuth URL token
(`/mcp/<token>`) is revoked: the server deletes it on start and that path is a 404.
`tests/test_mcp_auth.sh` runs a real server and attacks the boundary, including a simulated
authenticator for passkeys and RFC 6238 codes for the app (118 assertions).

## Tools

| Tool | Does | Safety |
|---|---|---|
| `shipmate_plan` | describe what a request would do + exact cost | read-only, code-enforced (`--permission-mode plan`) |
| `shipmate_execute` | act on the planned request | **structurally gated** — see below |
| `shipmate_status` | background jobs: running/done/failed | read-only |
| `shipmate_task_start` | background agent job (build/test) | branch-only, never deploys, never bills |
| `shipmate_task_result` | a finished job's summary | read-only |
| `shipmate_task_stop` | stop a running job | — |
| `shipmate_doctor` | one-sentence health check (net, tailnet, servers, auth, disk, jobs, queue) | read-only, deterministic |
| `shipmate_briefing` | what needs you now + what happened since the last morning briefing | read-only, deterministic |
| `shipmate_log` | timestamped captains-log entry, committed verbatim | deterministic; pushes only with `publish:true` |
| `shipmate_rollback` | revert to the previous successful deployment (DO) | describe-only unless `confirm:true`; deterministic |
| `shipmate_counsel` | deliberate on a question (single model, or multi-model panel + dissent when the toggle is on) | read-only always |
| `shipmate_counsel_toggle` | counsel on/off (off = single Anthropic model, the default) | — |

## Keep it running (LaunchAgents)

```bash
bash mcp/install-launchagents.sh        # idempotent; --remove to undo
```

Installs user LaunchAgents for both servers (`--http 8788`, `--onboard 8790`): started at
login, restarted on crash, logs in `~/.shipmate/mcp/`. The funnel config persists on its own.
LaunchAgents start at *login* — for a host that must survive a power cut unattended, enable
automatic login (macOS disables that while FileVault is on).

## Onboarding new devices (`--onboard`)

```bash
node mcp/shipmate-mcp.js --onboard 8790
```

Serves a setup page at `http://<your-mac>.<tailnet>.ts.net:8790` — **bound to the Tailscale
interface only** (it refuses to start without one, and never touches the funnel port), so
joining your tailnet *is* the login. Tabs for each device type:

- **iPhone**: ntfy topic (copy), the Siri Shortcut recipe with host/user/script prefilled,
  a paste-box that validates + appends the Shortcut's SSH public key to
  `~/.ssh/authorized_keys` (dedup, `0600`), and the Claude-app note (the connector is
  account-level — nothing to configure per device).
- **Laptop**: zero-install options (claude.ai already has the connector; `ssh` one-liner)
  or promote it to a full host.
- **New host Mac**: bootstrap commands (clone → install → doctor → `claude setup-token`).

All values are derived at startup (user, tailnet name, repo URL, ntfy topic) — nothing
hardcoded.

## Mission control (`/dashboard`)

The onboarding server also serves **`http://<host>:8790/dashboard`** (tailnet-only, like
everything on that port): live jobs, production deploy phases with links (cached 60s),
the dead-zone intent queue, the last counsel transcript — and **pending approvals with
Approve/Deny buttons**, so the shotgun seat can authorize new spend while the driver drives.

## The two-phase gate (the point of this server)

`shipmate_execute` is refused **in code** unless `shipmate_plan` ran for the **same project**
within the **last 10 minutes**, and the grant is **single-use** — consumed on execute. In the
voice bridge, plan→confirm is a convention the prompt upholds; here it's a mechanism the
client cannot skip. A model that never planned *cannot* execute, no matter what it says.

Execute turns still carry the doctrine: cost-neutral steps (merge, build, push, redeploy)
proceed; creating new billed resources, resizing, or deleting stops and describes itself.

## Roadmap (Phase 4 of docs/ROADMAP.md)

- [x] v0: stdio server over the bridge's machine interface; two-phase plan/execute in code — the grant now lives in `voice/lib/gate.sh` inside the bridge, so Siri, this server and the terminal share one gate (a plan arms it, an execute consumes it, 10-minute TTL, single use). The onboard server's tailnet-only `POST /ship/<nonce>` is the 🚀 button on a plan push.
- [x] Streamable HTTP transport + Tailscale Funnel + token-in-path; registered as a claude.ai
      custom connector.
- [x] **Confirmed: the Claude iOS app's voice mode calls these tools.** The phone app is the
      conversational front-end; the Siri bridge is the wake-word/one-shot channel.
- [ ] Run the HTTP server + funnel as a LaunchAgent (today it dies on reboot).
- [x] OAuth 2.1 in place of the bearer URL (PKCE, scopes, tailnet-tap sign-in, rotating refresh).
- [x] Out-of-band confirm for billable steps: `request-approval.sh` + ntfy action buttons
      hitting the tailnet-only server (`/approve/<nonce>`, `/deny/<nonce>`); fails closed.
