#!/bin/sh
# Link this checkout into herdr as a local plugin and seed its config.
#
#   sh install.sh              build + link + seed config
#   sh install.sh --no-build   link + seed only (use an existing bin/taptic)
#
# Safe to re-run: linking is idempotent and an existing config is never
# overwritten.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_ID=$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/herdr-plugin.toml" | head -1)
PLUGIN_ID=${PLUGIN_ID:-haptic-notify}
CONFIG_DIR="$HOME/.config/herdr/plugins/config/$PLUGIN_ID"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only (the Taptic Engine is Apple hardware)"
command -v herdr >/dev/null 2>&1 || die "herdr not found on PATH"
command -v node >/dev/null 2>&1 || die "node (>=18) not found on PATH"

case "${1:-}" in
  --no-build) log "skipping build" ;;
  *) sh "$ROOT/scripts/build-taptic.sh" ;;
esac

if [ ! -d "$CONFIG_DIR" ]; then
  mkdir -p "$CONFIG_DIR"
fi
if [ -f "$CONFIG_DIR/config.json" ]; then
  log "keeping existing config: $CONFIG_DIR/config.json"
else
  cp "$ROOT/config.example.json" "$CONFIG_DIR/config.json"
  log "seeded config: $CONFIG_DIR/config.json"
fi

log "linking $ROOT into herdr"
herdr plugin link "$ROOT" >/dev/null

log "linked plugin '$PLUGIN_ID'"
log ""
log "next steps:"
log "  1. herdr plugin action invoke test-done --plugin $PLUGIN_ID   # feel the pattern"
log "  2. node lab/server.mjs --open                                 # audition patterns"
log "  3. sh scripts/tail-log.sh                                     # watch real events"
