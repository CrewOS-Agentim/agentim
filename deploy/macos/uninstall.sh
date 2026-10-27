#!/bin/bash
# Removes the agentim launch agents/daemon and restores normal sleep. Leaves Docker data alone.
set -u
for label in com.agentim.watchdog com.agentim.runner; do
  launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
if [ -f /Library/LaunchDaemons/com.agentim.power.plist ]; then
  sudo launchctl bootout system /Library/LaunchDaemons/com.agentim.power.plist 2>/dev/null
  sudo rm -f /Library/LaunchDaemons/com.agentim.power.plist
  sudo pmset -a disablesleep 0
fi
echo "🐙 agentim's always-on helpers are gone; normal sleep restored. (docker compose down to stop the stack.)"
