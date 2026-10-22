#!/usr/bin/env python3
"""Hardware-free process/stop protocol checks. Pass a built pippinvr-server path."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='pippin-session-test-') as directory:
    root = Path(directory)
    app = root / 'SessionTest.app' / 'Contents'
    (app / 'MacOS').mkdir(parents=True)
    resources = app / 'Resources' / 'OpenXR'
    resources.mkdir(parents=True)
    for name in ['monado-runtime.json', 'MoltenVK_icd.json']:
        (resources / name).write_text('{}')
    with (app / 'Info.plist').open('wb') as output:
        plistlib.dump({'CFBundleExecutable': 'pippinvr-server', 'CFBundleIdentifier': 'com.pippinvr.session-test',
                      'CFBundlePackageType': 'APPL'}, output)
    executable = app / 'MacOS' / 'pippinvr-server'
    shutil.copy2(binary, executable)
    config = root / 'config.json'
    config.write_text(json.dumps({'port': 9943, 'displays': []}))
    helper = app / 'MacOS' / 'pippinvr-xr'
    ready = root / 'ready'
    stopped = root / 'stopped'
    env = dict(os.environ)
    env.pop('NEWT_IN_PROCESS', None)
    env.pop('PIPPINVR_WAIT_FOR_PID', None)
    env['PIPPINVR_XR_CLIENT'] = str(helper)
    harness_state = root / 'harness-newt-state'
    harness_state.mkdir(mode=0o700)
    harness_ipc = root / 'harness-newt-ipc'
    harness_ipc.mkdir(mode=0o700)
    env['NEWT_STATE_DIR'] = str(harness_state)
    env['NEWT_IPC_DIR'] = str(harness_ipc)
    env.pop('PIPPINVR_NEWT_SCRIPT', None)
    arguments = [str(executable), '--direct-usb', '--no-menu-bar', '--no-dock-icon', '--config', str(config)]

    def write_helper(body):
        helper.write_text('#!/bin/sh\n' + body)
        helper.chmod(0o755)

    managed_keys = ['QL_OVERRIDE_FPS', 'PIPPINVR_RAY_IDLE_SECONDS', 'PIPPINVR_RAY_WAKE_METERS', 'PIPPINVR_RAY_WAKE_DEGREES', 'NEWT_RAY_IDLE_SECONDS', 'NEWT_RAY_WAKE_METERS', 'NEWT_RAY_WAKE_DEGREES']
    for key in managed_keys:
        env.pop(key, None)

    write_helper('printf "settings:%s,%s,%s,%s\\n" "$QL_OVERRIDE_FPS" "$NEWT_RAY_IDLE_SECONDS" "$NEWT_RAY_WAKE_METERS" "$NEWT_RAY_WAKE_DEGREES"\n')
    config.write_text(json.dumps({'directUSB': {'refreshHz': 90, 'rayIdleSeconds': 1.5,
                                             'rayWakeDistanceMeters': 0.03, 'rayWakeAngleDegrees': 5}}))
    result = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and 'settings:90,1.5,0.03,5.0' in result.stdout, result.stdout + result.stderr
    print('PASS: file refresh and ray settings reach the bundled helper')

    override_env = dict(env, QL_OVERRIDE_FPS='72')
    result = subprocess.run(arguments, env=override_env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and 'settings:72,' in result.stdout, result.stdout + result.stderr
    print('PASS: explicit environment refresh overrides the config file')

    config.write_text(json.dumps({'directUSB': {'refreshHz': 0}}))
    result = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and 'settings:,2.0,0.02,3.0' in result.stdout, result.stdout + result.stderr
    print('PASS: Auto refresh and missing ray fields use defaults')

    for invalid in [{'refreshHz': 75}, {'rayIdleSeconds': -1}, {'rayWakeDistanceMeters': 0}, {'rayWakeAngleDegrees': 180}]:
        content = json.dumps({'directUSB': invalid})
        config.write_text(content)
        result = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode == 1 and 'settings:' not in result.stdout, result.stdout + result.stderr
        assert config.read_text() == content, 'invalid config was overwritten'
    print('PASS: invalid direct settings reject connection and preserve the file')
    config.write_text(json.dumps({'port': 9943, 'displays': []}))

    write_helper('exit 7\n')
    result = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 1 and 'status 7' in result.stderr, result.stderr
    print('PASS: helper failure is reported with its exit status')

    write_helper('exit 0\n')
    result = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    print('PASS: clean helper exit is accepted')

    write_helper(f'touch "{ready}"\nread command\n[ "$command" = stop ] || exit 8\nsleep 0.4\ntouch "{stopped}"\nexit 0\n')
    process = subprocess.Popen(arguments, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 8
        while not ready.exists() and time.monotonic() < deadline and process.poll() is None:
            time.sleep(0.02)
        assert ready.exists(), 'helper did not start'
        start = time.monotonic()
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=8)
        assert process.returncode == 0, stderr
        assert stopped.exists(), 'parent exited before the helper completed graceful stop'
        assert time.monotonic() - start >= 0.35, 'parent skipped the fade grace period'
        print('PASS: shutdown sends stop and waits for the helper grace period')
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()

    ready.unlink()
    write_helper(f'echo $$ > "{ready}"\nexec /usr/bin/python3 -c "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"\n')
    process = subprocess.Popen(arguments, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 8
        while not ready.exists() and time.monotonic() < deadline and process.poll() is None:
            time.sleep(0.02)
        assert ready.exists(), 'wedged helper did not start'
        helper_pid = int(ready.read_text())
        time.sleep(0.15)
        start = time.monotonic()
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=8)
        assert time.monotonic() - start < 5, 'bounded shutdown timed out'
        try:
            os.kill(helper_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('wedged helper survived shutdown')
        print('PASS: a wedged helper is forcibly stopped without being orphaned')
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()

    bare = root / 'bare'
    bare.mkdir()
    bare_executable = bare / 'pippinvr-server'
    shutil.copy2(binary, bare_executable)
    manager_state = root / 'newt-state'
    manager_state.mkdir(mode=0o700)
    manager_ipc = root / 'newt-ipc'
    manager_ipc.mkdir(mode=0o700)
    discovered_runtime = resources / 'monado-runtime.json'
    discovered_icd = resources / 'MoltenVK_icd.json'
    (manager_state / 'config.json').write_text(json.dumps(
        {'dashboard': str(helper), 'runtime': str(discovered_runtime), 'icd': str(discovered_icd)}))
    write_helper('printf "xr:%s|%s\\n" "$XR_RUNTIME_JSON" "$VK_ICD_FILENAMES"\n')
    bare_env = dict(env, NEWT_STATE_DIR=str(manager_state), NEWT_IPC_DIR=str(manager_ipc))
    for key in ['XR_RUNTIME_JSON', 'VK_ICD_FILENAMES', 'PIPPINVR_NEWT_SCRIPT']:
        bare_env.pop(key, None)
    bare_arguments = [str(bare_executable), '--direct-usb', '--no-menu-bar', '--no-dock-icon', '--config', str(config)]
    result = subprocess.run(bare_arguments, env=bare_env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and f'xr:{discovered_runtime}|{discovered_icd}' in result.stdout, \
        result.stdout + result.stderr
    print('PASS: bare terminal binary discovers runtime/ICD from the manager config')
