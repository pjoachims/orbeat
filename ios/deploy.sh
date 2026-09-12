#!/bin/bash
# Build + install + launch on the iPhone (USB or Wi-Fi — devicectl picks whatever is paired/online).
set -euo pipefail
cd "$(dirname "$0")"
DEV=2DD99A0A-3BF8-57F6-8244-6EDC9FC3A7C1   # Per’s iPhone 16 Pro (xcrun devicectl list devices)
xcodebuild -project Orbeat.xcodeproj -scheme Orbeat -configuration Debug \
  -destination "id=00008140-001C78D13AC2801C" -derivedDataPath build -allowProvisioningUpdates build -quiet
xcrun devicectl device install app --device "$DEV" build/Build/Products/Debug-iphoneos/Orbeat.app
xcrun devicectl device process launch --device "$DEV" com.vibecode.orbeat.ios
