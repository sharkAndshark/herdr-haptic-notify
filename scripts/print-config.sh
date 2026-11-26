#!/bin/sh
# Print the effective plugin config and where it lives.
set -eu
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/lucas.haptic-notify}"
CONFIG="$CONFIG_DIR/config.json"

echo "# config: $CONFIG"
if [ ! -f "$CONFIG" ]; then
  echo "(missing — the plugin falls back to config.example.json defaults until a"
  echo " config appears; copy it with:  cp \"$(dirname -- "$0")/../config.example.json\" \"$CONFIG\")"
  exit 0
fi
cat "$CONFIG"
echo
echo "# quick reference"
echo "#   done/blocked/idle sequence: onMs,offMs[,waveform,intensity,frequency];..."
echo "#   waveform 1 back 2 click 3 weak buzz 4 light tap 5 medium tap 6 strong tap 15/16 low thud"
echo "#   after editing, the next event picks it up — no reload needed"
