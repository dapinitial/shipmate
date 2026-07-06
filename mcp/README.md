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
- [ ] Out-of-band confirm for billable steps: ntfy action buttons hitting a local callback.
