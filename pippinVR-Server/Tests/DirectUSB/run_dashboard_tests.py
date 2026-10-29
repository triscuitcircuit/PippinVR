#!/usr/bin/env python3
"""Offline dashboard tests (no headset): custom headset panels, recentering."""
from pathlib import Path
import subprocess

tests = Path(__file__).resolve().parent
server = tests.parents[1]
source = server / "Sources/NewtDashboard"
output = server / ".build/direct-usb-tests"
output.mkdir(parents=True, exist_ok=True)

def execute(args):
    subprocess.run(list(map(str, args)), check=True, timeout=120)

execute(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-fsanitize=address,undefined", "-mmacosx-version-min=14.0",
         "-I" + str(source), tests / "custom_ui_test.mm", source / "CustomUIParse.mm", "-framework", "Foundation",
         "-o", output / "custom-ui"])
execute([output / "custom-ui"])
newt = server.parent / "Newt/include"
openxr = server / "third_party/openxr-sdk/include"
execute(["xcrun", "clang++", "-std=c++17", "-fsanitize=address,undefined", "-I" + str(source), "-I" + str(newt),
         "-I" + str(openxr), tests / "recenter_test.cpp", "-o", output / "recenter"])
execute([output / "recenter"])
