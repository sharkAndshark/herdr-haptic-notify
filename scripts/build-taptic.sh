#!/bin/sh
# Build (or fetch) the `taptic` helper that drives the Taptic Engine.
#
# Order of preference:
#   1. Prebuilt release asset for this architecture — no Xcode needed.
#      The published `<asset>.sha256` is verified before the binary is run.
#   2. Compile tools/taptic/taptic.swift with swiftc (Xcode Command Line Tools).
#
# Env:
#   HAPTIC_SKIP_DOWNLOAD=1     skip 1, always build from source
#   HAPTIC_REPO=owner/repo     override the release source (default: git origin)
#   HAPTIC_RELEASE_BASE=<url>  override the release download base (implies no gh)
#
# Output: <plugin>/bin/taptic
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/tools/taptic/taptic.swift"
OUT_DIR="$ROOT/bin"
OUT="$OUT_DIR/taptic"

ARCH=$(uname -m)
case "$ARCH" in
  arm64) ASSET_ARCH="arm64" ;;
  x86_64) ASSET_ARCH="x86_64" ;;
  *) ASSET_ARCH="$ARCH" ;;
esac

log() { printf '[build-taptic] %s\n' "$*" >&2; }
warn() { printf '[build-taptic] warning: %s\n' "$*" >&2; }

# Verify a downloaded binary against its published checksum file.
# Missing checksum file: warn and continue (older releases).
# Mismatch: hard failure — never run an unverified binary.
verify_checksum() {
  file=$1
  sumfile=$2
  if [ ! -s "$sumfile" ]; then
    warn "no checksum published for $(basename "$file"); skipping verification"
    return 0
  fi
  expected=$(awk 'NF {print $1; exit}' "$sumfile")
  actual=$(shasum -a 256 "$file" | awk '{print $1}')
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    printf '[build-taptic] CHECKSUM MISMATCH for %s\n  expected %s\n  actual   %s\n' \
      "$(basename "$file")" "${expected:-<empty>}" "$actual" >&2
    return 1
  fi
  log "checksum ok: $(basename "$file")"
  return 0
}

if [ "$(uname -s)" != "Darwin" ]; then
  log "this plugin is macOS only (found $(uname -s)); nothing to build"
  exit 0
fi

# Already built and newer than the source? Keep it.
if [ "${HAPTIC_SKIP_DOWNLOAD:-0}" = "1" ]; then
  log "HAPTIC_SKIP_DOWNLOAD=1 — building from source"
fi

if [ -x "$OUT" ] && [ "$OUT" -nt "$SRC" ] && [ "${HAPTIC_SKIP_DOWNLOAD:-0}" != "1" ]; then
  log "up to date: $OUT"
  exit 0
fi

mkdir -p "$OUT_DIR"

compile() {
  if ! command -v swiftc >/dev/null 2>&1; then
    return 1
  fi
  log "compiling $SRC"
  swiftc -O -o "$OUT" "$SRC"
  log "built $OUT"
  return 0
}

repo_slug() {
  if [ -n "${HAPTIC_REPO:-}" ]; then
    printf '%s' "$HAPTIC_REPO"
    return 0
  fi
  command -v git >/dev/null 2>&1 || return 1
  remote=$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$remote" ] || return 1
  printf '%s' "$remote" | sed -e 's#^git@github.com:##' -e 's#^https://github.com/##' -e 's#\.git$##'
}

download_prebuilt() {
  explicit_base=1
  if [ -z "${HAPTIC_RELEASE_BASE:-}" ]; then
    explicit_base=0
    slug=$(repo_slug) || return 1
    HAPTIC_RELEASE_BASE="https://github.com/$slug/releases/latest/download"
  fi
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  asset="taptic-macos-$ASSET_ARCH"
  url="$HAPTIC_RELEASE_BASE/$asset"
  tmp="$OUT.download"

  # A private repo's release assets need credentials; `gh` already has them.
  if [ "$explicit_base" -eq 0 ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    log "downloading $asset with gh"
    if gh release download --repo "$(repo_slug)" --pattern "$asset" --output "$tmp" --clobber >/dev/null 2>&1; then
      rm -f "$tmp.sha256"
      gh release download --repo "$(repo_slug)" --pattern "$asset.sha256" --output "$tmp.sha256" --clobber >/dev/null 2>&1 || true
      if ! verify_checksum "$tmp" "$tmp.sha256"; then
        rm -f "$tmp" "$tmp.sha256"
        return 2
      fi
      chmod +x "$tmp"
      command -v codesign >/dev/null 2>&1 && codesign --force --sign - "$tmp" >/dev/null 2>&1 || true
      mv "$tmp" "$OUT"
      rm -f "$tmp.sha256"
      log "installed prebuilt $OUT"
      return 0
    fi
    rm -f "$tmp"
  fi

  log "downloading $url"
  if ! curl -fsSL --http1.1 --retry 2 ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} -o "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi

  rm -f "$tmp.sha256"
  curl -fsSL --http1.1 --retry 2 ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} -o "$tmp.sha256" "$url.sha256" || rm -f "$tmp.sha256"
  if ! verify_checksum "$tmp" "$tmp.sha256"; then
    rm -f "$tmp" "$tmp.sha256"
    return 2
  fi
  rm -f "$tmp.sha256"
  chmod +x "$tmp"
  # Gatekeeper: an unsigned arm64 binary will not run at all.
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$tmp" >/dev/null 2>&1 || true
  fi
  mv "$tmp" "$OUT"
  log "installed prebuilt $OUT"
  return 0
}

if [ "${HAPTIC_SKIP_DOWNLOAD:-0}" = "1" ]; then
  compile || exit 1
  exit 0
fi

rc=0
download_prebuilt || rc=$?
case "$rc" in
  0) exit 0 ;;
  2)
    cat >&2 <<'EOF'
[build-taptic] refusing to continue: the downloaded binary does not match its
published checksum. Nothing was installed and no fallback build was run.

Inspect the release and retry, or build the auditable Swift source instead:
  HAPTIC_SKIP_DOWNLOAD=1 sh scripts/build-taptic.sh
EOF
    exit 1 ;;
esac

if compile; then
  exit 0
fi

cat >&2 <<'EOF'
[build-taptic] could not build the haptic helper.

Pick one:
  * install Xcode Command Line Tools:  xcode-select --install
  * or point HAPTIC_REPO / HAPTIC_RELEASE_BASE at a release that ships
    taptic-macos-<arch> binaries, e.g.
      HAPTIC_REPO=you/herdr-haptic-notify sh scripts/build-taptic.sh

Everything else in the plugin (event parsing, safety budget) works without the
helper; you simply get no vibration until it is built.
EOF
exit 1
