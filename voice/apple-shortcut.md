# Apple Shortcut setup — "Hey Siri, shipmate"

One-time setup so you can say *"Hey Siri, shipmate, deploy panogram"* (it runs in safe **plan
mode**; add **"confirm"** to the end to actually execute).

## Prereqs
- **Remote Login (SSH) on the Mac:** System Settings → General → Sharing → **Remote Login** = on.
- Note the Mac's **username** and **local IP** (or a hostname / Tailscale name for off-network).
- An SSH key the Shortcut can use (Shortcuts can generate one and you add it to the Mac's
  `~/.ssh/authorized_keys`).
- `chmod +x ~/Sites/shipmate/voice/shipmate-voice.sh`

## Build the Shortcut
1. **Shortcuts app → ＋ New Shortcut.** Name it **shipmate** (the name *is* the Siri phrase).
2. Add **Dictate Text** (or **Ask for Input**) → this captures what you say after "shipmate".
3. Add **Run Script Over SSH**:
   - **Host** = Mac IP / hostname, **User** = your username, **Authentication** = the SSH key.
   - **Script**:
     ```
     bash ~/Sites/shipmate/voice/shipmate-voice.sh "[Dictated Text]"
     ```
     (insert the *Dictated Text* variable where shown)
4. Add **Speak Text** → input = the **Shell Script Result**, so it reads the plan back to you.
5. Done. Invoke with **"Hey Siri, shipmate"** → speak your request.

## Using it
- *"…deploy panogram"* → speaks back the **plan + cost**, does nothing. Review it.
- *"…deploy panogram, confirm"* → actually runs (still pausing on irreversible steps).

## Off your home network
Point the SSH host at a **Tailscale** machine name (free, easy) instead of a LAN IP, so "Hey
Siri, shipmate" works from anywhere.

## Caveat
This v0 drives `claude --print` headlessly; granting it the tool permissions to call
`doctl`/`vercel` non-interactively is the main hardening step (see [README.md](README.md)). Until
then it shines in **plan mode** — which is exactly where voice belongs anyway.
