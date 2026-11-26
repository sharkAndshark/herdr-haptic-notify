#!/bin/sh
# Start the Haptic Lab UI and open it in the browser.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec node "$ROOT/lab/server.mjs" --open "$@"
