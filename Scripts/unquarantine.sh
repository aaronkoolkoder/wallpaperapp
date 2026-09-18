#!/bin/bash
# Clears the quarantine flag from an installed copy.
#
#   Scripts/unquarantine.sh [/Applications/Diorama.app]
#
# For when the app came from a download rather than a local build. This is the same thing
# right-click → Open does, without the dialog.
set -euo pipefail

TARGET="${1:-/Applications/Diorama.app}"
if [ ! -d "$TARGET" ]; then
    echo "not found: $TARGET" >&2
    exit 1
fi

xattr -dr com.apple.quarantine "$TARGET"
echo "cleared quarantine on $TARGET"
