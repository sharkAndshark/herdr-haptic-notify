#!/bin/sh
# Print the tail of the plugin log for the current herdr session.
set -eu

STATE="${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr/plugins/lucas.haptic-notify}"
LOG="$STATE/haptic-notify.log"

if [ ! -f "$LOG" ]; then
  echo "no log yet at $LOG"
  echo "the plugin writes its first line after the next agent status change."
  exit 0
fi

echo "# $LOG"
tail -n "${1:-40}" "$LOG"
