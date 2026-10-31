#!/bin/bash
#
# Generate Resources/dmg/DS_Store -- the committed Finder window layout that
# package-dmg.sh drops into every DMG it builds.
#
# RUN THIS LOCALLY, ON A MAC WITH A LOGGED-IN GUI SESSION, and commit the
# result. It drives Finder over AppleScript, which cannot work on a headless
# CI runner; that is the whole reason the layout is committed rather than
# recomputed per build.
#
# Re-run it whenever you change background.png, the window size, or which files
# package-dmg.sh stages.
#
#   ./build-app.sh release      # needs PippinVR.app to exist to position it
#   ./make-dmg-layout.sh
#   git add Resources/dmg/DS_Store Resources/dmg/background*.png
#
# First run will ask for Finder automation permission (System Settings ->
# Privacy & Security -> Automation). Approve it, then re-run.
#
set -euo pipefail

APP_NAME="PippinVR"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PIPPIN_SERVER_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"
REPO_ROOT="$( cd "${PIPPIN_SERVER_DIR}/.." && pwd )"
APP_DIR="${PIPPIN_SERVER_DIR}/${APP_NAME}.app"
DMG_RES_DIR="${PIPPIN_SERVER_DIR}/Resources/dmg"

# Window geometry. Keep WIN_W/WIN_H equal to the background image's 1x pixel
# size or the image will be cropped or tiled.
WIN_W="${WIN_W:-640}"
WIN_H="${WIN_H:-500}"
ICON_SIZE="${ICON_SIZE:-128}"

# Icon positions, in background-image coordinates, (0,0) at the top-left.
# Top row is the install gesture; bottom row is the three docs.
APP_POS_X="${APP_POS_X:-160}";   APP_POS_Y="${APP_POS_Y:-180}"
DROP_POS_X="${DROP_POS_X:-480}"; DROP_POS_Y="${DROP_POS_Y:-180}"
PDF_POS_X="${PDF_POS_X:-110}";   PDF_POS_Y="${PDF_POS_Y:-360}"
MD_POS_X="${MD_POS_X:-320}";     MD_POS_Y="${MD_POS_Y:-360}"
LIC_POS_X="${LIC_POS_X:-530}";   LIC_POS_Y="${LIC_POS_Y:-360}"

if [ ! -d "${APP_DIR}" ]; then
    echo "error: ${APP_DIR} not found. Run ./build-app.sh release first." >&2
    exit 1
fi

mkdir -p "${DMG_RES_DIR}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dmg-common.sh"

# MUST match package-dmg.sh exactly. Finder writes the background into
# .DS_Store as an absolute-path alias (/Volumes/<name>/.background/...), so if
# this differs from the real DMG's volume name the alias dangles and the
# background just does not appear.
VOLUME_NAME="${APP_NAME}"

STAGE_DIR="$(mktemp -d)"
RW_DMG="$(mktemp -u).dmg"
MOUNT_POINT="/Volumes/${VOLUME_NAME}"

# If something is already mounted under this name, macOS would mount ours as
# "PippinVR 1" and Finder would write the alias with that name -- producing a
# DS_Store whose background never resolves. Refuse rather than do that.
if [ -e "${MOUNT_POINT}" ]; then
    echo "error: ${MOUNT_POINT} is already mounted." >&2
    echo "Eject it first (a previously opened PippinVR DMG, most likely):" >&2
    echo "  hdiutil detach \"${MOUNT_POINT}\"" >&2
    exit 1
fi

cleanup() {
    hdiutil detach "${MOUNT_POINT}" -quiet -force 2>/dev/null || true
    rm -rf "${STAGE_DIR}"
    rm -f "${RW_DMG}"
}
trap cleanup EXIT

# Stage exactly what package-dmg.sh stages, so every icon Finder needs to
# position is present and the saved layout matches the real DMG.
echo "Staging..."
cp -R "${APP_DIR}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"
[ -f "${REPO_ROOT}/LICENSE" ] && cp "${REPO_ROOT}/LICENSE" "${STAGE_DIR}/License.txt"
[ -f "${REPO_ROOT}/README.md" ] && cp "${REPO_ROOT}/README.md" "${STAGE_DIR}/Read Me.md"
[ -f "${REPO_ROOT}/readme.pdf" ] && cp "${REPO_ROOT}/readme.pdf" "${STAGE_DIR}/${APP_NAME} Guide.pdf"
# Not positioned (hidden in the real DMG), but staged so the icon count and
# any Finder auto-placement match what package-dmg.sh produces. Size-capped
# to match too -- see MAX_FIGURE_SIZE there.
if [ -d "${REPO_ROOT}/figures" ]; then
    mkdir -p "${STAGE_DIR}/figures"
    rsync -a --exclude '.*' --max-size="${MAX_FIGURE_SIZE:-4m}" \
        "${REPO_ROOT}/figures/" "${STAGE_DIR}/figures/"
fi

DMG_WINDOW_W="${WIN_W}" DMG_WINDOW_H="${WIN_H}" \
    stage_background "${DMG_RES_DIR}" "${STAGE_DIR}"

if [ -f "${STAGE_DIR}/.background/background.tiff" ]; then
    HAS_BACKGROUND=1
else
    echo "warning: no background staged."
    echo "         Positions will still be saved, but with no background image."
    HAS_BACKGROUND=0
fi

# UDRW: Finder has to be able to write .DS_Store into the volume.
echo "Creating writable image..."
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGE_DIR}" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "${RW_DMG}" > /dev/null

# Deliberately NOT -nobrowse: Finder must see the volume to arrange it.
hdiutil attach "${RW_DMG}" -quiet

echo "Arranging window via Finder..."

if [ "${HAS_BACKGROUND}" = "1" ]; then
    BACKGROUND_CMD="set background picture of viewOptions to file \".background:background.tiff\""
else
    BACKGROUND_CMD=""
fi

# Positions are set only for items that exist, so a missing LICENSE or PDF
# does not abort the whole script.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, ${WIN_W} + 100, ${WIN_H} + 100}

        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to ${ICON_SIZE}
        set text size of viewOptions to 12
        ${BACKGROUND_CMD}

        set position of item "${APP_NAME}.app" of container window to {${APP_POS_X}, ${APP_POS_Y}}
        set position of item "Applications" of container window to {${DROP_POS_X}, ${DROP_POS_Y}}

        if exists item "${APP_NAME} Guide.pdf" of container window then
            set position of item "${APP_NAME} Guide.pdf" of container window to {${PDF_POS_X}, ${PDF_POS_Y}}
        end if
        if exists item "Read Me.md" of container window then
            set position of item "Read Me.md" of container window to {${MD_POS_X}, ${MD_POS_Y}}
        end if
        if exists item "License.txt" of container window then
            set position of item "License.txt" of container window to {${LIC_POS_X}, ${LIC_POS_Y}}
        end if
        -- Parked off to the side; package-dmg.sh hides it entirely, but a
        -- stale auto-position here could leave a gap in the window.
        if exists item "figures" of container window then
            set position of item "figures" of container window to {${WIN_W} + 200, ${WIN_H} + 200}
        end if

        -- Close/reopen forces Finder to flush the window state to .DS_Store.
        close
        open
        update without registering applications
        delay 3
    end tell
end tell
APPLESCRIPT

sync
sleep 1

if [ ! -f "${MOUNT_POINT}/.DS_Store" ]; then
    echo "error: Finder did not write a .DS_Store." >&2
    echo "Most likely Finder automation is not permitted. Check System Settings" >&2
    echo "-> Privacy & Security -> Automation, allow your terminal to control" >&2
    echo "Finder, then re-run." >&2
    exit 1
fi

cp "${MOUNT_POINT}/.DS_Store" "${DMG_RES_DIR}/DS_Store"
hdiutil detach "${MOUNT_POINT}" -quiet

echo
echo "Wrote ${DMG_RES_DIR}/DS_Store"
echo "Commit it so CI produces the same window:"
echo "  git add ${DMG_RES_DIR#"${REPO_ROOT}/"}/DS_Store"
echo
echo "Then verify with: ./package-dmg.sh && open dist/*.dmg"
