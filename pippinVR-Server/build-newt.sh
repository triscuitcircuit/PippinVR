#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEWT_SOURCE="${NEWT_SOURCE_DIR:-${SCRIPT_DIR}/../Newt}"
NEWT_BUILD="${NEWT_BUILD_DIR:-${SCRIPT_DIR}/.build/newt}"
NEWT_PREFIX="${SCRIPT_DIR}/.build/newt-package"
if [ ! -f "${NEWT_SOURCE}/CMakeLists.txt" ]; then
    echo "error: Newt sources not found at ${NEWT_SOURCE}" >&2
    echo "Newt is a separate project. Clone it next to PippinVR (as ../Newt)" >&2
    echo "or point NEWT_SOURCE_DIR at your checkout, then re-run." >&2
    exit 1
fi
SDK_ARGS=()
if [ -n "${VULKAN_SDK:-}" ]; then SDK_ARGS+=("-DVULKAN_SDK=${VULKAN_SDK}"); fi
OPENXR_ARGS=()
if [ -n "${OpenXR_DIR:-}" ]; then
    OPENXR_ARGS+=("-DOpenXR_DIR=${OpenXR_DIR}")
elif [ -d "${OPENXR_BUILD_DIR:-${SCRIPT_DIR}/third_party/openxr-sdk/build}/src/loader" ]; then
    OPENXR_ARGS+=("-DOpenXR_DIR=${OPENXR_BUILD_DIR:-${SCRIPT_DIR}/third_party/openxr-sdk/build}/src/loader")
fi
cmake -S "${NEWT_SOURCE}" -B "${NEWT_BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DNEWT_WITH_USB=OFF -DBUILD_TESTING=ON \
    ${OPENXR_ARGS[@]+"${OPENXR_ARGS[@]}"} \
    ${SDK_ARGS[@]+"${SDK_ARGS[@]}"}
cmake --build "${NEWT_BUILD}" --parallel 6
ctest --test-dir "${NEWT_BUILD}" --output-on-failure
cmake --install "${NEWT_BUILD}" --prefix "${NEWT_PREFIX}"
cp "${NEWT_PREFIX}/include/Newt.h" "${NEWT_PREFIX}/include/NewtLog.h" "${SCRIPT_DIR}/NewtBridge/include/"
