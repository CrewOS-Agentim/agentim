#!/bin/bash
# Brings agentim back whenever it isn't running. launchd runs this at login and
# every 60 seconds (com.agentim.watchdog). Containers restart by themselves
# (restart: unless-stopped); this makes sure Docker itself is up.
set -u
ROOT="${AGENTIM_ROOT:?}"
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"

log() { echo "$(date '+%F %T') $*"; }

if ! docker info >/dev/null 2>&1; then
  log "Docker isn't running, starting Docker Desktop"
  open -ga Docker
  exit 0   # next tick brings the stack up once Docker is ready
fi

running=$(docker compose -f "$ROOT/docker-compose.yml" --project-directory "$ROOT" ps --status running --services 2>/dev/null | wc -l | tr -d ' ')
expected=$(docker compose -f "$ROOT/docker-compose.yml" --project-directory "$ROOT" config --services 2>/dev/null | wc -l | tr -d ' ')
if [ "$running" != "$expected" ]; then
  log "$running/$expected services running, starting the stack"
  docker compose -f "$ROOT/docker-compose.yml" --project-directory "$ROOT" up -d
fi
