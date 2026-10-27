#!/bin/bash
# Keeps the Mac awake with the lid closed, but only while it's on the charger.
# Runs as root from the com.agentim.power LaunchDaemon. On battery it restores
# normal sleep so a closed laptop in a bag doesn't cook itself.
#
#   power-guard.sh             watch forever (the daemon)
#   power-guard.sh decide TXT  print 1 (disable sleep) or 0 for `pmset -g ps` output TXT (used by tests)
set -u

decide() {
  case "$1" in
    *"'AC Power'"*) echo 1 ;;
    *) echo 0 ;;
  esac
}

current() {
  # pmset omits SleepDisabled when it's off.
  pmset -g | awk '/SleepDisabled/ {print $2; found=1} END {if (!found) print 0}'
}

if [ "${1:-}" = "decide" ]; then
  decide "${2:-}"
  exit 0
fi

while true; do
  want=$(decide "$(pmset -g ps)")
  if [ "$(current)" != "$want" ]; then
    pmset -a disablesleep "$want"
    echo "$(date '+%F %T') on $( [ "$want" = 1 ] && echo AC: lid-close sleep disabled || echo battery: normal sleep restored)"
  fi
  sleep "${AGENTIM_POWER_INTERVAL:-15}"
done
