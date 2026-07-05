#!/bin/bash
# Build Sauron.app (a proper double-clickable bundle) without Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product SauronApp
./scripts/make_icns.sh .build/Sauron.icns

APP="Sauron.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SauronApp "$APP/Contents/MacOS/Sauron"
cp .build/Sauron.icns "$APP/Contents/Resources/Sauron.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Sauron</string>
    <key>CFBundleIdentifier</key>
    <string>com.joshv.sauron</string>
    <key>CFBundleName</key>
    <string>Sauron</string>
    <key>CFBundleDisplayName</key>
    <string>Sauron</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>Sauron</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Sauron asks Finder to empty the Trash.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP — open with: open $APP"
