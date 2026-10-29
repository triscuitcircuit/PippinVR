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
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "${PIPPIN_SERVER_DIR}/.." rev-list --count HEAD 2>/dev/null || echo 1)}"
APP_DIR="${PIPPIN_SERVER_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENTITLEMENTS="${PIPPIN_SERVER_DIR}/Resources/${APP_NAME}.entitlements"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

cd "${PIPPIN_SERVER_DIR}"

# Chain the whole Direct USB pipeline automatically so a runner only needs to
# check out submodules, have the Vulkan SDK installed, and run this one
# script -- no manual build-monado.sh/build-newt.sh/env-var discovery.
# PIPPINVR_SKIP_DIRECT=1 opts out (plain Quest Client-only build, e.g. for a
# CI matrix leg that doesn't need Direct USB at all).
if [ "${PIPPINVR_SKIP_DIRECT:-0}" != "1" ] && [ -f "${PIPPIN_SERVER_DIR}/../Newt/CMakeLists.txt" ]; then
    MONADO_VENDOR_DIR="${MONADO_VENDOR_DIR:-${PIPPIN_SERVER_DIR}/.build/monado-vendor/lib}"
    # Always rebuild both (incrementally; quick when nothing changed) so the app never
    # bundles a stale runtime or dashboard core. PIPPINVR_SKIP_DEPS=1 only builds what
    # is missing, as before.
    if [ "${PIPPINVR_SKIP_DEPS:-0}" != "1" ] || [ ! -f "${MONADO_VENDOR_DIR}/libopenxr_monado.dylib" ]; then
        echo "Building the Monado runtime via build-monado.sh..."
        bash "${SCRIPT_DIR}/build-monado.sh"
    fi
    if [ "${PIPPINVR_SKIP_DEPS:-0}" != "1" ] || [ ! -f "${PIPPIN_SERVER_DIR}/.build/newt-package/lib/libnewt_core.a" ]; then
        echo "Building Newt via build-newt.sh..."
        bash "${SCRIPT_DIR}/build-newt.sh"
    fi
elif [ "${PIPPINVR_SKIP_DIRECT:-0}" != "1" ]; then
    echo "Newt source missing; initialize submodules or explicitly set PIPPINVR_SKIP_DIRECT=1." >&2
    exit 1
fi

BUILD_ARGS=(-c "${BUILD_CONFIG}")
if [ "${UNIVERSAL:-0}" = "1" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}"

BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

if [ -d "${APP_DIR}" ]; then
    rm -rf "${APP_DIR}"
fi

mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"


cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${MACOS_DIR}/${EXECUTABLE_NAME}"

SPARKLE_FRAMEWORK=""
for candidate in \
    "${BUILD_DIR}/Sparkle.framework" \
    "${BUILD_DIR}/PackageFrameworks/Sparkle.framework" \
    "${PIPPIN_SERVER_DIR}/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"; do
    if [ -d "$candidate" ]; then
        SPARKLE_FRAMEWORK="$candidate"
        break
    fi
done
if [ -n "${SPARKLE_FRAMEWORK}" ] && [ -d "${SPARKLE_FRAMEWORK}" ]; then
    mkdir -p "${CONTENTS_DIR}/Frameworks"
    ditto "${SPARKLE_FRAMEWORK}" "${CONTENTS_DIR}/Frameworks/Sparkle.framework"
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY}" bash "${SCRIPT_DIR}/sign-sparkle.sh" "${APP_DIR}"
    echo "Embedded Sparkle.framework from ${SPARKLE_FRAMEWORK}"
elif otool -L "${MACOS_DIR}/${EXECUTABLE_NAME}" | grep -q 'Sparkle.framework'; then
    echo "error: executable links Sparkle but Sparkle.framework was not found to embed" >&2
    exit 1
fi
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"


cp "${PIPPIN_SERVER_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
python3 "${SCRIPT_DIR}/configure-updates.py" "${CONTENTS_DIR}/Info.plist"
if [ -f "${PIPPIN_SERVER_DIR}/../figures/pippin.png" ]; then
    cp "${PIPPIN_SERVER_DIR}/../figures/pippin.png" "${RESOURCES_DIR}/pippin-logo.png"
else
    echo "Warning: ../figures/pippin.png not found; VR dock will use the app-icon fallback"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"

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
        "${MACOS_DIR}/${EXECUTABLE_NAME}"
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP_DIR}"
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
if [ "${PIPPINVR_SKIP_DIRECT:-0}" != "1" ] && [ -f "${PIPPIN_SERVER_DIR}/.build/newt-package/lib/libnewt_core.a" ] && [ -d "${MONADO_VENDOR_DIR}" ]; then
    echo "Direct USB build detected with a Monado vendor dir -- bundling the runtime..."
    MONADO_VENDOR_DIR="${MONADO_VENDOR_DIR}" bash "${SCRIPT_DIR}/bundle-monado-runtime.sh" "${APP_DIR}"
elif [ "${PIPPINVR_SKIP_DIRECT:-0}" != "1" ]; then
    echo "Direct USB libraries are missing at ${MONADO_VENDOR_DIR}; run build-monado.sh and build-newt.sh." >&2
    exit 1
fi

echo "Location: ${APP_DIR}"
