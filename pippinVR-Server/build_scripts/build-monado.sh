#!/bin/bash
set -euo pipefail

# Build the OpenXR-SDK loader and Monado (quest_link driver) runtime dylibs
# into .build/monado-vendor/lib, matching the layout build-newt.sh and
# bundle-monado-runtime.sh already expect.
#
# Usage:
#   ./build-monado.sh [--clean]
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPPIN_SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

THIRD_PARTY_DIR="${PIPPIN_SERVER_DIR}/third_party"
OPENXR_SRC_DIR="${THIRD_PARTY_DIR}/openxr-sdk"
OPENXR_TAG="${OPENXR_TAG:-release-1.0.30}"
OPENXR_BUILD_DIR="${OPENXR_BUILD_DIR:-${OPENXR_SRC_DIR}/build}"
MONADO_SRC_DIR="${MONADO_SRC_DIR:-${THIRD_PARTY_DIR}/monado-ql}"
MONADO_BUILD_DIR="${MONADO_BUILD_DIR:-${MONADO_SRC_DIR}/build}"
EIGEN_DIR="${THIRD_PARTY_DIR}/eigen-3.4.0"
VENDOR_DIR="${PIPPIN_SERVER_DIR}/.build/monado-vendor"

if [ -z "${VULKAN_SDK:-}" ]; then
    for candidate in "${HOME}/VulkanSDK"/*/macOS; do
        if [ -f "${candidate}/include/vulkan/vulkan.h" ]; then
            VULKAN_SDK="${candidate}"
            break
        fi
    done
fi
if [ -z "${VULKAN_SDK:-}" ]; then
    echo "error: no Vulkan SDK found under ~/VulkanSDK and VULKAN_SDK isn't set." >&2
    echo "Install the Vulkan SDK or point VULKAN_SDK at it." >&2
    exit 1
fi
echo "Using Vulkan SDK: ${VULKAN_SDK}"

if [ ! -f "${MONADO_SRC_DIR}/CMakeLists.txt" ]; then
    echo "error: Monado sources not found at ${MONADO_SRC_DIR}" >&2
    echo "Run 'git submodule update --init pippinVR-Server/third_party/monado-ql' first." >&2
    exit 1
fi

if [ "${1:-}" = "--clean" ]; then
    echo "Cleaning ${OPENXR_BUILD_DIR} and ${MONADO_BUILD_DIR}..."
    rm -rf "${OPENXR_BUILD_DIR}" "${MONADO_BUILD_DIR}"
fi

if [ ! -f "${OPENXR_SRC_DIR}/CMakeLists.txt" ]; then
    echo "=== Cloning OpenXR-SDK (${OPENXR_TAG}) into ${OPENXR_SRC_DIR} ==="
    git clone --depth 1 --branch "${OPENXR_TAG}" \
        https://github.com/KhronosGroup/OpenXR-SDK.git "${OPENXR_SRC_DIR}"
fi

# Homebrew's eigen package's version header doesn't parse cleanly under
# Monado's FindEigen3.cmake ("Eigen3 version .. found... but at least version
# 3 is required") -- vendor the known-good release directly instead of
# relying on whatever Homebrew has installed.
if [ ! -f "${EIGEN_DIR}/Eigen/src/Core/util/Macros.h" ]; then
    echo "=== Cloning Eigen 3.4.0 into ${EIGEN_DIR} ==="
    git clone --depth 1 --branch 3.4.0 \
        https://gitlab.com/libeigen/eigen.git "${EIGEN_DIR}"
fi

echo "=== [1/2] Building OpenXR-SDK loader in ${OPENXR_BUILD_DIR} ==="
cmake -S "${OPENXR_SRC_DIR}" -B "${OPENXR_BUILD_DIR}" \
    -G "Unix Makefiles" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_MAKE_PROGRAM=/usr/bin/make \
    -DPython3_EXECUTABLE=/usr/bin/python3 \
    -DPYTHON_EXECUTABLE=/usr/bin/python3 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
    -DDYNAMIC_LOADER=ON \
    -DBUILD_LOADER=ON \
    -DBUILD_API_LAYERS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CONFORMANCE_TESTS=OFF \
    -DBUILD_WITH_SYSTEM_JSONCPP=OFF
/usr/bin/make -C "${OPENXR_BUILD_DIR}" -j8 openxr_loader

GLSLANGVALIDATOR_COMMAND="${GLSLANGVALIDATOR_COMMAND:-${VULKAN_SDK}/bin/glslangValidator}"
if [ ! -x "${GLSLANGVALIDATOR_COMMAND}" ]; then
    echo "error: shader compiler not executable: ${GLSLANGVALIDATOR_COMMAND}" >&2
    exit 1
fi

echo "=== [2/2] Building Monado (quest_link) in ${MONADO_BUILD_DIR} ==="
EXTRA_INCLUDES="-DEIGEN_MPL2_ONLY -I/opt/homebrew/include -I/usr/local/include"
cmake -S "${MONADO_SRC_DIR}" -B "${MONADO_BUILD_DIR}" \
    -G "Unix Makefiles" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_MAKE_PROGRAM=/usr/bin/make \
    -DPython3_EXECUTABLE=/usr/bin/python3 \
    -DPYTHON_EXECUTABLE=/usr/bin/python3 \
    -DGLSLANGVALIDATOR_COMMAND="${GLSLANGVALIDATOR_COMMAND}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
    -DCMAKE_C_FLAGS="${EXTRA_INCLUDES}" \
    -DCMAKE_CXX_FLAGS="${EXTRA_INCLUDES}" \
    -DEIGEN3_INCLUDE_DIR="${EIGEN_DIR}" \
    -DVulkan_INCLUDE_DIR="${VULKAN_SDK}/include" \
    -DVulkan_LIBRARY="${VULKAN_SDK}/lib/libvulkan.1.dylib" \
    -DXRT_ENABLE_GPL=OFF \
    -DXRT_HAVE_X264=OFF \
    -DXRT_HAVE_XCB=OFF \
    -DXRT_HAVE_XLIB=OFF \
    -DXRT_HAVE_XRANDR=OFF \
    -DXRT_BUILD_DRIVER_QUEST_LINK=ON \
    -DXRT_BUILD_DRIVER_WIVRN=ON \
    -DXRT_BUILD_DRIVER_SIMULATED=ON \
    -DXRT_BUILD_DRIVER_TWRAP=ON \
    -DXRT_BUILD_DRIVER_NS=OFF \
    -DXRT_BUILD_DRIVER_PSVR=OFF \
    -DXRT_BUILD_DRIVER_QWERTY=OFF \
    -DXRT_BUILD_DRIVER_WMR=OFF \
    -DXRT_BUILD_SAMPLES=OFF \
    -DXRT_FEATURE_SERVICE=OFF \
    -DXRT_FEATURE_OPENXR=ON \
    -DXRT_HAVE_VT=ON \
    -DXRT_HAVE_VULKAN=ON \
    -DXRT_HAVE_TRACY=OFF \
    -DBUILD_TESTING=OFF
/usr/bin/make -C "${MONADO_BUILD_DIR}" -j8 openxr_monado

mkdir -p "${VENDOR_DIR}/include" "${VENDOR_DIR}/lib"
rsync -a "${OPENXR_BUILD_DIR}/include/openxr" "${VENDOR_DIR}/include/"
cp -f "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${OPENXR_BUILD_DIR}/src/loader/libopenxr_loader.dylib")" "${VENDOR_DIR}/lib/libopenxr_loader.dylib"
cp -f "${MONADO_BUILD_DIR}/src/xrt/targets/openxr/libopenxr_monado.dylib" "${VENDOR_DIR}/lib/libopenxr_monado.dylib"
cp -f "${VULKAN_SDK}/lib/libvulkan.1.dylib" "${VENDOR_DIR}/lib/libvulkan.1.dylib"
cp -f "${VULKAN_SDK}/lib/libMoltenVK.dylib" "${VENDOR_DIR}/lib/libMoltenVK.dylib"

echo "Built and synced into ${VENDOR_DIR}/lib:"
echo "  libopenxr_loader.dylib"
echo "  libopenxr_monado.dylib"
echo "  libvulkan.1.dylib"
echo "  libMoltenVK.dylib"
echo
echo "Next: OPENXR_INCLUDE_DIR=${OPENXR_BUILD_DIR}/include ./build-newt.sh, then ./build-app.sh"
echo "(build-app.sh bundles the Monado runtime automatically once .build/newt-package exists)."
