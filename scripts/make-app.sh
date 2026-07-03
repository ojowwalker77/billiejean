#!/bin/bash
# Assembles billiejean.app from the release build.
# Usage: scripts/make-app.sh   (from anywhere; operates on the repo root)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building release..."
swift build -c release

if [ ! -f scripts/AppIcon.icns ]; then
  echo "Generating app icon..."
  swift scripts/make-icon.swift
fi

APP=dist/billiejean.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/VinylfyStudio "$APP/Contents/MacOS/billiejean"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: gives the bundle a stable identity so TCC permissions
# (System Audio Recording, Automation) stick to the app across rebuilds.
codesign --force -s - "$APP"

echo "Built $APP"
echo "First launch: right-click the app > Open (unsigned build), then grant the"
echo "System Audio Recording and Music automation prompts once."
