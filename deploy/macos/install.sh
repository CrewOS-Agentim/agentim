#!/bin/bash
# Makes agentim always-on on a Mac:
#   1. com.agentim.watchdog (LaunchAgent): starts Docker + the stack at login, re-checks every 60 s
#   2. com.agentim.runner   (LaunchAgent): native runner on :8766 for LTX Desktop video, restarted if it dies
#   3. com.agentim.power    (LaunchDaemon, root): no lid-close sleep while on the charger
#   4. pmset: never idle-sleep on the charger, restart automatically after a power failure
#
# usage: deploy/macos/install.sh [--no-power] [--no-runner] [--dry-run DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
DAEMONS="/Library/LaunchDaemons"
LOGS="$HOME/Library/Logs/agentim"
POWER=1 RUNNER=1 DRY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-power) POWER=0 ;;
    --no-runner) RUNNER=0 ;;
    --dry-run) DRY="$2"; AGENTS="$2/LaunchAgents"; DAEMONS="$2/LaunchDaemons"; LOGS="$2/Logs"; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done

say() { printf '🐙 %s\n' "$*"; }
mkdir -p "$AGENTS" "$LOGS"
[ -n "$DRY" ] && mkdir -p "$DAEMONS"

if [ -z "$DRY" ] && [ ! -f "$ROOT/.env" ]; then
  say "No .env yet. Copying .env.example → .env with fresh random secrets."
  cp "$ROOT/.env.example" "$ROOT/.env"
  for key in RUNNER_TOKEN AGENTIM_WEBHOOK_SECRET WAHA_API_KEY WAHA_DASHBOARD_PASSWORD; do
    sed -i '' "s/^$key=change-me/$key=$(openssl rand -hex 24)/" "$ROOT/.env"
  done
  # The WhatsApp bridge publishes Apple-silicon builds under a separate tag.
  [ "$(uname -m)" = arm64 ] && sed -i '' "s/^WAHA_TAG=.*/WAHA_TAG=arm/" "$ROOT/.env"
  say "Edit $ROOT/.env to add your Telegram/Slack tokens and allowed users."
fi
RUNNER_TOKEN=$( [ -f "$ROOT/.env" ] && grep -E '^RUNNER_TOKEN=' "$ROOT/.env" | cut -d= -f2- || echo dry-run)

plist() {  # label, program args (one per line), extra keys
  local label="$1" args="$2" extra="$3"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$(while IFS= read -r arg; do [ -n "$arg" ] && echo "    <string>$arg</string>"; done <<< "$args")
  </array>
  <key>RunAtLoad</key><true/>
$extra
</dict>
</plist>
EOF
}

load() {  # domain plist
  [ -n "$DRY" ] && return 0
  launchctl bootout "$1" "$2" 2>/dev/null || true
  launchctl bootstrap "$1" "$2"
}

# 1. Watchdog
plist com.agentim.watchdog "/bin/bash
$ROOT/deploy/macos/watchdog.sh" "  <key>StartInterval</key><integer>60</integer>
  <key>EnvironmentVariables</key><dict><key>AGENTIM_ROOT</key><string>$ROOT</string></dict>
  <key>StandardOutPath</key><string>$LOGS/watchdog.log</string>
  <key>StandardErrorPath</key><string>$LOGS/watchdog.log</string>" > "$AGENTS/com.agentim.watchdog.plist"
load "gui/$(id -u)" "$AGENTS/com.agentim.watchdog.plist"
say "Watchdog installed: Docker and the stack start at login and come back within a minute if stopped."

# 2. Native runner (LTX Desktop bridge)
if [ "$RUNNER" = 1 ]; then
  plist com.agentim.runner "/usr/bin/env
python3
$ROOT/runner/runner.py" "  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict>
    <key>RUNNER_PORT</key><string>8766</string>
    <key>RUNNER_TOKEN</key><string>$RUNNER_TOKEN</string>
    <key>RUNNER_DISABLE</key><string>ollama,lmstudio,llamacpp,vllm,docker</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOGS/runner.log</string>
  <key>StandardErrorPath</key><string>$LOGS/runner.log</string>" > "$AGENTS/com.agentim.runner.plist"
  load "gui/$(id -u)" "$AGENTS/com.agentim.runner.plist"
  say "Native runner on :8766 (LTX video) installed; it restarts if it ever stops."
fi

# 3 + 4. Power (needs root)
if [ "$POWER" = 1 ]; then
  daemon="$(plist com.agentim.power "/bin/bash
$ROOT/deploy/macos/power-guard.sh" "  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/agentim-power.log</string>
  <key>StandardErrorPath</key><string>/var/log/agentim-power.log</string>")"
  if [ -n "$DRY" ]; then
    echo "$daemon" > "$DAEMONS/com.agentim.power.plist"
  else
    say "Installing the power guard (asks for your password)…"
    echo "$daemon" | sudo tee "$DAEMONS/com.agentim.power.plist" >/dev/null
    sudo chown root:wheel "$DAEMONS/com.agentim.power.plist"
    sudo chmod 644 "$DAEMONS/com.agentim.power.plist"
    sudo launchctl bootout system "$DAEMONS/com.agentim.power.plist" 2>/dev/null || true
    sudo launchctl bootstrap system "$DAEMONS/com.agentim.power.plist"
    sudo pmset -c sleep 0 tcpkeepalive 1 womp 1   # on the charger: never idle-sleep, stay reachable
    sudo pmset -a autorestart 1                    # boot again after a power failure
    say "Power guard on: lid closed + charger = stays awake; on battery it sleeps normally."
  fi
fi

say "Done. Logs: $LOGS"
say "After a reboot everything starts when you log in. For hands-free reboots enable automatic login"
say "(System Settings → Users & Groups; requires FileVault off), or just log in once."
