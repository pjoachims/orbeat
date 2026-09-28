#!/bin/bash
# Build + install + launch on an iPhone (USB or Wi-Fi).
# Usage: ios/deploy.sh [device-name-substring]   (default: first available paired iPhone)
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen -q

MATCH="${1:-}"
DEV=$(xcrun devicectl list devices 2>/dev/null \
  | awk -v m="$MATCH" '/available \(paired\)/ && /iPhone/ && index($0, m) { print $0; exit }' \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
[ -n "$DEV" ] || { echo "No available paired iPhone${MATCH:+ matching '$MATCH'}"; exit 1; }
UDID=$(xcrun devicectl device info details --device "$DEV" 2>/dev/null | awk '/udid:/ { print $2; exit }')

xcodebuild -project Orbeat.xcodeproj -scheme Orbeat -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build -allowProvisioningUpdates build -quiet
xcrun devicectl device install app --device "$DEV" build/Build/Products/Debug-iphoneos/Orbeat.app
xcrun devicectl device process launch --terminate-existing --device "$DEV" com.vibecode.orbeat.ios
