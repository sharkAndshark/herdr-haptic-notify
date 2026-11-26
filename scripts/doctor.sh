#!/bin/sh
# Diagnostics for "I installed it and nothing vibrates".
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/lucas.haptic-notify}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr/plugins/lucas.haptic-notify}"

ok() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; }

echo "haptic-notify doctor"
echo
echo "1. host"
if [ "$(uname -s)" = "Darwin" ]; then ok "macOS $(sw_vers -productVersion)"; else bad "not macOS — the plugin only works on Apple hardware"; fi

if command -v node >/dev/null 2>&1; then
  ok "node $(node -v) (hook + lab)"
else
  bad "node not found — the hook cannot run (needs Node >= 18)"
fi

if command -v herdr >/dev/null 2>&1; then
  ok "herdr $(herdr --version 2>/dev/null | awk '{print $2}')"
else
  bad "herdr not on PATH — the plugin is invoked by herdr"
fi

echo
echo "2. trackpad / haptic hardware"
if [ "$(uname -s)" = "Darwin" ]; then
  if ioreg -c AppleMultitouchDevice -r 2>/dev/null | grep -q '"ActuationSupported" = Yes'; then
    ok "Force Touch trackpad with actuation support"
  else
    warn "no actuation-capable trackpad found (Magic Trackpad 2 also works)"
  fi
  detents=$(defaults read com.apple.AppleMultitouchTrackpad ActuateDetents 2>/dev/null || echo 1)
  suppressed=$(defaults read com.apple.AppleMultitouchTrackpad ForceSuppressed 2>/dev/null || echo 0)
  if [ "$detents" = "0" ] || [ "$suppressed" = "1" ]; then
    bad "haptics disabled in System Settings → Trackpad (ActuateDetents=$detents ForceSuppressed=$suppressed)"
  else
    ok "haptics enabled in System Settings"
  fi
fi

echo
echo "3. helper binary"
BIN="${HAPTIC_TAPTIC:-$ROOT/bin/taptic}"
if [ -x "$BIN" ]; then
  ok "$BIN ($(file -b "$BIN" | cut -d, -f1))"
  if "$BIN" --help >/dev/null 2>&1; then
    ok "helper runs"
  else
    bad "helper is not executable — rerun the build step: sh scripts/build-taptic.sh"
  fi
else
  bad "missing helper at $BIN — run: sh scripts/build-taptic.sh"
fi

echo
echo "4. config"
CONFIG="$CONFIG_DIR/config.json"
if [ -f "$CONFIG" ]; then
  ok "$CONFIG"
  node -e '
    const c = require(process.argv[1]);
    const statuses = Object.keys(c.statuses ?? {});
    console.log("        statuses: " + (statuses.length ? statuses.map(s =>
      s + "(" + (c.statuses[s].label ?? "?") + ")").join(", ") : "NONE — nothing will ever fire"));
    if (!c.statuses || Object.keys(c.statuses).length === 0) process.exitCode = 3;
    const safety = c.safety ?? {};
    console.log("        safety: maxIntensity=" + (safety.maxIntensity ?? "off") +
      " maxTotalMs=" + (safety.maxTotalMs ?? "off") +
      " minGapMs=" + (safety.minGapMs ?? "off"));
  ' "$CONFIG" || warn "no notify-worthy statuses configured — add done/blocked/idle"
else
  ok "no config file — built-in defaults are active"
  echo "        statuses: done(m1), blocked(m1), idle(m1)   [m1 = the default chime]"
  echo "        safety: maxIntensity=1.6 maxTotalMs=800 minGapMs=2000"
fi

echo
echo "5. last decisions"
LOG="$STATE_DIR/haptic-notify.log"
if [ -f "$LOG" ]; then
  ok "$LOG"
  tail -n 8 "$LOG" | sed 's/^/        /'
else
  warn "no log yet at $LOG — no agent status change has happened since install"
fi

echo
echo "next: herdr plugin action invoke test-done --plugin lucas.haptic-notify"
