#!/usr/bin/env python3
"""Inspect bundled RomM libraries and corresponding source in an Android package."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

from build_steam_android import inspect_elf
from package_romm_cores import DEFAULT_CORES, PINS, ROOT

MAX_ENTRY_BYTES = 256 * 1024 * 1024
SYSTEM_LIBRARIES = {'libandroid.so', 'liblog.so', 'libc.so', 'libm.so',
                    'libdl.so', 'libz.so', 'libOpenSLES.so', 'libaaudio.so'}
CORE_EXPORTS = {'retro_api_version', 'retro_init', 'retro_deinit', 'retro_run',
                'retro_load_game', 'retro_unload_game', 'retro_get_system_info',
                'retro_get_system_av_info', 'retro_serialize', 'retro_unserialize',
                'retro_serialize_size', 'retro_get_memory_data', 'retro_get_memory_size',
                'retro_set_environment', 'retro_set_video_refresh',
                'retro_set_audio_sample', 'retro_set_audio_sample_batch',
                'retro_set_input_poll', 'retro_set_input_state', 'retro_set_controller_port_device'}


def read_entry(archive, name, limit=MAX_ENTRY_BYTES):
    try:
        entry = archive.getinfo(name)
    except KeyError as error:
        raise ValueError(f'Missing RomM package entry: {name}') from error
    if entry.flag_bits & 1 or not 0 < entry.file_size <= limit:
        raise ValueError(f'Invalid RomM package entry: {name}')
    return archive.read(entry)


def child_path(prefix, relative):
    path = PurePosixPath(relative)
    if not relative or path.is_absolute() or '..' in path.parts or '\\' in relative:
        raise ValueError('Invalid RomM receipt path')
    return prefix + relative


def check_romm(archive, abis, readelf, temporary, *, is_apk):
    names = set(archive.namelist())
    lib_prefix = 'lib/' if is_apk else 'base/lib/'
    asset_prefix = 'assets/romm-notices/' if is_apk else 'base/assets/romm-notices/'
    filenames = {'libplezy_retro.so', 'libplezy_retro_worker.so',
                 *(f'lib{core}_libretro.so' for core in DEFAULT_CORES)}
    expected = {f'{lib_prefix}{abi}/{name}' for abi in abis for name in filenames}
    actual = {name for name in names if name.split('/')[-1] in filenames}
    if actual != expected:
        raise ValueError(f'RomM ABI/library set differs: missing={sorted(expected-actual)}, unexpected={sorted(actual-expected)}')
    # Only the public proxy ABI belongs in the app. Worker audio functions are
    # intentionally absent; the service is entered through its separate JNI ABI.
    host = (ROOT / 'native/games/romm/retro_api.h').read_text()
    host_exports = set(re.findall(r'\bPLEZY_RETRO_EXPORT\s+[^\n(]*?\b(plezy_retro_\w+)\(', host))
    host_exports.add('Java_com_edde746_plezy_games_RommProcessBroker_initialize')
    worker_exports = {'Java_com_edde746_plezy_games_RommIsolatedService_runWorker'}
    if len(host_exports) < 10:
        raise ValueError('RomM host export contract is incomplete')
    artifacts = []
    for name in sorted(expected):
        abi = name.split('/')[-2]
        data = read_entry(archive, name)
        binary = Path(temporary) / name.split('/')[-1]
        binary.write_bytes(data)
        details = subprocess.check_output([str(readelf), '--wide', '--file-header',
            '--program-headers', '--dynamic', '--dyn-syms', str(binary)], text=True)
        exports = (host_exports if name.endswith('/libplezy_retro.so') else
                   worker_exports if name.endswith('/libplezy_retro_worker.so') else CORE_EXPORTS)
        inspect_elf(details, abi, exports)
        needed = set(re.findall(r'\(NEEDED\).*\[([^\]]+)\]', details))
        for dependency in needed - SYSTEM_LIBRARIES:
            if '/' in dependency or '\\' in dependency:
                raise ValueError('Invalid RomM runtime dependency')
            read_entry(archive, f'{lib_prefix}{abi}/{dependency}')
        artifacts.append({'file': name, 'abi': abi, 'sha256': hashlib.sha256(data).hexdigest(),
                          'exportsChecked': len(exports), 'bytes': len(data)})
    for abi in sorted(abis):
        prefix = asset_prefix + abi + '/'
        manifest = json.loads(read_entry(archive, prefix + 'romm-cores.json', 1024 * 1024))
        records = manifest.get('cores', [])
        if (manifest.get('schemaVersion') != 1 or manifest.get('platform') != 'Android'
                or manifest.get('architecture') != abi or len(records) != len(DEFAULT_CORES)
                or {row.get('core') for row in records} != DEFAULT_CORES):
            raise ValueError('RomM source receipt does not match the application ABI/core set')
        for row in records:
            core = row['core']
            if row.get('commit') != PINS[core]['commit']:
                raise ValueError('RomM source receipt uses an unexpected revision')
            archive_name = child_path(prefix, row['sourceArchive'])
            source = read_entry(archive, archive_name)
            if hashlib.sha256(source).hexdigest() != row.get('sourceSha256'):
                raise ValueError('RomM corresponding source digest differs')
            if not row.get('licenses'):
                raise ValueError('RomM license notices are missing')
            for license in row['licenses']:
                read_entry(archive, child_path(prefix, license))
    return artifacts
