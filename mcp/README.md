# shipmate-mcp (v0 — stdio)

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

The endpoint is `https://<your-mac>.<tailnet>.ts.net/mcp/<token>` where `<token>` is a
48-hex-char secret minted into `~/.shipmate/mcp/http-token` (0600) on first run. Every other
path 404s. Add that URL at claude.ai → Settings → Connectors → **Add custom connector**.

**Be clear-eyed about the trade:** the URL is a bearer secret for a server that can deploy
your apps and start agent jobs. TLS terminates on your Mac (relays see ciphertext), execute
stays behind the plan grant, but whoever holds the URL holds the keys. Treat it like a
password; `tailscale funnel --https=443 off` kills public access instantly. A LaunchAgent +
OAuth are the production path — this is the experiment path.

## Tools

| Tool | Does | Safety |
|---|---|---|
| `shipmate_plan` | describe what a request would do + exact cost | read-only, code-enforced (`--permission-mode plan`) |
| `shipmate_execute` | act on the planned request | **structurally gated** — see below |
| `shipmate_status` | background jobs: running/done/failed | read-only |
| `shipmate_task_start` | background agent job (build/test) | branch-only, never deploys, never bills |
| `shipmate_task_result` | a finished job's summary | read-only |
| `shipmate_task_stop` | stop a running job | — |
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

## The two-phase gate (the point of this server)

`shipmate_execute` is refused **in code** unless `shipmate_plan` ran for the **same project**
within the **last 10 minutes**, and the grant is **single-use** — consumed on execute. In the
voice bridge, plan→confirm is a convention the prompt upholds; here it's a mechanism the
client cannot skip. A model that never planned *cannot* execute, no matter what it says.

Execute turns still carry the doctrine: cost-neutral steps (merge, build, push, redeploy)
proceed; creating new billed resources, resizing, or deleting stops and describes itself.

## Roadmap (Phase 4 of docs/ROADMAP.md)

- [x] v0: stdio server over the bridge's machine interface; two-phase plan/execute in code.
- [x] Streamable HTTP transport + Tailscale Funnel + token-in-path; registered as a claude.ai
      custom connector.
- [x] **Confirmed: the Claude iOS app's voice mode calls these tools.** The phone app is the
      conversational front-end; the Siri bridge is the wake-word/one-shot channel.
- [ ] Run the HTTP server + funnel as a LaunchAgent (today it dies on reboot).
- [ ] OAuth in place of the bearer URL.
- [x] Out-of-band confirm for billable steps: `request-approval.sh` + ntfy action buttons
      hitting the tailnet-only server (`/approve/<nonce>`, `/deny/<nonce>`); fails closed.
