#!/bin/bash
# Provenance and malware check for anything pulled into this project.
#
# Run this on every downloaded archive, binary, or vendored source tree BEFORE using it.
# Source dependencies (glslang, SPIRV-Cross) are pinned by commit SHA, which is the real
# integrity control; the AV scan is defence in depth.
#
# Usage: Scripts/verify-dependency.sh <path> [expected-sha256]
set -uo pipefail

TARGET="${1:?usage: verify-dependency.sh <path> [expected-sha256]}"
EXPECTED="${2:-}"
FAIL=0

echo "=== verifying: $TARGET ==="

if [ ! -e "$TARGET" ]; then echo "FAIL: does not exist"; exit 1; fi

# 1. Checksum against the expected value, when one is known.
echo "--- sha256 ---"
if [ -f "$TARGET" ]; then
    ACTUAL=$(shasum -a 256 "$TARGET" | awk '{print $1}')
    echo "  $ACTUAL"
    if [ -n "$EXPECTED" ]; then
        if [ "$ACTUAL" = "$EXPECTED" ]; then
            echo "  OK: matches expected"
        else
            echo "  FAIL: expected $EXPECTED"
            FAIL=1
        fi
    else
        echo "  (no expected value given — record this in THIRD_PARTY.md)"
    fi
fi

# 2. Quarantine. A file still carrying com.apple.quarantine came from a browser or an
#    untrusted download and has not been vetted by anything.
echo "--- quarantine ---"
if xattr "$TARGET" 2>/dev/null | grep -q 'com.apple.quarantine'; then
    echo "  WARNING: still quarantined — inspect before clearing"
    FAIL=1
else
    echo "  OK: not quarantined"
fi

# 3. Signature, for Mach-O binaries only. Homebrew binaries are ad-hoc/linker-signed and will
#    show as 'rejected' by spctl; that is expected and is not by itself a finding.
if file "$TARGET" 2>/dev/null | grep -q 'Mach-O'; then
    echo "--- code signature ---"
    codesign -dv --verbose=2 "$TARGET" 2>&1 | grep -E 'Authority|TeamIdentifier|Signature|flags' | sed 's/^/  /'
fi

# 4. Malware scan, if ClamAV is present.
echo "--- malware scan ---"
if command -v clamscan >/dev/null 2>&1; then
    clamscan -r --infected --no-summary "$TARGET" 2>&1 | sed 's/^/  /'
    RC=${PIPESTATUS[0]}
    case $RC in
        0) echo "  OK: no threats found" ;;
        1) echo "  FAIL: THREAT DETECTED"; FAIL=1 ;;
        *) echo "  WARNING: scanner error (rc=$RC)" ;;
    esac
else
    echo "  SKIPPED: clamscan not installed (brew install clamav)"
fi

echo "=== result: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL) ==="
exit $FAIL
