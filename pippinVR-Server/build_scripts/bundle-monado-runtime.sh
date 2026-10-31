#!/bin/bash
set -euo pipefail

# Stage a relocatable Monado OpenXR runtime inside a PippinVR .app bundle.
#
# Usage:
#   bundle-monado-runtime.sh [APP_DIR]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPPIN_SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_DIR="${1:-${PIPPIN_SERVER_DIR}/PippinVR.app}"
if [ ! -d "${APP_DIR}" ]; then
    echo "error: ${APP_DIR} not found -- run build-app.sh first" >&2
    exit 1
fi


MONADO_VENDOR_DIR="${MONADO_VENDOR_DIR:-${PIPPIN_SERVER_DIR}/.build/monado-vendor/lib}"
MONADO_DYLIB="${MONADO_DYLIB:-${MONADO_VENDOR_DIR}/libopenxr_monado.dylib}"
LOADER_DYLIB="${LOADER_DYLIB:-${MONADO_VENDOR_DIR}/libopenxr_loader.dylib}"
MOLTENVK_DYLIB="${MOLTENVK_DYLIB:-${MONADO_VENDOR_DIR}/libMoltenVK.dylib}"
VULKAN_DYLIB="${VULKAN_DYLIB:-${MONADO_VENDOR_DIR}/libvulkan.1.dylib}"

NEWTD_BIN="${NEWTD_BIN:-${PIPPIN_SERVER_DIR}/.build/newt-package/bin/newtd}"

PYTHON3="/usr/bin/python3"
if [ ! -x "${PYTHON3}" ]; then
    PYTHON3="python3"
fi

for path in "${MONADO_DYLIB}" "${LOADER_DYLIB}" "${MOLTENVK_DYLIB}" "${VULKAN_DYLIB}"; do
    if [ ! -f "${path}" ]; then
        echo "error: Monado bundle input missing: ${path}" >&2
        echo "Point MONADO_VENDOR_DIR (or the individual *_DYLIB vars) at a" >&2
        echo "directory containing the four Monado/OpenXR/Vulkan dylibs." >&2
        exit 1
    fi
done

SDL3_DYLIB="${SDL3_DYLIB:-}"
if [ -z "${SDL3_DYLIB}" ]; then
    for candidate in \
        "${MONADO_VENDOR_DIR}/libSDL3.dylib" \
        /opt/homebrew/lib/libSDL3.dylib \
        /opt/homebrew/opt/sdl3/lib/libSDL3.dylib \
        /usr/local/lib/libSDL3.dylib; do
        if [ -f "${candidate}" ]; then
            SDL3_DYLIB="${candidate}"
            break
        fi
    done
fi
if [ -z "${SDL3_DYLIB}" ]; then
    echo "error: libSDL3.dylib not found (checked MONADO_VENDOR_DIR, Homebrew)." >&2
    echo "sdl2-compat dlopens this at runtime; without it Direct USB crashes" >&2
    echo "with an off-main-thread NSAlert the first time Newt_Run() starts." >&2
    exit 1
fi

DEST="${APP_DIR}/Contents/Frameworks/Monado"
case "${DEST}" in
    */Contents/Frameworks/Monado) ;;
    *)
        echo "Refusing to replace unexpected directory: ${DEST}" >&2
        exit 1
        ;;
esac
rm -rf "${DEST}"
mkdir -p "${DEST}" "${APP_DIR}/Contents/Resources/OpenXR"

"${PYTHON3}" - "$DEST" "$MONADO_DYLIB" "$LOADER_DYLIB" "$VULKAN_DYLIB" "$MOLTENVK_DYLIB" "$SDL3_DYLIB" "$MONADO_VENDOR_DIR" <<'PY'
import os
import shutil
import subprocess
import sys
from pathlib import Path

dest = Path(sys.argv[1])
roots = [Path(path) for path in sys.argv[2:-1]]
vendor_dir = Path(sys.argv[-1])
search_dirs = [vendor_dir, Path("/opt/homebrew/lib"), Path("/usr/local/lib")]
search_dirs.extend(sorted(Path("/opt/homebrew/opt").glob("*/lib")))

OTOOL = "/usr/bin/otool" if os.path.exists("/usr/bin/otool") else "otool"
INSTALL_NAME_TOOL = "/usr/bin/install_name_tool" if os.path.exists("/usr/bin/install_name_tool") else "install_name_tool"


def load_commands(path):
    output = subprocess.check_output([OTOOL, "-L", str(path)], text=True)
    deps = []
    for line in output.splitlines():
        if line[:1].isspace() and " (compatibility" in line:
            deps.append(line.strip().split(" (compatibility", 1)[0])
    return deps


def is_system(path):
    return path.startswith(("/usr/lib/", "/System/"))


def install_basename(path):
    try:
        output = subprocess.check_output([OTOOL, "-D", str(path)], text=True)
        for line in output.splitlines()[1:]:
            value = line.strip()
            if value.endswith(".dylib"):
                return Path(value).name
    except subprocess.CalledProcessError:
        pass
    return path.name


def resolve(dep, loader_dir):
    if os.path.exists(dep):
        return Path(dep)
    if dep.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
        name = Path(dep).name
        for directory in search_dirs:
            candidate = directory / name
            if candidate.exists():
                return candidate
        candidate = loader_dir / name
        if candidate.exists():
            return candidate
    return None


queue = list(roots)
by_basename = {}
by_realpath = {}
while queue:
    source = queue.pop(0)
    if not source.exists():
        raise SystemExit(f"missing dependency: {source}")
    real = Path(os.path.realpath(source))
    basename = install_basename(real)
    if real in by_realpath:
        continue
    prior = by_basename.get(basename)
    if prior is not None and prior != real:
        raise SystemExit(f"conflicting dylibs named {basename}: {prior} and {real}")
    by_basename[basename] = real
    by_realpath[real] = basename
    for dep in load_commands(real):
        if is_system(dep) or Path(dep).name == basename:
            continue
        resolved = resolve(dep, real.parent)
        if resolved is None:
            raise SystemExit(f"unresolved non-system dependency {dep!r} from {real}")
        queue.append(resolved)

for basename, source in sorted(by_basename.items()):
    target = dest / basename
    shutil.copy2(source, target)
    target.chmod(0o755)

for basename in sorted(by_basename):
    target = dest / basename
    subprocess.check_call([INSTALL_NAME_TOOL, "-id", f"@loader_path/{basename}", str(target)])
    for dep in list(load_commands(target)):
        if is_system(dep) or Path(dep).name == basename:
            continue
        dep_name = Path(dep).name
        if dep_name not in by_basename:
            raise SystemExit(f"unbundled dependency {dep!r} referenced by {basename}")
        subprocess.check_call(
            [INSTALL_NAME_TOOL, "-change", dep, f"@loader_path/{dep_name}", str(target)]
        )

print(f"bundled {len(by_basename)} dylibs")
for basename in sorted(by_basename):
    print(f"  {basename}")
PY

# sdl2-compat (if present in the closure) searches the unversioned name even
# though SDL3's install name is versioned.
if [ -f "${DEST}/libSDL3.0.dylib" ] && [ ! -e "${DEST}/libSDL3.dylib" ]; then
    ln -s libSDL3.0.dylib "${DEST}/libSDL3.dylib"
fi

EXECUTABLE="${APP_DIR}/Contents/MacOS/pippinvr-server"
ENTITLEMENTS="${PIPPIN_SERVER_DIR}/Resources/PippinVR.entitlements"
for lib in libopenxr_loader.dylib libvulkan.1.dylib; do
    if otool -L "${EXECUTABLE}" | grep -q "@loader_path/${lib}"; then
        install_name_tool -change "@loader_path/${lib}" \
            "@executable_path/../Frameworks/Monado/${lib}" "${EXECUTABLE}"
    fi
done

cat > "${APP_DIR}/Contents/Resources/OpenXR/monado-runtime.json" <<'JSON'
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "Monado (Quest Link, bundled by PippinVR)",
        "library_path": "../../Frameworks/Monado/libopenxr_monado.dylib"
    }
}
JSON

cat > "${APP_DIR}/Contents/Resources/OpenXR/MoltenVK_icd.json" <<'JSON'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "../../Frameworks/Monado/libMoltenVK.dylib",
        "api_version": "1.1.0"
    }
}
JSON

if [ -f "${NEWTD_BIN}" ]; then
    cp "${NEWTD_BIN}" "${APP_DIR}/Contents/Resources/newtd"
    chmod +x "${APP_DIR}/Contents/Resources/newtd"
    echo "Bundled newtd (enables managed Direct USB sessions)"
else
    echo "warning: newtd not found at ${NEWTD_BIN} -- managed Direct USB sessions" >&2
    echo "will fall back to in-process mode. Run build-newt.sh first if this" >&2
    echo "is unexpected." >&2
fi

LICENSE_DIR="${APP_DIR}/Contents/Resources/Licenses"
mkdir -p "${LICENSE_DIR}"
stage_license() {
    local source="$1" dest="$2"
    if [ -f "${source}" ]; then
        cp "${source}" "${LICENSE_DIR}/${dest}"
    else
        echo "warning: license file not found, skipping: ${source}" >&2
    fi
}
if [ -f "${PIPPIN_SERVER_DIR}/../readme.org" ]; then
    cp "${PIPPIN_SERVER_DIR}/../readme.org" "${APP_DIR}/Contents/Resources/readme.org"
fi
if [ -f "${PIPPIN_SERVER_DIR}/../LICENSE" ]; then
    stage_license "${PIPPIN_SERVER_DIR}/../LICENSE" "PippinVR-LICENSE.txt"
fi
stage_license "${PIPPIN_SERVER_DIR}/../Newt/LICENSE" "Newt-LICENSE.txt"
stage_license "${PIPPIN_SERVER_DIR}/third_party/monado-ql/LICENSE" "Monado-LICENSE.txt"
if [ -d "${PIPPIN_SERVER_DIR}/third_party/monado-ql/LICENSES" ]; then
    mkdir -p "${LICENSE_DIR}/Monado-LICENSES"
    cp "${PIPPIN_SERVER_DIR}"/third_party/monado-ql/LICENSES/*.txt "${LICENSE_DIR}/Monado-LICENSES/" 2>/dev/null || true
fi
stage_license "${PIPPIN_SERVER_DIR}/third_party/openxr-sdk/LICENSE" "OpenXR-SDK-LICENSE.txt"
stage_license "${PIPPIN_SERVER_DIR}/third_party/eigen-3.4.0/COPYING.README" "Eigen-COPYING.README.txt"
stage_license "${PIPPIN_SERVER_DIR}/third_party/eigen-3.4.0/COPYING.MPL2" "Eigen-COPYING.MPL2.txt"
stage_license "${PIPPIN_SERVER_DIR}/third_party/monado-ql/build/_deps/boostpfr-src/LICENSE_1_0.txt" "Boost-PFR-LICENSE_1_0.txt"
for candidate in /opt/homebrew/Cellar/libusb/*/COPYING /usr/local/Cellar/libusb/*/COPYING; do
    [ -f "${candidate}" ] && stage_license "${candidate}" "libusb-COPYING.txt" && break
done
for candidate in /opt/homebrew/Cellar/capnp/*/LICENSE /usr/local/Cellar/capnp/*/LICENSE; do
    [ -f "${candidate}" ] && stage_license "${candidate}" "CapnProto-LICENSE.txt" && break
done
for candidate in /opt/homebrew/Cellar/sdl3/*/LICENSE.txt /usr/local/Cellar/sdl3/*/LICENSE.txt; do
    [ -f "${candidate}" ] && stage_license "${candidate}" "SDL3-LICENSE.txt" && break
done
echo "Staged acknowledgements/licenses at: ${LICENSE_DIR}"

LEAKED_DEPS="$(otool -L "${DEST}"/*.dylib 2>/dev/null \
    | grep -E '^\s+(/opt/homebrew|/usr/local|/Users|/tmp)' || true)"
if [ -n "${LEAKED_DEPS}" ]; then
    echo "error: non-relocatable load paths found in bundle:" >&2
    echo "${LEAKED_DEPS}" >&2
    exit 1
fi

python3 "${SCRIPT_DIR}/verify-bundle.py" "${APP_DIR}" --fix-rpaths
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}" bash "${SCRIPT_DIR}/sign-sparkle.sh" "${APP_DIR}"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
for library in "${DEST}"/*.dylib; do
    if [ "${CODESIGN_IDENTITY}" = "-" ]; then
        codesign --force --sign - "$library" >/dev/null
    else
        codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "$library" >/dev/null
    fi
done
if [ -f "${APP_DIR}/Contents/Resources/newtd" ]; then
    if [ "${CODESIGN_IDENTITY}" = "-" ]; then
        codesign --force --sign - "${APP_DIR}/Contents/Resources/newtd" >/dev/null
    else
        codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "${APP_DIR}/Contents/Resources/newtd" >/dev/null
    fi
fi
if [ "${CODESIGN_IDENTITY}" = "-" ]; then
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${EXECUTABLE}" >/dev/null
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP_DIR}" >/dev/null
else
    codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${ENTITLEMENTS}" "${EXECUTABLE}" >/dev/null
    codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${ENTITLEMENTS}" "${APP_DIR}" >/dev/null
fi
codesign --verify --strict "${APP_DIR}"

echo "Monado runtime bundled at: ${DEST}"
