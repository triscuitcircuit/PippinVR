#!/bin/bash

image_dimensions() {
    sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null \
        | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {if (w && h) print w, h}'
}

stage_background() {
    local res_dir="$1" stage_dir="$2"
    local png="${res_dir}/background.png"
    local png2x="${res_dir}/background@2x.png"
    local out="${stage_dir}/.background/background.tiff"

    if [ -f "${res_dir}/background.tiff" ]; then
        mkdir -p "${stage_dir}/.background"
        cp "${res_dir}/background.tiff" "${out}"
        return 0
    fi

    if [ ! -f "${png}" ]; then
        echo "  (no background image in ${res_dir}, using the default window)"
        return 0
    fi

    mkdir -p "${stage_dir}/.background"

    local dims w h
    dims="$(image_dimensions "${png}")"
    if [ -z "${dims}" ]; then
        echo "error: cannot read ${png} -- is it a valid PNG?" >&2
        return 1
    fi
    read -r w h <<< "${dims}"

    if [ "${w}" != "${DMG_WINDOW_W:-640}" ] || [ "${h}" != "${DMG_WINDOW_H:-460}" ]; then
        echo "  warning: background.png is ${w}x${h}, but the window is" \
             "${DMG_WINDOW_W:-640}x${DMG_WINDOW_H:-460}."
        echo "           Finder will crop or tile it. Either resize the image or"
        echo "           re-run make-dmg-layout.sh with WIN_W=${w} WIN_H=${h}."
    fi

    if [ ! -f "${png2x}" ]; then
        cp "${png}" "${out}"
        echo "  Background: ${w}x${h} (no @2x, will be soft on Retina)"
        return 0
    fi

    local dims2x w2x h2x
    dims2x="$(image_dimensions "${png2x}")"
    if [ -z "${dims2x}" ]; then
        echo "error: cannot read ${png2x} -- is it a valid PNG?" >&2
        return 1
    fi
    read -r w2x h2x <<< "${dims2x}"

    if ! command -v tiffutil &> /dev/null; then
        cp "${png}" "${out}"
        echo "  Background: ${w}x${h} (tiffutil unavailable, 1x only)"
        return 0
    fi

    tiffutil -cathidpicheck "${png}" "${png2x}" -out "${out}" > /dev/null
    echo "  Background: ${w}x${h} + ${w2x}x${h2x} Retina"
}
