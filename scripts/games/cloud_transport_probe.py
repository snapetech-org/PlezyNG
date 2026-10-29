#!/usr/bin/env python3
"""Exercise real desktop IPC with Dart, a fake Steam observer and no Steam changes.
Run only when the actual Cloud plugin is stopped; never remove an existing socket.
Windows/macOS agents need Python 3.10+ and Dart 3.10+ (Flutter's Dart is sufficient).
A missing SDK or unavailable OS socket is a failure, not a silently passing skip.
"""
import argparse
import asyncio
import os
import shutil
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'integrations/steam-cloud-decky'))
from bridge import Bridge


def dart_executable(command):
    resolved = shutil.which(command)
    if not resolved:
        raise FileNotFoundError('Dart SDK executable is required')
    path = Path(resolved)
    if sys.platform == 'win32' and path.suffix.lower() in ('.bat', '.cmd'):
        # Flutter exposes dart.bat on PATH; launch the native SDK without a shell.
        path = path.parent / 'cache/dart-sdk/bin/dart.exe'
        if not path.is_file():
            raise FileNotFoundError('Pass --dart with the native dart.exe path')
    return str(path)


async def run(dart):
    dart = dart_executable(dart)
    if sys.platform == 'win32':
        from windows_pipe import WindowsBridge
    mode = ''
    claimed = 0

    async def emit(_, request, data):
        nonlocal claimed
        if mode == 'cancel':
            await asyncio.sleep(.4)
        if not await bridge.claim(request):
            return
        claimed += 1
        if mode == 'cancel':
            raise AssertionError('Disconnected request was claimed')
        status = 'observed'
        if data['steamId'] != '76561198000000001':
            status = 'unknown'
        elif data['op'] == 'set' and data['expected'] is not True:
            status = 'stale'
        await bridge.complete(request, {'status': status, 'steamId': data['steamId'],
                                       'enabled': data.get('enabled', True)})

    temporary = tempfile.TemporaryDirectory()
    env = os.environ.copy()
    created = None
    if sys.platform == 'win32':
        bridge = WindowsBridge(emit)
        await bridge.start()
    else:
        uid = os.getuid()
        bridge = Bridge(uid, emit)
        if sys.platform == 'darwin':
            runtime = Path(f'/tmp/plezyng-steam-cloud-{uid}')
            if not runtime.exists():
                runtime.mkdir(mode=0o700)
                created = runtime
        else:
            runtime = Path(temporary.name)
            env['XDG_RUNTIME_DIR'] = str(runtime)
        await bridge.start(runtime)
    try:
        for mode in ('read', 'set', 'stale', 'wrong_account', 'malformed', 'disabled', 'cancel'):
            bridge.allow(mode != 'disabled')
            before = claimed
            process = await asyncio.create_subprocess_exec(
                dart, str(ROOT / 'scripts/games/cloud_transport_probe.dart'), mode, env=env)
            try:
                code = await asyncio.wait_for(process.wait(), 20)
            except BaseException:
                process.kill()
                await process.wait()
                raise
            if code:
                raise RuntimeError(f'{mode}: Dart probe failed ({code})')
            # Let cancelled event callbacks retire before checking claim counts.
            await asyncio.sleep(.5)
            if mode in ('malformed', 'disabled', 'cancel') and claimed != before:
                raise AssertionError(f'{mode}: unauthorized claim')
        print(f'PASS real OS IPC: {sys.platform}; simulated observer, not live Steam')
    finally:
        await bridge.close()
        temporary.cleanup()
        if created:
            created.rmdir()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    asyncio.run(run(parser.parse_args().dart))
