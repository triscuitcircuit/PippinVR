#!/usr/bin/env python3
"""Validate a relocatable app, optionally removing build-only rpaths before signing."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import shutil
import os
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--sdk", type=Path)
parser.add_argument("--fix-rpaths", action="store_true")
parser.add_argument("--smoke", action="store_true")
args = parser.parse_args()
app = args.app.resolve()
magic = {bytes.fromhex(s) for s in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf")}

def run(*command):
    return subprocess.check_output(list(map(str, command)), text=True, stderr=subprocess.STDOUT)

def system(path):
    return path.startswith(("/usr/lib/", "/System/Library/"))

binaries = []
for path in app.rglob("*"):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open("rb") as stream:
        if stream.read(4) in magic:
            binaries.append(path)
assert binaries, "No Mach-O binaries in app"
required = (14, 0)
for path in binaries:
    commands = run("otool", "-l", path)
    versions = re.findall(r"^\s+minos (\d+\.\d+(?:\.\d+)?)$", commands, re.M)
    versions += re.findall(r"cmd LC_VERSION_MIN_MACOSX\n\s+cmdsize \d+\n\s+version (\d+\.\d+(?:\.\d+)?)", commands)
    for version in versions:
        required = max(required, tuple(map(int, version.split('.'))))
    for search in set(re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset", commands)):
        if search.startswith("/") and not system(search):
            if not args.fix_rpaths:
                raise SystemExit(f"External rpath: {path}: {search}")
            subprocess.run(["install_name_tool", "-delete_rpath", search, str(path)], check=True)
    for dependency in re.findall(r"^\s+(.*?) \(compatibility version", run("otool", "-L", path), re.M):
        if system(dependency):
            continue
        if dependency.startswith("/"):
            raise SystemExit(f"External dependency: {path}: {dependency}")
        if dependency.startswith("@loader_path/"):
            target = path.parent / dependency.removeprefix("@loader_path/")
        elif dependency.startswith("@executable_path/"):
            target = app / "Contents/MacOS" / dependency.removeprefix("@executable_path/")
        elif dependency.startswith("@rpath/"):
            suffix = dependency.removeprefix("@rpath/")
            targets = [app / "Contents/Frameworks" / suffix, app / "Contents/Frameworks/Monado" / suffix,
                       path.parent / suffix]
            target = next((p for p in targets if p.exists()), targets[0])
        else:
            raise SystemExit(f"Unrecognized dependency: {path}: {dependency}")
        if not target.exists() or not target.resolve().is_relative_to(app):
            raise SystemExit(f"Missing bundled dependency: {path}: {dependency}")

plist = app / "Contents/Info.plist"
info = plistlib.loads(plist.read_bytes())
advertised = tuple(map(int, info.get("LSMinimumSystemVersion", "14.0").split('.')))
if args.fix_rpaths:
    info['LSMinimumSystemVersion'] = '.'.join(map(str, required))
    plist.write_bytes(plistlib.dumps(info, sort_keys=False))
elif advertised < required:
    raise SystemExit(f"App advertises macOS {advertised} but bundled code requires {required}")

for name, key in [("monado-runtime.json", "runtime"), ("MoltenVK_icd.json", "ICD")]:
    manifest = app / "Contents/Resources/OpenXR" / name
    data = json.loads(manifest.read_text())
    target = (manifest.parent / data[key]["library_path"]).resolve()
    assert target.is_relative_to(app) and target.exists(), f"Broken manifest: {manifest}"
if args.sdk:
    for name in ("libMoltenVK.dylib", "libvulkan.1.dylib"):
        def uuids(path):
            return set(re.findall(r"UUID: ([\w-]+) \((.*?)\)", run("dwarfdump", "--uuid", path)))
        source = uuids(args.sdk / "lib" / name)
        bundled = uuids(app / "Contents/Frameworks/Monado" / name)
        assert bundled and bundled <= source, f"{name} does not match the selected SDK"
if args.smoke:
    with tempfile.TemporaryDirectory(prefix="pippin-relocation-") as directory:
        relocated = Path(directory) / "PippinVR.app"
        shutil.copytree(app, relocated, symlinks=True)
        environment = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "NEWT_", "QL_", "VK_", "XR_", "VULKAN_", "PIPPIN"))}
        subprocess.run([str(relocated / "Contents/MacOS/pippinvr-server"), "--help"],
                       env=environment, check=True, timeout=30, stdout=subprocess.DEVNULL)
print(f"PASS: {len(binaries)} bundled binaries; macOS {info.get('LSMinimumSystemVersion')}; library resolution, manifests and SDK identity")
