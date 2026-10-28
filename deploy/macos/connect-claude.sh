#!/bin/bash
# Adds agentim to Claude Desktop (as a local MCP server) and to Claude Code if it's installed.
#   ./deploy/macos/connect-claude.sh            # connect
#   ./deploy/macos/connect-claude.sh remove     # disconnect
# Restart Claude Desktop afterwards. Nothing leaves your Mac: Claude talks to the gateway on localhost.
set -euo pipefail
ROOT="${AGENTIM_STACK:-$(cd "$(dirname "$0")/../.." && pwd)}"
BRIDGE="$ROOT/deploy/mcp/agentim_mcp.py"
CONFIG="${CLAUDE_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"
ACTION="${1:-add}"
[ -f "$BRIDGE" ] || { echo "Missing $BRIDGE" >&2; exit 1; }

mkdir -p "$(dirname "$CONFIG")"
[ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.agentim-backup"
/usr/bin/python3 - "$CONFIG" "$BRIDGE" "$ACTION" <<'EOF'
import json, os, sys
path, bridge, action = sys.argv[1:4]
try:
    config = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
except ValueError:
    sys.exit(f"{path} isn't valid JSON; fix it (a backup is next to it) and try again.")
servers = config.setdefault("mcpServers", {})
if action == "remove":
    servers.pop("agentim", None)
else:
    servers["agentim"] = {"command": "/usr/bin/python3", "args": [bridge]}
json.dump(config, open(path, "w"), indent=2)
EOF
if [ "$ACTION" = "remove" ]; then
  echo "Removed agentim from Claude Desktop."
  command -v claude >/dev/null && claude mcp remove agentim -s user >/dev/null 2>&1 || true
  exit 0
fi
echo "Added agentim to Claude Desktop ($CONFIG). Restart Claude to load it."
if command -v claude >/dev/null; then
  claude mcp remove agentim -s user >/dev/null 2>&1 || true
  claude mcp add agentim -s user -- /usr/bin/python3 "$BRIDGE" >/dev/null && echo "Added agentim to Claude Code."
fi
