#!/usr/bin/env bash
# install-launchagents.sh — keep the shipmate servers alive across crashes and reboots.
#
# Installs two macOS LaunchAgents for the current user:
#   com.shipmate.mcp-http     — shipmate-mcp --http 8788    (the Claude-app connector)
#   com.shipmate.mcp-onboard  — shipmate-mcp --onboard 8790 (tailnet-only device onboarding)
#
# Idempotent: safe to re-run after every git pull (it reloads the agents). All paths are
# derived — repo from this script's location, node from PATH, user from whoami.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-launchagents.sh [--remove]

Installs (or with --remove, uninstalls) LaunchAgents that keep the shipmate MCP server
(--http 8788) and the onboarding UI (--onboard 8790) running: started at login, restarted
on crash. Logs land in ~/.shipmate/mcp/.

Note: LaunchAgents start at *login*. For a headless host that must survive a power cut
unattended, enable automatic login (System Settings → Users & Groups) — macOS disables
that option while FileVault is on.
EOF
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$DIR/shipmate-mcp.js"
AGENTS="$HOME/Library/LaunchAgents"
LOGDIR="$HOME/.shipmate/mcp"
UID_NUM="$(id -u)"

NODE="$(command -v node || true)"
[ -z "$NODE" ] && { echo "✗ node not found on PATH — install Node.js first." >&2; exit 1; }

# label → kind|args, one per service (bash 3.2: no associative arrays).
# kind=server → node shipmate-mcp.js, KeepAlive. kind=timer → bash bridge, StartInterval.
services() {
  printf '%s\n' \
    "com.shipmate.mcp-http|server|--http|8788" \
    "com.shipmate.mcp-onboard|server|--onboard|8790" \
    "com.shipmate.queue-flush|timer|--flush-queue|60"
}

remove_all() {
  local line label
  services | while IFS='|' read -r label _ _; do
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    rm -f "$AGENTS/$label.plist"
    echo "✓ removed $label"
  done
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --remove)  remove_all; exit 0 ;;
esac

mkdir -p "$AGENTS" "$LOGDIR"

# Anything still nohup'd from hand-testing would fight the agents over the ports.
pkill -f 'shipmate-mcp.js --(http|onboard)' 2>/dev/null || true
sleep 1

BRIDGE="$(cd "$DIR/../voice" && pwd)/shipmate-voice.sh"

services | while IFS='|' read -r label kind mode extra; do
  plist="$AGENTS/$label.plist"
  if [ "$kind" = "server" ]; then
    prog="<string>$NODE</string><string>$SERVER</string><string>$mode</string><string>$extra</string>"
    sched="<key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>"
  else
    prog="<string>/bin/bash</string><string>$BRIDGE</string><string>$mode</string>"
    sched="<key>StartInterval</key><integer>$extra</integer>"
  fi
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>$prog</array>
  <key>RunAtLoad</key><true/>
  $sched
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOGDIR/$label.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/$label.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$plist"
  echo "✓ $label → $mode $extra (log: $LOGDIR/$label.log)"
done

echo
echo "Both agents load at login and restart on crash. Check:  launchctl list | grep shipmate"
echo "Reminder: 'tailscale funnel --bg 8788' persists on its own across reboots."
