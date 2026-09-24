#!/bin/bash
set -e


# Definitions of directory variables.
APP_NAME="PippinVR"
EXECUTABLE_NAME="pippinvr-server"
VERSION="1.0"
BUILD_CONFIG="${1:-release}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR="${SCRIPT_DIR}/.build/${BUILD_CONFIG}"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building ${APP_NAME}.app (${BUILD_CONFIG})..."

if [ -d "${APP_DIR}" ]; then
    rm -rf "${APP_DIR}"
fi

echo "Building executable..."
swift build -c "${BUILD_CONFIG}"


mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"


cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"


cp "${SCRIPT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true

if command -v iconutil &> /dev/null; then
    ICONSET_DIR="${SCRIPT_DIR}/AppIcon.iconset"

    if [ -d "${ICONSET_DIR}" ]; then
        iconutil -c icns -o "${RESOURCES_DIR}/AppIcon.icns" "${ICONSET_DIR}"
    else
        echo "No iconset found at ${ICONSET_DIR}, app will use default icon"
    fi
else
    echo "Using default"
fi

if [ -f "${SCRIPT_DIR}/pippinvr.example.json" ]; then
    cp "${SCRIPT_DIR}/pippinvr.example.json" "${RESOURCES_DIR}/pippinvr.example.json"
fi

codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || echo "  (Warning: Code signing failed, app may not launch properly)"

echo "Location: ${APP_DIR}"
