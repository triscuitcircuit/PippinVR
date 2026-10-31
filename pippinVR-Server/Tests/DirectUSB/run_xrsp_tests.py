#!/usr/bin/env python3
"""Run packet/probe regressions using the configured Monado build's includes."""
import json
from pathlib import Path
import shlex
import subprocess

tests = Path(__file__).resolve().parent
server = tests.parents[1]
monado = server / "third_party/monado-ql"
driver = monado / "src/xrt/drivers/quest_link"
database = json.loads((monado / "build/compile_commands.json").read_text())
entry = next(item for item in database if item["file"].endswith("/ql_xrsp_topic.cpp"))
args = shlex.split(entry["command"])
flags = []
index = 1
while index < len(args):
    arg = args[index]
    if arg in ("-c", "-o"):
        index += 2
        continue
    if arg not in ("-DNDEBUG", "-O2"):
        flags.append(arg)
    index += 1

output = server / ".build/direct-usb-tests"
output.mkdir(parents=True, exist_ok=True)
for name, sources in (
    ("xrsp-topic", [driver / "ql_xrsp_topic.cpp", tests / "xrsp_topic_test.cpp"]),
    ("camera-probe", [tests / "camera_probe_test.cpp"]),
    ("invite-ok", [tests / "invite_ok_test.cpp"]),
    ("camera-stream", [tests / "camera_stream_test.cpp"]),
    ("camera-hevc", [tests / "camera_hevc_test.cpp"]),
):
    executable = output / name
    subprocess.run(
        [args[0], *flags, "-I" + str(driver), "-fsanitize=address,undefined",
         "-fno-omit-frame-pointer", *map(str, sources), "-o", str(executable)],
        check=True,
    )
    subprocess.run([str(executable)], check=True)
