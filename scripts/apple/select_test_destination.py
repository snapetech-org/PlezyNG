#!/usr/bin/env python3
"""Choose the intended SDK runtime instead of the first installed simulator."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def version_pair(value):
    if re.fullmatch(r'\d+\.\d+(?:\.\d+)?', value) is None:
        raise ValueError('Unexpected Apple SDK/runtime version')
    return tuple(map(int, value.split('.')[:2]))


def select_device_template(payload, platform, sdk_version):
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
            device_type = devices[0].get('deviceTypeIdentifier', '')
            if not device_type.startswith('com.apple.CoreSimulator.SimDeviceType.'):
                raise ValueError('Simulator returned an invalid device type')
            return runtime, device_type
    raise ValueError(f'No available {platform} simulator matches selected SDK {sdk_version}')


def owner_record(env):
    for key, pattern in (('GITHUB_RUN_ID', r'\d+'), ('GITHUB_RUN_ATTEMPT', r'\d+'),
                         ('GITHUB_JOB', r'[A-Za-z0-9_-]+'), ('GITHUB_SHA', r'[0-9a-f]{40}'),
                         ('SIMULATOR_RUNTIME', r'iOS|tvOS')):
        if re.fullmatch(pattern, env.get(key, '')) is None:
            raise ValueError(f'Invalid simulator owner field: {key}')
    return {key: env[key] for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
                                     'GITHUB_JOB', 'GITHUB_SHA', 'SIMULATOR_RUNTIME')}


def receipt_path(env, owner):
    temp = Path(env['RUNNER_TEMP']).resolve(strict=True)
    name = '-'.join(owner[key] for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
                                         'GITHUB_JOB', 'SIMULATOR_RUNTIME'))
    return temp / f'pleazyng-simulator-{name}.json'


def simctl(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()


def create_fresh_device(payload, platform, sdk_version, env):
    runtime, device_type = select_device_template(payload, platform, sdk_version)
    owner = owner_record(env)
    receipt = receipt_path(env, owner)
    if receipt.exists() or receipt.is_symlink():
        raise ValueError('Simulator owner receipt already exists; refusing to replace it')
    name = f"Pleazyng-{env['GITHUB_RUN_ID']}-{env['GITHUB_RUN_ATTEMPT']}-{platform}"
    # Never boot, erase, clone, uninstall from, or reuse the template device.
    udid = simctl('create', name, device_type, runtime['identifier'])
    if re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', udid) is None:
        raise ValueError('Simulator returned an invalid device identifier')
    record = {'owner': owner, 'udid': udid, 'name': name,
              'runtime': runtime['identifier'], 'device_type': device_type, 'state': 'created'}
    with receipt.open('x', encoding='utf-8') as output:
        json.dump(record, output, indent=2)
    return f'platform={platform} Simulator,id={udid}', runtime['version'], receipt


def cleanup_device(env):
    if env.get('STATIC_DESTINATION') or not env.get('SIMULATOR_RUNTIME'):
        return
    owner = owner_record(env)
    receipt = receipt_path(env, owner)
    if not receipt.exists():
        return
    if receipt.is_symlink():
        raise ValueError('Refusing redirected simulator receipt')
    record = json.loads(receipt.read_text(encoding='utf-8'))
    if record['owner'] != owner:
        raise ValueError('Simulator receipt owner does not match this job')
    if env.get('APPLE_JIT_JOB_STATUS') == 'cancelled':
        print(f'Cancelled job: retaining owned simulator and receipt {receipt}')
        return
    helper = env.get('APPLE_JIT_PROCESS_HELPER')
    if helper:
        root = env.get('APPLE_JIT_PROCESS_RUNNER_ROOT', '')
        job_id = env.get('APPLE_JIT_PROCESS_JOB_ID', '')
        if (helper != f'{root}/.apple-jit-process-tree.py' or Path(helper).is_symlink()
                or not Path(helper).is_file() or not job_id.isdigit()):
            raise ValueError('Refusing simulator cleanup with an unfamiliar process observer')
        subprocess.run([sys.executable, helper, 'settle-idle', env['GITHUB_RUN_ID'],
                        job_id, env['GITHUB_RUN_ATTEMPT'], root], check=True)
    inventory = json.loads(simctl('list', '-j'))
    matches = [(runtime, device) for runtime, devices in inventory['devices'].items()
               for device in devices if device['udid'] == record['udid']]
    if matches:
        runtime, device = matches[0]
        if (runtime != record['runtime'] or device['name'] != record['name']
                or device.get('deviceTypeIdentifier') != record['device_type']):
            raise ValueError('Simulator identity differs from its owner receipt; refusing cleanup')
        if device['state'] != 'Shutdown':
            simctl('shutdown', record['udid'])
        simctl('delete', record['udid'])
    record['state'] = 'deleted'
    receipt.write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(f'Removed owned simulator {record["udid"]}; retained receipt {receipt}')


def main():
    if sys.argv[1:] == ['--cleanup']:
        cleanup_device(os.environ)
        return
    if sys.argv[1:]:
        raise ValueError('Only --cleanup is supported')
    destination = os.environ.get('STATIC_DESTINATION', '')
    runtime = ''
    if not destination:
        sdk = os.environ['SIMULATOR_SDK']
        version = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-version'], text=True).strip()
        payload = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '-j'], text=True))
        destination, runtime, receipt = create_fresh_device(
            payload, os.environ['SIMULATOR_RUNTIME'], version, os.environ)
        with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
            output.write(f'APPLE_SIMULATOR_RECEIPT={receipt}\n')
    with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
        output.write(f'APPLE_TEST_DESTINATION={destination}\nAPPLE_TEST_RUNTIME_VERSION={runtime}\n')
    print(f'Apple test destination: {destination}; runtime: {runtime or "native host"}')


if __name__ == '__main__':
    main()
