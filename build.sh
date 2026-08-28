#!/bin/bash
# Builds BluetoothTool.app. No Xcode required — SwiftPM produces the binary and
# we assemble the bundle by hand, then ad-hoc sign it so macOS will run it.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/BluetoothTool.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/BluetoothTool"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/BluetoothTool"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>BluetoothTool</string>
    <key>CFBundleDisplayName</key>           <string>Multi-Speaker</string>
    <key>CFBundleIdentifier</key>            <string>com.bluetoothtool.app</string>
    <key>CFBundleExecutable</key>            <string>BluetoothTool</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>                   <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>BluetoothTool connects your paired speakers and headphones so it can play to all of them at once.</string>
    <!-- Reading now-playing and driving transport controls in Spotify. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Multi-Speaker shows what Spotify is playing and lets you skip or pause it from the menu bar and the remote page.</string>
    <!-- Permits plain HTTP to loopback and .local only, so `supabase start`
         works for local testing. Real Supabase projects are HTTPS and are
         still held to full ATS. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>          <true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo
echo "Built $APP"
echo "Run it with:  open '$PWD/$APP'"
