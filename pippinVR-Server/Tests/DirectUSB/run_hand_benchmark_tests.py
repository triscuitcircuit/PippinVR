#!/usr/bin/env python3
"""Offline mask/snapshot tests; --vision also exercises native Vision on blank pixels (no camera)."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--vision", action="store_true")
options = parser.parse_args()
tests = Path(__file__).resolve().parent
server = tests.parents[1]
source = server / "Sources/NewtDashboard"
monado = server / "third_party/monado-ql"
driver = monado / "src/xrt/drivers/quest_link"
output = server / ".build/direct-usb-tests"
output.mkdir(parents=True, exist_ok=True)

def execute(args):
    subprocess.run(list(map(str, args)), check=True, timeout=120)

execute(["xcrun", "clang++", "-std=c++17", "-fsanitize=address,undefined", "-I" + str(source),
         tests / "hand_benchmark_test.cpp", "-o", output / "hand-benchmark-math"])
execute([output / "hand-benchmark-math"])
execute(["xcrun", "clang++", "-std=c++17", "-fsanitize=address,undefined", "-I" + str(source),
         tests / "hand_mask_test.cpp", "-o", output / "hand-mask-math"])
execute([output / "hand-mask-math"])
newt = server.parent / "Newt/include"
openxr = server / "third_party/openxr-sdk/include"
stereo_includes = ["-I" + str(source), "-I" + str(newt), "-I" + str(openxr), "-I" + str(tests)]
execute(["xcrun", "clang++", "-std=c++17", "-O2", "-fsanitize=address,undefined", *stereo_includes,
         tests / "hand_stereo_rig_test.cpp", "-o", output / "hand-stereo-rig"])
execute([output / "hand-stereo-rig"])
database = json.loads((monado / "build/compile_commands.json").read_text())
entry = next(item for item in database if item["file"].endswith("/ql_camera_vt.cpp"))
args = shlex.split(entry["command"])
flags = []
i = 1
while i < len(args):
    if args[i] in ("-c", "-o"):
        i += 2
        continue
    if args[i] not in ("-DNDEBUG", "-O2"):
        flags.append(args[i])
    i += 1
frameworks = ["CoreFoundation", "CoreVideo", "CoreMedia", "VideoToolbox"]
execute([args[0], *flags, "-I" + str(driver), "-fsanitize=address,undefined",
         tests / "camera_pair_snapshot_test.cpp",
         *[arg for framework in frameworks for arg in ("-framework", framework)],
         "-o", output / "camera-pair-snapshot"])
execute([output / "camera-pair-snapshot"])
if options.vision:
    frameworks = ["Vision", "CoreImage", "AppKit", "CoreVideo", "Foundation"]
    execute(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-fsanitize=address,undefined", "-mmacosx-version-min=14.0",
             "-DPIPPIN_HAND_BENCHMARK_TEST", source / "HandBenchmark.mm",
             *[arg for framework in frameworks for arg in ("-framework", framework)],
             "-o", output / "hand-vision-smoke"])
    execute([output / "hand-vision-smoke"])
    execute(["xcrun", "clang++", "-std=c++17", "-O1", "-fobjc-arc", "-fsanitize=address", "-mmacosx-version-min=14.0",
             *stereo_includes, tests / "hand_stereo_pipeline_test.mm", source / "HandStereo.mm",
             "-framework", "Metal", "-framework", "CoreVideo", "-framework", "Foundation",
             "-o", output / "hand-stereo-pipeline"])
    execute([output / "hand-stereo-pipeline"])
