#!/bin/bash
# Build the Mac app into ./Orbeat.app (xcodebuild, automatic signing — the
# stable Apple Development identity keeps Bluetooth/iCloud grants across builds).
set -euo pipefail
cd "$(dirname "$0")"

xcodegen -q
echo "▸ Building Orbeat (macOS)…"
xcodebuild -project Orbeat.xcodeproj -scheme OrbeatMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates build -quiet
rm -rf Orbeat.app
cp -R build/Build/Products/Release/Orbeat.app .
echo "✓ Built Orbeat.app"
