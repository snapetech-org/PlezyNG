#!/usr/bin/env python3
"""Choose the intended SDK runtime instead of the first installed simulator."""
import json
import os
import re
import subprocess


def version_pair(value):
    if re.fullmatch(r'\d+\.\d+(?:\.\d+)?', value) is None:
        raise ValueError('Unexpected Apple SDK/runtime version')
    return tuple(map(int, value.split('.')[:2]))


def select_device(payload, platform, sdk_version):
    if platform not in ('iOS', 'tvOS'):
        raise ValueError('Expected iOS or tvOS simulator platform')
    expected = version_pair(sdk_version)
    runtimes = [runtime for runtime in payload['runtimes']
                if runtime.get('isAvailable') is True and f'.{platform}-' in runtime.get('identifier', '')
                and version_pair(runtime['version']) == expected]
    for runtime in sorted(runtimes, key=lambda value: tuple(map(int, value['version'].split('.'))), reverse=True):
        devices = [device for device in payload['devices'].get(runtime['identifier'], [])
                   if device.get('isAvailable') is True]
        devices.sort(key=lambda device: (not device.get('name', '').startswith('iPhone'),
                                         device.get('name', ''), device.get('udid', '')))
        if devices:
            udid = devices[0]['udid']
            if re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', udid) is None:
                raise ValueError('Simulator returned an invalid device identifier')
            return f'platform={platform} Simulator,id={udid}', runtime['version']
    raise ValueError(f'No available {platform} simulator matches selected SDK {sdk_version}')


def main():
    destination = os.environ.get('STATIC_DESTINATION', '')
    runtime = ''
    if not destination:
        sdk = os.environ['SIMULATOR_SDK']
        version = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-version'], text=True).strip()
        payload = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '-j'], text=True))
        destination, runtime = select_device(payload, os.environ['SIMULATOR_RUNTIME'], version)
    with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
        output.write(f'APPLE_TEST_DESTINATION={destination}\nAPPLE_TEST_RUNTIME_VERSION={runtime}\n')
    print(f'Apple test destination: {destination}; runtime: {runtime or "native host"}')


if __name__ == '__main__':
    main()
