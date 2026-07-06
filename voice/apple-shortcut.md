# Apple Shortcut setup — "Hey Siri, shipmate"

One-time setup so you can say *"Hey Siri, shipmate"* and then talk to your fleet. Plan mode is
the default; end a phrase with **"confirm"** (or "do it") to actually execute.

## Prereqs
- **Remote Login (SSH) on the Mac:** System Settings → General → Sharing → **Remote Login** = on.
- Note the Mac's **username** and **local IP** (or a hostname / Tailscale name for off-network).
- An SSH key the Shortcut can use (Shortcuts can generate one and you add it to the Mac's
  `~/.ssh/authorized_keys`).
- `chmod +x ~/Sites/shipmate/voice/shipmate-voice.sh`

## Shortcut A — one shot (simplest)
1. **Shortcuts app → ＋ New Shortcut.** Name it **shipmate** (the name *is* the Siri phrase).
2. Add **Dictate Text** → captures what you say after "shipmate".
3. Add **Run Script Over SSH**:
   - **Host** = Mac IP / hostname, **User** = your username, **Authentication** = the SSH key.
   - **Input** = the *Dictated Text* variable (the bridge reads it from stdin), **Script**:
     ```
     bash ~/Sites/shipmate/voice/shipmate-voice.sh
     ```
   - (Equivalent alternative: leave Input empty and put the variable in the script line
     itself: `bash ~/Sites/shipmate/voice/shipmate-voice.sh "[Dictated Text]"`.)
4. Add **Speak Text** → input = the **Shell Script Result**.

Sessions persist on the Mac, so even one-shot invocations chain: run it again and say
*"confirm"* — it remembers the plan it just read you.

## Shortcut B — conversation loop (for the road)
Same as A, but wrap steps 2–4 in a **Repeat 10 times** block:

1. **Repeat (10)**
   1. **Dictate Text**
   2. **Run Script Over SSH** (same script as above)
   3. **Speak Text** (Shell Script Result)
2. End Repeat

Now one *"Hey Siri, shipmate"* gives you ten back-and-forth turns: plan → ask about cost →
*"do it"* → *"work on the next feature"* → *"status"*. End early by staying silent (dictation
times out) or saying "cancel" to Siri.

## Using it on a drive
- *"…deploy panogram"* → speaks the **plan + cost**, does nothing.
- *"…confirm"* → executes (still pauses on anything irreversible).
- *"…work on adding dark mode to panogram"* → replies immediately; the agent works on the Mac.
  When it finishes, **ntfy → CarPlay** announces the result (see [README.md](README.md)).
- *"…status"* / *"…what happened with job 2?"* → check in whenever.

## Off your home network
Point the SSH host at a **Tailscale** machine name (free, easy) instead of a LAN IP, so "Hey
Siri, shipmate" works from anywhere — including the highway.

## Notes
- Long-running *conversational* turns hold the SSH connection open; if Shortcuts times one
  out, phrase big work as a background job ("work on …") — that path returns in ~2 seconds by
  design.
- Dictation punctuation ("Deploy panogram, confirm.") is handled — case and punctuation are
  stripped before parsing.
