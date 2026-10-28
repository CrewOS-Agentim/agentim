#!/bin/bash
# Gives ChatGPT a way in: starts a Cloudflare quick tunnel to the gateway and prints the connector URL.
#   ./deploy/macos/connect-chatgpt.sh          # start (or show) the tunnel
#   ./deploy/macos/connect-chatgpt.sh stop     # close it
# Then in ChatGPT: Settings → Apps & Connectors → Advanced → Developer mode, Create connector,
# paste the URL, Authentication: none. Anyone with the URL can use your agentim, so keep it private.
set -euo pipefail
ROOT="${AGENTIM_STACK:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
ENV="$ROOT/.env"
[ -f "$ENV" ] || { echo "No .env in $ROOT. Run the agentim onboarding (or install.sh) first." >&2; exit 1; }

if [ "${1:-}" = "stop" ]; then
  docker compose --profile chatgpt stop tunnel >/dev/null 2>&1 || true
  docker compose --profile chatgpt rm -f tunnel >/dev/null 2>&1 || true
  echo "ChatGPT tunnel closed."
  exit 0
fi

# A long random secret is the only key to the public URL.
secret=$(grep -E '^AGENTIM_MCP_SECRET=' "$ENV" | cut -d= -f2- || true)
if [ "${#secret}" -lt 16 ]; then
  secret=$(openssl rand -hex 24)
  if grep -qE '^AGENTIM_MCP_SECRET=' "$ENV"; then
    sed -i '' "s/^AGENTIM_MCP_SECRET=.*/AGENTIM_MCP_SECRET=$secret/" "$ENV"
  else
    printf '\n# ChatGPT connector: the secret part of the /mcp/<secret> URL.\nAGENTIM_MCP_SECRET=%s\n' "$secret" >> "$ENV"
  fi
  docker compose up -d --no-deps gateway >/dev/null 2>&1   # picks up the new secret
fi

docker compose --profile chatgpt up -d --no-deps tunnel >/dev/null 2>&1
url=""
for _ in $(seq 1 45); do
  url=$(docker compose --profile chatgpt logs tunnel 2>/dev/null | grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
  [ -n "$url" ] && break
  sleep 2
done
[ -n "$url" ] || { echo "The tunnel didn't come up. Check: docker compose --profile chatgpt logs tunnel" >&2; exit 1; }
echo "$url/mcp/$secret"
