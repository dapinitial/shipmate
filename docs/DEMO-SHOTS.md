# Demo shots — shipmate for a portfolio film

Seven moments that show what shipmate does today, in the order a viewer understands them:
it **refuses**, it **counts**, it **speaks first**, it **briefs**, it **listens**, and only
then it **ships**. Every shot is staged on demo data; none needs a real recipient, a real key,
or a change to a real site.

**There is no public sandbox for shipmate.** (spacelabforever.com/studio is Spacelab Studio's.)
Each shot is one of:

| Source | Means |
|---|---|
| **Local · demo data** | This Mac, a throwaway folder, no keys, no network beyond localhost. |
| **Local · simulator** | As above, plus the Even Hub simulator and whisper.cpp. Still no keys. |
| **Your setup** | Your tailnet, phone, Claude login and a real project. Frame carefully (see the end). |

## Stage the demo (once, before shots 1–5)

Every shipmate path can be pointed elsewhere by environment, so the demo never touches
`~/.shipmate` or `~/Sites`. Run this in each terminal you film from:

```bash
export DEMO="$TMPDIR/shipmate-demo" SM=~/Sites/shipmate
export SHIPMATE_LEDGER="$DEMO/ledger.jsonl" SHIPMATE_SENTINEL_DIR="$DEMO/sentinel" \
       SHIPMATE_SENTINEL_LOG="$DEMO/sentinel.jsonl" SHIPMATE_MEMORY="$DEMO/memory.jsonl" \
       SHIPMATE_HEARD="$DEMO/heard.jsonl" SHIPMATE_BRIEFING_MARK="$DEMO/briefing.last" \
       SHIPMATE_SITES_ROOT="$DEMO/fleet" SHIPMATE_APP_SH="$DEMO/app.sh" \
       SHIPMATE_SENTINEL_CHECKS="site deploy"
```

And once, to build the props:

```bash
mkdir -p "$DEMO/www" "$DEMO/fleet/demo-shop/.do" && cd "$DEMO"
# a repo with a local "remote", so pushes go nowhere real
git init -q --bare remote.git && git init -q -b main site && cd site
git remote add origin ../remote.git
printf 'max_files: 40\nprotected:\n  - .env\n' > .shipmate.yml
echo hi > index.html && git add -A && git -c user.name=Demo -c user.email=demo@example.com commit -qm init
bash $SM/skills/deploy/bin/install-hooks.sh "$DEMO/site" && git push -q origin main
# a one-project fleet whose "host" is a file you edit, and whose site is a local web server
cd "$DEMO/fleet/demo-shop" && git init -q && echo 'name: demo-shop' > .do/app.yaml
printf 'health_url: http://127.0.0.1:8799/\n' > .shipmate.yml
echo ok > "$DEMO/www/index.html" && echo "ACTIVE 6/6 2026-11-19" > "$DEMO/phase"
cat > "$DEMO/app.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in status) echo "deploy: $(cat "$(dirname "$0")/phase")";; *) echo "demo: status only"; exit 9;; esac
EOF
chmod +x "$DEMO/app.sh"
```

Reset between takes: `rm -rf "$DEMO"` and run the block again.

---

## 1. The push guard says no

- **Screen:** one terminal, large type.
- **What happens:** a 60-file commit that also carries a `.env` is pushed. shipmate refuses
  twice, in plain words: *pushing main would change 61 files; this project's cap is 40*, and
  *'.env' is a protected path… refusing to push it.* The `.env` comes out and the push is refused
  again for the size. Then `SHIPMATE_ALLOW=max-files git push` goes through, because a person
  named the rule they were skipping.
- **Stage:**
  ```bash
  cd "$DEMO/site"; for i in $(seq 1 60); do echo $i > page$i.html; done; echo X=1 > .env
  git add -A && git -c user.name=Demo -c user.email=demo@example.com commit -qm "big change"
  git push origin main                      # refused: size + .env
  git rm -q --cached .env && rm .env && git -c user.name=Demo -c user.email=demo@example.com commit -qm "drop env"
  git push origin main                      # refused: size
  SHIPMATE_ALLOW=max-files git push origin main   # through, and recorded
  ```
- **Source:** Local · demo data. Verified 2026-11-19.

## 2. Every decision is counted

- **Screen:** the same terminal.
- **What happens:** `ledger.sh report` lists what the gates just decided: three refusals and
  one override, each with the rule, the counts and *note: (not yet assessed)*. Then a human
  judgment is added with `annotate`. That's the point: the record holds facts, and only a person
  writes what they meant.
- **Stage:**
  ```bash
  bash $SM/skills/deploy/bin/ledger.sh report
  bash $SM/skills/deploy/bin/ledger.sh annotate <id of the override> "Deliberate: one feature, 60 pages."
  bash $SM/skills/deploy/bin/ledger.sh show <same id>
  ```
- **Source:** Local · demo data. The report is verified; the annotate step is the same command
  used on the real ledger.

## 3. It speaks first

- **Screen:** split: left, the demo site's web server; right, the sentinel. Optionally a phone
  showing the push.
- **What happens:** the site is stopped. The first check stays silent (one bad answer isn't a
  verdict). The second says *🔴 demo-shop is down… doesn't answer, two checks in a row. If the
  last deploy caused it, say 'roll back demo-shop, confirm'.* A failed deploy is said at once
  (*❌ … Production stays on the previous version*). Restart the site, flip the phase back, and it
  says each recovery once: *🟢 demo-shop is back… after about 1 min*, *✅ demo-shop deploys again.*
- **Stage:**
  ```bash
  python3 -m http.server 8799 --bind 127.0.0.1 -d "$DEMO/www"     # left pane; Ctrl-C to "go down"
  S() { bash $SM/skills/deploy/bin/sentinel.sh "$DEMO/fleet"; }    # right pane
  S                       # healthy: silent
  # stop the server, then:
  S; S                    # silent, then 🔴
  echo "ERROR 3/6 2026-11-19" > "$DEMO/phase"; S                     # ❌
  # restart the server, then:
  echo "ACTIVE 6/6 2026-11-19" > "$DEMO/phase"; S                    # 🟢 and ✅
  ```
  For the phone: install the ntfy app, subscribe to a **throwaway random topic**, and pipe the
  output: `S | while read -r l; do curl -s -d "$l" ntfy.sh/<random-topic> >/dev/null; done`.
  ntfy topics are public, so use a fresh one and nothing but demo text.
- **Source:** Local · demo data (the phone needs the free ntfy app, no account). Verified
  2026-11-19.

## 4. "Good morning"

- **Screen:** the terminal, then the Mac's voice reading it (or the glasses' BRIEF view, shot 5).
- **What happens:** the briefing puts what needs you first (a reminder), then what happened (the
  outage and failed deploy from shot 3, both recovered; the gate held 3; the guard was overridden
  once). No model writes it: same facts, same sentence, every time.
- **Stage:**
  ```bash
  bash $SM/voice/shipmate-voice.sh --remember reminder "check the demo shop's checkout page"
  bash $SM/skills/deploy/bin/briefing.sh --hours 24 | say
  bash $SM/skills/deploy/bin/briefing.sh --hours 24 --lines     # the heads-up version
  ```
- **Source:** Local · demo data. Verified 2026-11-19. Known wording nit on a one-project fleet:
  *"All 1 projects are answering."* Fix it or crop it before filming.

## 5. Ask the glasses, and watch them refuse to ship

- **Screen:** the Even Hub simulator (the glasses' green-on-black display), with the touchpad.
- **What happens:** a long press, a spoken *"what do you remember?"*, and the answer appears on
  the display: the demo reminder. Then *"deploy demo-shop, ship it"*, and the display answers
  *I heard ship it, but the glasses can only plan. Tap Ship it on your phone, or say it to
  Siri.* The cheapest gesture gets the least authority. The BRIEF view shows shot 4's lines.
- **Stage:** a shipmate server on a demo home, paired with a demo device:
  ```bash
  mkdir -p "$DEMO/home/.shipmate/mcp"
  H=(HOME="$DEMO/home" SHIPMATE_WHISPER_MODEL="$HOME/.shipmate/whisper/ggml-base.en.bin")
  env "${H[@]}" node $SM/mcp/shipmate-mcp.js --http 8797 &
  env "${H[@]}" node $SM/mcp/shipmate-mcp.js --pair-device "Demo G2"          # prints a code
  cd $SM/glasses && npm run dev -- --port 5174 &
  npx evenhub-simulator http://localhost:5174/ --automation-port 9898 \
      --aid coreaudio:MSLoopbackDriverDevice_UID
  # open http://localhost:5174/#pair=<CODE>&server=http://127.0.0.1:8797 in the simulator
  curl -s -X POST -d '{"action":"long_press"}' localhost:9898/api/input
  say -a "Microsoft Teams Audio" "what do you remember"
  curl -s -X POST -d '{"action":"long_press_release"}' localhost:9898/api/input
  ```
  (The loopback device routes `say` into the simulator's microphone; any loopback driver works.)
  Afterwards: `env "${H[@]}" node $SM/mcp/shipmate-mcp.js --grants` and `--revoke-client <id>`.
- **Source:** Local · simulator. No keys: speech is transcribed by whisper.cpp on the Mac, and
  memory, briefing and refusal questions need no model. Verified against the demo server over
  HTTP (pair, glance, both answers) on 2026-11-19. The simulator run itself was filmed against
  the live server before, not yet against this demo server, so do one dry take. The demo
  project's Fleet row reads `UNKNOWN` (the glance asks the real host), so film BRIEF and talk,
  not Fleet.

## 6. Plan, then Ship it, in the Claude app

- **Screen:** the phone, the Claude app in voice mode, then shipmate's Ship-it card.
- **What happens:** *"How would you deploy panogram?"* gets a plan and a cost, with nothing
  changed. Saying *"ship it"* without a fresh plan is refused. After the plan, the **Ship it**
  tap goes through, and the live check reports when the commit is actually serving.
- **Stage:** your real connector (OAuth sign-in with your passkey) and a real project. Use a
  **cost-neutral redeploy** (an empty commit or a copy change) on a site you own, or stop the
  take at the plan and the refusal. Either way it ships nothing billed.
- **Source:** Your setup. Needs your tailnet, your Claude account and a real host. It can't be
  faked honestly, because the gate is the product.

## 7. "Hey Siri, shipmate, status", from the car

- **Screen:** CarPlay (or the phone's Siri sheet), the spoken reply as captions.
- **What happens:** one sentence in, one sentence back: live deploy phases and anything the
  sentinel has open, led by the open problem. Optionally *"roll back panogram"* (without
  *confirm*) describes the rollback and changes nothing.
- **Stage:** the Shortcut from [voice/apple-shortcut.md](../voice/apple-shortcut.md) over SSH
  to your Mac. Film parked.
- **Source:** Your setup (SSH key, your real fleet's names, which are public sites).

---

## Keep out of frame

- the tailnet hostname (`*.ts.net`), the Funnel URL, any bearer token, pairing code or grant nonce;
- the ntfy topic you really use (shot 3 uses a throwaway one);
- the OAuth/passkey sheet and any account email;
- your real `~/.shipmate` ledger in the glasses' Gate view. It holds test entries filed under
  "r1", which is also why `glasses/docs/gate.png` must never be used;
- `.env*` contents. In shot 1 the `.env` holds `X=1` and nothing else.

## For the portfolio card

**Card (≤ 60 chars):** Voice-run deploys behind a gate agents can't talk past

**Modal story:**
shipmate is the deploy and ops assistant I built for my own fleet of eight live sites: say
"deploy this" in the terminal, to Siri in the car, or into the Claude app, and it plans the
change, shows the cost, and ships to DigitalOcean or Vercel. The interesting part is the
authority model: nothing reaches production without a single-use grant from a plan step, every
push is guarded, and every decision lands in a ledger I judge by hand. It also speaks first,
watching every site for downtime, failed deploys, expiring certificates and security drift,
briefing me at 7:30, and answering questions asked into Even G2 glasses that can look but never
ship.
