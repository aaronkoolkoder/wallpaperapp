#!/bin/bash
# Assembles Diorama.app from the SwiftPM build product.
#
# There is no .xcodeproj in this repo by design — the project definition lives in project.yml
# (XcodeGen) for people who want to open it in Xcode, and this script covers the command-line
# and CI paths without needing one.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product Diorama
BIN="$(swift build -c "$CONFIG" --product Diorama --show-bin-path)/Diorama"

APP="$ROOT/dist/Diorama.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Diorama"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Diorama</string>
    <key>CFBundleDisplayName</key><string>Diorama</string>
    <key>CFBundleIdentifier</key><string>app.diorama.Diorama</string>
    <key>CFBundleExecutable</key><string>Diorama</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <!-- Menu bar app: no Dock icon, no default window. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "built $APP"
