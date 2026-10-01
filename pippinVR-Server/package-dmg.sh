#!/bin/bash
set -euo pipefail

APP_NAME="PippinVR"
VERSION="${VERSION:-1.0}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
DMG_RES_DIR="${SCRIPT_DIR}/Resources/dmg"
DIST_DIR="${SCRIPT_DIR}/dist"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

VOLUME_NAME="${APP_NAME}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dmg-common.sh"

if [ ! -d "${APP_DIR}" ]; then
    echo "${APP_DIR} not found" >&2
    exit 1
fi

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"

STAGE_DIR="$(mktemp -d)"
RW_DMG="$(mktemp -u).dmg"
MOUNT_POINT="$(mktemp -d)"

cleanup() {
    hdiutil detach "${MOUNT_POINT}" -quiet -force 2>/dev/null || true
    rm -rf "${STAGE_DIR}" "${MOUNT_POINT}"
    rm -f "${RW_DMG}"
}
trap cleanup EXIT


cp -R "${APP_DIR}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

if [ -f "${REPO_ROOT}/LICENSE" ]; then
    cp "${REPO_ROOT}/LICENSE" "${STAGE_DIR}/License.txt"
else
    echo "${REPO_ROOT}/LICENSE not found"
fi

if [ -f "${REPO_ROOT}/README.md" ]; then
    cp "${REPO_ROOT}/README.md" "${STAGE_DIR}/Read Me.md"
else
    echo "${REPO_ROOT}/README.md"
fi

if [ -f "${REPO_ROOT}/readme.pdf" ]; then
    cp "${REPO_ROOT}/readme.pdf" "${STAGE_DIR}/${APP_NAME} Guide.pdf"
else
    echo " ${REPO_ROOT}/readme.pdf not found"
fi

MAX_FIGURE_SIZE="${MAX_FIGURE_SIZE:-4m}"
if [ -d "${REPO_ROOT}/figures" ]; then
    mkdir -p "${STAGE_DIR}/figures"
    rsync -a --exclude '.*' --max-size="${MAX_FIGURE_SIZE}" \
        "${REPO_ROOT}/figures/" "${STAGE_DIR}/figures/"

    SKIPPED="$(find "${REPO_ROOT}/figures" -type f -not -name '.*' \
        -size +"${MAX_FIGURE_SIZE%m}"M -exec basename {} \; 2>/dev/null || true)"
    if [ -n "${SKIPPED}" ]; then
        echo "  Figures over ${MAX_FIGURE_SIZE} omitted"
        echo "    ${SKIPPED//$'\n'/$'\n'    }"
    fi
fi

stage_background "${DMG_RES_DIR}" "${STAGE_DIR}"

if [ -f "${DMG_RES_DIR}/VolumeIcon.icns" ]; then
    cp "${DMG_RES_DIR}/VolumeIcon.icns" "${STAGE_DIR}/.VolumeIcon.icns"
fi

if [ -f "${DMG_RES_DIR}/DS_Store" ]; then
    cp "${DMG_RES_DIR}/DS_Store" "${STAGE_DIR}/.DS_Store"
else
    echo "Default layout"
fi

echo "Creating image..."
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGE_DIR}" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "${RW_DMG}" > /dev/null

hdiutil attach "${RW_DMG}" -mountpoint "${MOUNT_POINT}" -nobrowse -quiet

if [ -f "${MOUNT_POINT}/.VolumeIcon.icns" ]; then
    if command -v SetFile &> /dev/null; then
        SetFile -a C "${MOUNT_POINT}"
    else
        echo "  (SetFile unavailable, volume will use the generic disk icon)"
    fi
fi

if [ -d "${MOUNT_POINT}/figures" ]; then
    chflags hidden "${MOUNT_POINT}/figures"
fi

sync
hdiutil detach "${MOUNT_POINT}" -quiet

echo "Compressing to ${DMG_PATH}..."
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -ov -o "${DMG_PATH}" > /dev/null

# --- Sign, notarize, staple --------------------------------------------------

if [ "${CODESIGN_IDENTITY}" = "-" ]; then
    echo "local testing"
    echo "DMG: ${DMG_PATH}"
    exit 0
fi

echo "Signing Installer"
codesign --force --timestamp --sign "${CODESIGN_IDENTITY}" "${DMG_PATH}"

NOTARY_ARGS=()
if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] \
   && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
    NOTARY_ARGS=(--key "${APPLE_API_KEY_PATH}"
                 --key-id "${APPLE_API_KEY_ID}"
                 --issuer "${APPLE_API_ISSUER_ID}")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] \
     && [ -n "${APPLE_TEAM_ID:-}" ]; then
    NOTARY_ARGS=(--apple-id "${APPLE_ID}"
                 --password "${APPLE_APP_PASSWORD}"
                 --team-id "${APPLE_TEAM_ID}")
else
    echo "No notarization credentials"
    echo "DMG: ${DMG_PATH}"
    exit 0
fi

echo "Submitting to Apple notary service"
if ! xcrun notarytool submit "${DMG_PATH}" "${NOTARY_ARGS[@]}" --wait --timeout 30m; then
    echo "error: notarization failed" >&2
    SUBMISSION_ID="$(xcrun notarytool history "${NOTARY_ARGS[@]}" \
        --output-format json 2>/dev/null \
        | plutil -extract history.0.id raw - 2>/dev/null || true)"
    if [ -n "${SUBMISSION_ID}" ]; then
        xcrun notarytool log "${SUBMISSION_ID}" "${NOTARY_ARGS[@]}" >&2 || true
    fi
    exit 1
fi

xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

spctl --assess --type open --context context:primary-signature -vv "${DMG_PATH}"

echo "${DMG_PATH}"
