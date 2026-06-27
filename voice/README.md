# Voice (experimental v0)

> *"Hey Siri, shipmate — deploy panogram."*

The brain already exists: Claude Code running the `/deploy` skill. Voice is a thin front-end on
top. This is a working **v0 scaffold**, deliberately safe, not a polished product.

## How it flows

```
You speak  →  Apple Shortcut ("Hey Siri, shipmate …")
           →  Run Script over SSH  →  your Mac
           →  voice/shipmate-voice.sh "<phrase>"
           →  claude --print  (headless, runs the /deploy skill)
           →  result spoken back to you (Speak Text)
```

No new server, no cloud — it SSHes into your own machine and drives the same skill you'd run by
hand. Set it up in **[apple-shortcut.md](apple-shortcut.md)**.

## Safety (the whole reason this is careful)

Voice is a lovely demo and a **dangerous UI for irreversible infra** — it mishears, and there's
no diff to review. So:

- **Plan mode by default.** A spoken request only ever *describes* what it would do and the cost.
  It creates, charges, and publishes **nothing**.
- **Explicit execute.** To actually run, the phrase must end with **"confirm"** (or "do it" /
  "send it") — a deliberate second utterance, not an accidental "yeah."
- **Hard stops still hold.** Even in execute mode, any step the skill flags as irreversible pauses.
- **Credentials never move** — doctl/vercel tokens stay in your CLI config; the bridge just
  invokes the local skill.

## Status / hardening TODO

- [ ] Headless tool-permission config (so `/deploy` can call `doctl`/`vercel` non-interactively
      *only* for the safe, plan-mode parts).
- [ ] Out-of-band confirm for billable steps (a phone tap, not just a spoken word).
- [ ] Project resolution from the phrase ("deploy panogram" → `~/Sites/panogram`).
- [ ] Alexa Skill equivalent (same bridge, different front-end).
