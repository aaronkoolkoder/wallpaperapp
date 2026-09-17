#!/bin/bash
# Assembles Diorama.app from the SwiftPM build product.
#
# There is no .xcodeproj in this repo by design — this covers the command-line and CI paths
# without needing one.
#
#   Scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^## \[\([0-9.]*\)\].*/\1/p' CHANGELOG.md 2>/dev/null | head -1)"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c "$CONFIG" --product Diorama
BIN="$(swift build -c "$CONFIG" --product Diorama --show-bin-path)/Diorama"

APP="$ROOT/dist/Diorama.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Diorama"

# Regenerate the icon if it is missing, so a fresh clone builds a complete app.
if [ ! -f "$ROOT/Resources/Diorama.icns" ]; then
    swift "$ROOT/Scripts/make-icon.swift" "$ROOT/Resources" >/dev/null
    iconutil -c icns "$ROOT/Resources/Diorama.iconset" -o "$ROOT/Resources/Diorama.icns"
fi
cp "$ROOT/Resources/Diorama.icns" "$APP/Contents/Resources/Diorama.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Diorama</string>
    <key>CFBundleDisplayName</key><string>Diorama</string>
    <key>CFBundleIdentifier</key><string>app.diorama.Diorama</string>
    <key>CFBundleExecutable</key><string>Diorama</string>
    <key>CFBundleIconFile</key><string>Diorama</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Aaron Merchant</string>
    <!-- Not LSUIElement: the app manages its own activation policy at runtime, showing a Dock
         icon while a window is open and dropping to menu-bar-only when none is. Declaring
         LSUIElement here would pin it to accessory and break that. -->
</dict>
</plist>
PLIST

# Ad-hoc signature. Not a substitute for Developer ID — Gatekeeper still warns on download —
# but an unsigned bundle is refused outright on Apple Silicon, so this is the minimum that runs.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built $APP (${CONFIG}, v${VERSION} build ${BUILD})"
