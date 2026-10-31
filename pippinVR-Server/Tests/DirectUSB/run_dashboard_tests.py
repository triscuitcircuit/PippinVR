#!/usr/bin/env python3
"""Offline dashboard tests (no headset): custom headset panels, recentering."""
from pathlib import Path
import os
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
vulkan_sdk = os.environ.get("VULKAN_SDK")
vulkan_include = []
if vulkan_sdk:
    include = Path(vulkan_sdk) / "include"
    if not (include / "vulkan/vulkan.h").is_file():
        raise SystemExit(f"Vulkan headers not found in VULKAN_SDK: {include}")
    vulkan_include = ["-I" + str(include)]
execute(["xcrun", "clang++", "-std=c++17", "-fsanitize=address,undefined", "-I" + str(source), "-I" + str(newt),
         "-I" + str(openxr), *vulkan_include, tests / "recenter_test.cpp", "-o", output / "recenter"])
execute([output / "recenter"])
