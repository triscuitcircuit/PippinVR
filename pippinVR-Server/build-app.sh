#!/bin/bash
set -e


# Definitions of directory variables.
APP_NAME="PippinVR"
EXECUTABLE_NAME="pippinvr-server"
VERSION="${VERSION:-1.0}"
BUILD_CONFIG="${1:-release}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENTITLEMENTS="${SCRIPT_DIR}/Resources/${APP_NAME}.entitlements"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [ -d "${APP_DIR}" ]; then
    rm -rf "${APP_DIR}"
fi
BUILD_ARGS=(-c "${BUILD_CONFIG}")
if [ "${UNIVERSAL:-0}" = "1" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}"

BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"


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
        echo "No iconset found at ${ICONSET_DIR}"
    fi
else
    echo "Using default"
fi

if [ -f "${SCRIPT_DIR}/pippinvr.example.json" ]; then
    cp "${SCRIPT_DIR}/pippinvr.example.json" "${RESOURCES_DIR}/pippinvr.example.json"
fi

if [ "${CODESIGN_IDENTITY}" = "-" ]; then
    echo "Signing ad-hoc"
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" \
        "${MACOS_DIR}/${EXECUTABLE_NAME}" 2>/dev/null \
        || echo "Code signing failed"
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP_DIR}" 2>/dev/null \
        || echo "Code signing failed"
else
    codesign --force --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${CODESIGN_IDENTITY}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
    codesign --force --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${CODESIGN_IDENTITY}" "${APP_DIR}"
    codesign --verify --strict --verbose=2 "${APP_DIR}"
fi

echo "Location: ${APP_DIR}"
