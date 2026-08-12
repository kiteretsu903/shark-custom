#!/bin/bash
# Build FunCooler.app — a signed menu bar app bundle with a Bluetooth usage
# description, so macOS shows a normal permission prompt instead of aborting.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FunCooler.app"
BIN="$APP/Contents/MacOS/FunCooler"

echo "Compiling…"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework CoreBluetooth \
  -o "$BIN" \
  Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>FunCooler</string>
    <key>CFBundleDisplayName</key>     <string>FunCooler</string>
    <key>CFBundleIdentifier</key>      <string>local.funcooler.control</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>FunCooler</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>FunCooler needs Bluetooth to discover and control your Black Shark cooler.</string>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP"
