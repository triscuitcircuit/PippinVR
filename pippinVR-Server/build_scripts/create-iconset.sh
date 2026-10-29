#!/bin/bash
# Create macOS iconset from PNG source

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PIPPIN_SERVER_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"
SOURCE_PNG="${PIPPIN_SERVER_DIR}/Sources/pippinvr-server/Resources/app-icon.png"
ICONSET_DIR="${PIPPIN_SERVER_DIR}/AppIcon.iconset"

echo "Creating AppIcon.iconset from app-icon.png..."

# Check if source exists
if [ ! -f "${SOURCE_PNG}" ]; then
    echo "Error: ${SOURCE_PNG} not found"
    exit 1
fi

# Remove old iconset if exists
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

# Generate all required sizes using sips (built-in macOS tool)
echo "Generating icon sizes..."

# 16x16
sips -z 16 16 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_16x16.png" > /dev/null
sips -z 32 32 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_16x16@2x.png" > /dev/null

# 32x32
sips -z 32 32 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_32x32.png" > /dev/null
sips -z 64 64 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_32x32@2x.png" > /dev/null

# 128x128
sips -z 128 128 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_128x128.png" > /dev/null
sips -z 256 256 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" > /dev/null

# 256x256
sips -z 256 256 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_256x256.png" > /dev/null
sips -z 512 512 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" > /dev/null

# 512x512
sips -z 512 512 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_512x512.png" > /dev/null
sips -z 1024 1024 "${SOURCE_PNG}" --out "${ICONSET_DIR}/icon_512x512@2x.png" > /dev/null

echo "✓ Iconset created: ${ICONSET_DIR}"
echo ""
echo "Files created:"
ls -lh "${ICONSET_DIR}"
echo ""
echo "To convert to .icns, the build script will run:"
echo "  iconutil -c icns ${ICONSET_DIR}"
