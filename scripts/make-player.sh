#!/bin/bash
# Assembles billiejean-player.app from the release helper build.
# Usage: scripts/make-player.sh   (from anywhere; operates on the repo root)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building release..."
if ! swift build -c release; then
  echo "Plain swift build failed; retrying with a local clang module cache and SwiftPM subprocess sandbox disabled..."
  export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/player-helper-clang-module-cache}"
  mkdir -p "$CLANG_MODULE_CACHE_PATH"
  swift build -c release --disable-sandbox
fi

APP=dist/billiejean-player.app
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/VinylfyPlayerHelper "$APP/Contents/MacOS/billiejean-player"
cp scripts/PlayerInfo.plist "$APP/Contents/Info.plist"

if [ "${PROVISION_PROFILE:-}" != "" ] && [ -f "$PROVISION_PROFILE" ]; then
  cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

CODESIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "${ENTITLEMENTS:-}" != "" ] && [ -f "$ENTITLEMENTS" ]; then
  CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi

codesign "${CODESIGN_ARGS[@]}" "$APP"

echo "Built $APP"
echo "Signing identity: $SIGN_IDENTITY"
echo "Next steps:"
echo "  SIGN_IDENTITY='Developer ID Application: ...' scripts/make-player.sh"
echo "  PROVISION_PROFILE=/path/to/profile.provisionprofile ENTITLEMENTS=/path/to/entitlements.plist scripts/make-player.sh"
echo "  open $APP --args 'Billie Jean Michael Jackson'"
