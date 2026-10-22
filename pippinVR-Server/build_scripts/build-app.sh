#!/bin/bash
set -e


# Definitions of directory variables.
APP_NAME="PippinVR"
EXECUTABLE_NAME="pippinvr-server"
VERSION="${VERSION:-1.0}"
BUILD_CONFIG="${1:-release}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# pippinVR-Server root -- one level up from build_scripts/. All real
# inputs/outputs (Sources/, .build/, Resources/, PippinVR.app, the sibling
# Newt checkout) live there, not inside build_scripts/ itself.
PIPPIN_SERVER_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"
APP_DIR="${PIPPIN_SERVER_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENTITLEMENTS="${PIPPIN_SERVER_DIR}/Resources/${APP_NAME}.entitlements"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "${PIPPIN_SERVER_DIR}"

if [ -d "${APP_DIR}" ]; then
    rm -rf "${APP_DIR}"
fi

# Chain the whole Direct USB pipeline automatically so a runner only needs to
# check out submodules, have the Vulkan SDK installed, and run this one
# script -- no manual build-monado.sh/build-newt.sh/env-var discovery.
# PIPPINVR_SKIP_DIRECT=1 opts out (plain Quest Client-only build, e.g. for a
# CI matrix leg that doesn't need Direct USB at all).
if [ "${PIPPINVR_SKIP_DIRECT:-0}" != "1" ] && [ -f "${PIPPIN_SERVER_DIR}/../Newt/CMakeLists.txt" ]; then
    MONADO_VENDOR_DIR="${MONADO_VENDOR_DIR:-${PIPPIN_SERVER_DIR}/.build/monado-vendor/lib}"
    if [ ! -f "${MONADO_VENDOR_DIR}/libopenxr_monado.dylib" ]; then
        echo "No Monado vendor libs yet -- building them via build-monado.sh..."
        "${SCRIPT_DIR}/build-monado.sh"
    fi
    if [ ! -f "${PIPPIN_SERVER_DIR}/.build/newt-package/lib/libnewt_core.a" ]; then
        echo "Newt not built yet -- building it via build-newt.sh..."
        "${SCRIPT_DIR}/build-newt.sh"
    fi
elif [ "${PIPPINVR_SKIP_DIRECT:-0}" != "1" ]; then
    echo "Newt source not found at ../Newt -- building the plain Quest Client app (no Direct USB)."
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


cp "${PIPPIN_SERVER_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true

if command -v iconutil &> /dev/null; then
    ICONSET_DIR="${PIPPIN_SERVER_DIR}/AppIcon.iconset"

    if [ -d "${ICONSET_DIR}" ]; then
        iconutil -c icns -o "${RESOURCES_DIR}/AppIcon.icns" "${ICONSET_DIR}"
    else
        echo "No iconset found at ${ICONSET_DIR}"
    fi
else
    echo "Using default"
fi

if [ -f "${PIPPIN_SERVER_DIR}/pippinvr.example.json" ]; then
    cp "${PIPPIN_SERVER_DIR}/pippinvr.example.json" "${RESOURCES_DIR}/pippinvr.example.json"
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

MONADO_VENDOR_DIR="${MONADO_VENDOR_DIR:-${PIPPIN_SERVER_DIR}/.build/monado-vendor/lib}"
if [ -f "${PIPPIN_SERVER_DIR}/.build/newt-package/lib/libnewt_core.a" ] && [ -d "${MONADO_VENDOR_DIR}" ]; then
    echo "Direct USB build detected with a Monado vendor dir -- bundling the runtime..."
    MONADO_VENDOR_DIR="${MONADO_VENDOR_DIR}" "${SCRIPT_DIR}/bundle-monado-runtime.sh" "${APP_DIR}"
elif [ -f "${PIPPIN_SERVER_DIR}/.build/newt-package/lib/libnewt_core.a" ]; then
    echo "Direct USB build detected but no Monado vendor dir at ${MONADO_VENDOR_DIR} -- " \
         "run bundle-monado-runtime.sh yourself once you have one, or Direct USB won't connect."
fi

echo "Location: ${APP_DIR}"
