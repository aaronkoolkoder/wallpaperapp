#!/bin/bash
# Build and install straight into /Applications.
#
#   Scripts/install.sh [release|debug]
#
# This is the path to use on your own machine. Gatekeeper's warning comes from the quarantine
# attribute a browser attaches to downloads — an app built locally and copied into place never
# carries it, so there is nothing to click through. The DMG is for handing to other people.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/Scripts/bundle.sh" "$CONFIG"

DEST="/Applications/Diorama.app"

# Quit a running copy first; replacing a bundle underneath a live process leaves it in a state
# where the app is running code that no longer exists on disk.
if pgrep -x Diorama >/dev/null 2>&1; then
    echo "quitting the running copy…"
    osascript -e 'tell application id "app.diorama.Diorama" to quit' 2>/dev/null || pkill -x Diorama
    for _ in $(seq 1 20); do
        pgrep -x Diorama >/dev/null 2>&1 || break
        sleep 0.25
    done
fi

rm -rf "$DEST"
cp -R "$ROOT/dist/Diorama.app" "$DEST"

# Belt and braces: clear quarantine in case the bundle picked it up from an intermediate step.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "installed $DEST"
echo "open it with:  open -a Diorama"
