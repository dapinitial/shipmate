# Voice (v1 — conversational)

> *"Hey Siri, shipmate — deploy panogram."* … *"what will that cost?"* … *"do it."*

The brain already exists: Claude Code running the `/deploy` skill. Voice is a thin front-end.
v1 makes it a **conversation** (sessions persist across utterances), adds **background agent
jobs** ("work on X" — hang up, drive, get pinged when it's done), and a **push-back channel**
so results reach you through CarPlay.

## How it flows

```
You speak  →  Apple Shortcut ("Hey Siri, shipmate …")
           →  Run Script over SSH  →  your Mac
           →  voice/shipmate-voice.sh "<phrase>"
           →  claude -p --resume <session>   (headless, remembers the conversation)
           →  reply spoken back  ·  long jobs detach and ping you via ntfy → CarPlay
```

No new server, no cloud — it SSHes into your own machine and drives the same skill you'd run
by hand. Setup in **[apple-shortcut.md](apple-shortcut.md)**.

## What you can say

| You say… | It does |
|---|---|
| *"deploy panogram"* | **Plan only.** Speaks the plan + monthly cost. Changes nothing. |
| *"what will that cost?"* (any follow-up) | Continues the **same session** — it remembers the plan. |
| *"…confirm"* / *"do it"* / *"send it"* / *"ship it"* | Executes the plan (still pauses on irreversible steps). |
| *"work on adding dark mode to panogram"* | **Background agent job.** Replies in 2 seconds, works for as long as it takes, pings your phone when done. Also: *"have an agent …"*, *"… in the background"*. |
| *"status"* / *"how's it going?"* | Which jobs are running/done, and for how long. |
| *"result"* / *"what happened with job 2?"* | Speaks a finished job's summary. |
| *"stop job 2"* | Kills a running job. |
| *"new session"* / *"start over"* | Forgets the current conversation. |

Projects are matched by name against `~/Sites` (configurable). Follow-ups that don't name a
project stay with the one you're already talking about.

## Safety (the whole reason this is careful)

Voice is a lovely demo and a **dangerous UI for irreversible infra** — it mishears, and
there's no diff to review. So:

- **Plan turns are read-only in code, not prose:** they run with Claude Code's
  `--permission-mode plan`, so a plan turn *cannot* write, run, or bill — no matter what the
  model or a misheard phrase says.
- **Explicit execute.** Only a phrase **ending** in "confirm" / "do it" / "send it" /
  "ship it" executes — a deliberate second utterance, not an accidental "yeah". A "confirm"
  mid-sentence doesn't count. Even then, irreversible/billable steps still pause.
- **Background jobs never touch prod:** they're instructed to work on a fresh branch, never
  push the default branch (deploy-on-push!), and never deploy or create anything that bills.
  Deploys only happen through the plan → confirm flow above.
- **The phrase parser is tested** (`tests/test_voice_phrase.sh`) — it's the code that decides
  plan vs execute, so it gets the envspec treatment.
- **Credentials never move** — doctl/vercel tokens stay in your CLI config; the bridge just
  invokes the local skill.

## Getting pinged while driving (ntfy)

Job-done notifications go through [ntfy.sh](https://ntfy.sh) (free, no account):

1. Install the **ntfy** app on your iPhone, subscribe to a topic with a long random name
   (the name is the only secret — anyone who knows it can read your notifications).
2. On the Mac: `mkdir -p ~/.shipmate && echo 'export SHIPMATE_NTFY_TOPIC=<your-topic>' >> ~/.shipmate/voice.env`
3. Allow the app's notifications; CarPlay/Announce Notifications reads them to you.

Self-hosted ntfy? Set `SHIPMATE_NTFY_URL`. No topic set? Jobs still run — you just have to
ask for *"status"*.

## Config (`~/.shipmate/voice.env`, all optional)

| Var | Default | Meaning |
|---|---|---|
| `SHIPMATE_SITES_ROOT` | `~/Sites` | where project dirs are matched by name |
| `SHIPMATE_PROJECT_DIR` | sites root | fallback when no project is named |
| `SHIPMATE_VOICE_STATE` | `~/.shipmate/voice` | session + job state |
| `SHIPMATE_NTFY_TOPIC` | *(unset)* | ntfy topic for pushes |
| `SHIPMATE_NTFY_URL` | `https://ntfy.sh` | ntfy server |
| `SHIPMATE_VOICE_CLAUDE_ARGS` | *(unset)* | extra flags for every `claude` call |

## Status / hardening TODO

- [x] Headless permission gating — plan turns run under `--permission-mode plan` (code-enforced).
- [x] Project resolution from the phrase ("deploy panogram" → `~/Sites/panogram`).
- [x] Multi-turn sessions (`--resume`), background jobs, push-back channel.
- [ ] Out-of-band confirm for billable steps (a phone tap, not just a spoken word) — the ntfy
      channel is the natural carrier for this.
- [ ] `shipmate-mcp`: expose plan/confirm/status/jobs as MCP tools so the Claude iOS app
      (voice mode) and other clients can drive the same engine. See docs/ROADMAP.md Phase 4.
- [ ] Alexa Skill equivalent (same bridge, different front-end).
