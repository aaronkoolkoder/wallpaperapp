#!/bin/bash
# Builds the drag-to-Applications installer disk image.
#
#   Scripts/make-dmg.sh [debug|release]
#
# The window layout is written directly into a .DS_Store rather than by scripting Finder. The
# AppleScript approach every other DMG recipe uses requires Automation permission, which means a
# permission prompt on a developer's machine and a hang in CI where nobody can answer it.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^## \[\([0-9.]*\)\].*/\1/p' CHANGELOG.md 2>/dev/null | head -1)"
VERSION="${VERSION:-0.1.0}"

VOLUME="Diorama"
STAGING="$ROOT/dist/dmg-staging"
DMG="$ROOT/dist/Diorama-${VERSION}.dmg"

"$ROOT/Scripts/bundle.sh" "$CONFIG"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING/.background"

cp -R "$ROOT/dist/Diorama.app" "$STAGING/Diorama.app"
ln -s /Applications "$STAGING/Applications"

if [ ! -f "$ROOT/Resources/dmg-background.png" ]; then
    swift "$ROOT/Scripts/make-dmg-background.swift" "$ROOT/Resources" >/dev/null
fi
cp "$ROOT/Resources/dmg-background.png" "$STAGING/.background/background.png"
cp "$ROOT/Resources/dmg-background@2x.png" "$STAGING/.background/background@2x.png"

# Volume icon, so the mounted disk shows the app's icon rather than a blank drive.
cp "$ROOT/Resources/Diorama.icns" "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING" 2>/dev/null || true

PY="${DMG_PYTHON:-python3}"
if "$PY" -c "import ds_store" >/dev/null 2>&1; then
    "$PY" "$ROOT/Scripts/write_dmg_layout.py" "$STAGING"
else
    echo "warning: ds_store not installed — the DMG will open with Finder's default layout."
    echo "         pip install ds_store mac_alias, or set DMG_PYTHON to an interpreter that has it."
fi

hdiutil create \
    -volname "$VOLUME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG" >/dev/null

rm -rf "$STAGING"

# Ad-hoc sign the image too, so its contents are at least tamper-evident.
codesign --force --sign - "$DMG" 2>/dev/null || true

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "built $DMG ($SIZE)"
