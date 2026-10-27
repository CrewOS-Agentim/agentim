#!/bin/bash
# Always-on agentim on Linux (systemd): starts the stack at boot, keeps the
# laptop awake with the lid closed while on external power.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

sudo tee /etc/systemd/system/agentim.service >/dev/null <<EOF
[Unit]
Description=agentim (Agent Tim's switchboard)
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ROOT
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now docker agentim

sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/agentim.conf >/dev/null <<EOF
[Login]
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
sudo systemctl kill -s HUP systemd-logind
echo "🐙 agentim starts at boot; lid-close is ignored while on external power."
