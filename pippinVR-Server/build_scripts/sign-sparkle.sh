#!/bin/bash
set -euo pipefail
FRAMEWORK="$1/Contents/Frameworks/Sparkle.framework"
[ -d "$FRAMEWORK" ] || exit 0
SIGN=(--force --sign "${CODESIGN_IDENTITY:--}")
if [ "${CODESIGN_IDENTITY:--}" != "-" ]; then
    SIGN+=(--options runtime --timestamp)
fi
# Sign inside out; only the downloader keeps its sandbox entitlements.
for item in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    TARGET="$FRAMEWORK/Versions/Current/$item"
    [ -e "$TARGET" ] || continue
    if [ "$item" = XPCServices/Downloader.xpc ]; then
        codesign "${SIGN[@]}" --preserve-metadata=entitlements "$TARGET"
    else
        codesign "${SIGN[@]}" "$TARGET"
    fi
done
codesign "${SIGN[@]}" "$FRAMEWORK"
codesign --verify --deep --strict "$FRAMEWORK"
