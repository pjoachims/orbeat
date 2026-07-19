#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Orbeat.app"
EXEC="Orbeat"
BUNDLE_ID="com.vibecode.orbeat"

echo "▸ Compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework Combine -framework CoreBluetooth \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$EXEC"

cp Resources/Orbeat.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Orbeat</string>
  <key>CFBundleDisplayName</key><string>Orbeat</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>Orbeat</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Orbeat reads live heart rate from a nearby Bluetooth heart-rate device.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ Built $APP"
