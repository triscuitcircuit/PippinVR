#!/usr/bin/env python3
"""Synthetic audio buffer checks; no capture, playback, or headset required."""
from pathlib import Path
import subprocess

tests = Path(__file__).resolve().parent
server = tests.parents[1]
output = server / ".build/direct-usb-tests/audio-buffers"
output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([
    "xcrun", "clang++", "-std=c++17", "-fsanitize=address,undefined",
    "-I" + str(server / "Sources/NewtDashboard"),
    "-I" + str(server / "third_party/monado-ql/src/xrt/drivers/quest_link"),
    str(tests / "audio_buffers_test.cpp"), "-o", str(output),
], check=True, timeout=120)
subprocess.run([str(output)], check=True, timeout=30)
