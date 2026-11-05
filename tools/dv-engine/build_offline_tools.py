#!/usr/bin/env python3
"""Build the self-contained offline converter bundled in normal Linux packages."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import sysconfig
import tarfile
import urllib.request

from build_adapters import checkout, patch_felbaker_vs_output_key

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ENCODER_FLAGS = [
    '--disable-autodetect', '--disable-doc', '--disable-debug', '--disable-network', '--disable-everything',
    '--enable-gpl', '--enable-version3', '--enable-libx264', '--enable-libx265', '--enable-libzimg',
    '--enable-protocol=file,pipe', '--enable-demuxer=hevc,rawvideo,matroska,mov,mpegts', '--enable-muxer=matroska',
    '--enable-parser=hevc,h264,aac,aac_latm,ac3,dca,mpegaudio,flac,opus,vorbis',
    '--enable-decoder=rawvideo,hevc,h264,aac,aac_latm,ac3,eac3,dca,truehd,mlp,flac,alac,opus,vorbis,mp3,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le',
    '--enable-encoder=libx264,libx265,aac', '--enable-filter=zscale,format,tonemap,scale,aresample,apad,anull,null',
    '--enable-ffmpeg', '--enable-ffprobe',
]


def run(arguments, *, cwd=None, capture=False):
    result = subprocess.run(list(map(str, arguments)), cwd=cwd, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def package_runtime(work: Path, wheel_site: Path, encoder: Path, baker: Path) -> Path:
    root = work / 'bundle'
    root.mkdir()
    for directory in ('bin', 'plugins', 'share', 'notices'):
        (root / directory).mkdir()
    shutil.copytree(sysconfig.get_path('stdlib'), root / 'lib/python3.12',
                    ignore=shutil.ignore_patterns('__pycache__', 'test', 'tests', 'site-packages', 'dist-packages', 'ensurepip', 'idlelib'))
    shutil.copy2(Path(sys.executable).resolve(), root / 'bin/python3.12')
    for source in wheel_site.iterdir():
        if not source.name.startswith('vapoursynth'):
            continue
        target = root / 'lib/python3.12/site-packages' / source.name
        target.parent.mkdir(exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, ignore=shutil.ignore_patterns('__pycache__'))
        else:
            shutil.copy2(source, target)
    for name in ('ffmpeg', 'ffprobe'):
        shutil.copy2(encoder / 'bin' / name, root / 'bin' / name)
    shutil.copy2(baker / 'libfelbaker.so', root / 'plugins')
    for name in ('offline_cli.py', 'offline_frames.py', 'companion.py'):
        shutil.copy2(HERE / name, root / 'share' / name)
    libraries = root / 'lib/runtime'
    libraries.mkdir()
    libpython = Path(sysconfig.get_config_var('LIBDIR')) / sysconfig.get_config_var('LDLIBRARY')
    shutil.copy2(libpython.resolve(), libraries / libpython.name)
    skip = ('libc.so', 'libm.so', 'libpthread.so', 'librt.so', 'libdl.so', 'ld-linux', 'linux-vdso', 'libresolv.so', 'libutil.so')
    queue = []
    for path in root.rglob('*'):
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) == b'\x7fELF':
                    queue.append(path)
    seen = set()
    while queue:
        path = queue.pop()
        if path in seen:
            continue
        seen.add(path)
        result = subprocess.run(['ldd', str(path)], text=True, capture_output=True)
        if 'not found' in result.stdout:
            raise ValueError(result.stdout)
        for name, filename in re.findall(r'^\s*(\S+) => (/\S+)', result.stdout, re.M):
            if name.startswith(skip):
                continue
            source = Path(filename)
            if source.is_relative_to(root):
                continue
            target = libraries / name
            if not target.exists():
                shutil.copy2(source, target)
                queue.append(target)
    template = '''#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")RELATIVE" && pwd)"
export LD_LIBRARY_PATH="$root/lib/runtime"
export PYTHONHOME="$root"
export PYTHONPATH="$root/lib/python3.12/site-packages"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
unset VAPOURSYNTH_EXTRA_PLUGIN_PATH
exec "$root/bin/python3.12" -I -B "$root/share/SCRIPT" "$@"
'''
    for relative, script, parent in (('plezyng-dv-convert', 'offline_cli.py', ''),
                                     ('bin/plezyng-dv-frames', 'offline_frames.py', '/..')):
        launcher = root / relative
        launcher.write_text(template.replace('RELATIVE', parent).replace('SCRIPT', script))
        launcher.chmod(0o755)
    return root


def build(work: Path, lock: dict):
    if any(work.iterdir()):
        raise ValueError('use a new empty build directory; share Cargo/download caches separately')
    if sys.version_info[:2] != (3, 12):
        raise ValueError('offline runtime requires the pinned Ubuntu Python 3.12 ABI')
    for command, expected in ((['rustc', '--version'], lock['toolchain']['rust']),
                              (['meson', '--version'], lock['toolchain']['meson']),
                              (['cargo', 'cinstall', '--version'], lock['toolchain']['cargo_c'])):
        if expected not in run(command, capture=True):
            raise ValueError('build tool version does not match offline.lock.json')
    sources = work / 'sources'
    sources.mkdir()
    producer = sources / 'producer'
    checkout(producer, lock['sources']['producer'])
    ffmpeg = sources / 'ffmpeg'
    run(['python3', 'scripts/patches.py', 'fetch-pinned', 'ffmpeg', 'linux', ffmpeg], cwd=producer)
    felbaker = sources / 'felbaker'
    checkout(felbaker, lock['sources']['felbaker'])
    patch_felbaker_vs_output_key(felbaker)
    manifest = felbaker / 'meson.build'
    original = manifest.read_text()
    portable = original.replace("['-march=x86-64-v3', 'x86-64-v3']", "['-mtune=generic', 'generic']").replace(
        "['-march=armv8.2-a', 'oryon-1', '-mtune=oryon-1']", "['-mtune=generic', 'generic']").replace(
        "cargo, 'cinstall', '--release',", "cargo, 'cinstall', '--release', '--locked',")
    if portable == original or "'--release', '--locked'" not in portable:
        raise ValueError('FelBaker build options changed; review the portable/locked patch')
    manifest.write_text(portable)
    baker_build = work / 'felbaker-build'
    run(['meson', 'setup', baker_build, felbaker, '--wrap-mode=nofallback', '-Dcpu_tier=generic', '-Dtests=false'])
    run(['meson', 'compile', '-C', baker_build, '-j', '2'])
    encoder = work / 'encoder'
    encoder_build = work / 'encoder-build'
    encoder_build.mkdir()
    run([ffmpeg / 'configure', f'--prefix={encoder}', *ENCODER_FLAGS], cwd=encoder_build)
    run(['make', '-j2'], cwd=encoder_build)
    run(['make', 'install'], cwd=encoder_build)
    wheels = work / 'wheels'
    wheels.mkdir()
    wheel_site = work / 'python-site'
    wheel_paths = []
    for entry in lock['wheels']['linux-' + platform.machine()]:
        archive = wheels / entry['name']
        urllib.request.urlretrieve(entry['url'], archive)
        if digest(archive) != entry['sha256']:
            raise ValueError('published wheel hash mismatch')
        wheel_paths.append(archive)
    run([sys.executable, '-m', 'pip', 'install', '--no-deps', '--target', wheel_site, *wheel_paths])
    root = package_runtime(work, wheel_site, encoder, baker_build)
    notices = root / 'notices'
    for component, tree in (('ffmpeg', ffmpeg), ('felbaker', felbaker),
                            ('dovi-tool', felbaker / 'external/dovi_tool'),
                            ('libdovi', felbaker / 'external/dovi_tool/dolby_vision')):
        for path in tree.iterdir():
            if path.is_file() and path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
                shutil.copy2(path, notices / (component + '-' + path.name))
    for package in ('python3.12', 'libpython3.12-stdlib', 'libx264-164', 'libx265-199', 'libzimg2'):
        source = Path('/usr/share/doc') / package / 'copyright'
        if not source.is_file():
            raise ValueError(f'missing runtime copyright notice: {package}')
        shutil.copy2(source, notices / (package + '-copyright'))
    report = {'schema_version': 1, 'lock': lock, 'encoder_flags': ENCODER_FLAGS,
              'architecture': platform.machine(), 'activation': 'runtime-command',
              'device_qualification': 'unqualified',
              'system_packages': run(['dpkg-query', '-W', '-f=${Package}\t${Version}\n'], capture=True),
              'files': {str(path.relative_to(root)): digest(path) for path in sorted(root.rglob('*')) if path.is_file()}}
    (root / 'provenance.json').write_text(json.dumps(report, indent=2) + '\n')
    run([root / 'plezyng-dv-convert', '--self-test'])
    archive = work / ('PlezyNG-dv-tools-linux-' + platform.machine() + '.tar.zst')
    run(['tar', '--zstd', '-cf', archive, '-C', root, '.'])
    (work / (archive.name + '.sha256')).write_text(digest(archive) + '  ' + archive.name + '\n')
    print(archive)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    lock = json.loads((HERE / 'offline.lock.json').read_text())
    work = args.work_dir.absolute()
    work.mkdir(parents=True, exist_ok=True)
    if args.inside:
        build(work, lock)
    else:
        image = 'plezyng-dv-tools-' + hashlib.sha256((HERE / 'Offline.Dockerfile').read_bytes()).hexdigest()[:12]
        run(['docker', 'build', '--build-arg', 'RUST_IMAGE=' + lock['toolchain']['rust_images'][platform.machine()],
             '-f', HERE / 'Offline.Dockerfile', '-t', image, HERE])
        run(['docker', 'run', '--rm', '--cpus=2', '-v', f'{ROOT}:/appsrc:ro', '-v', f'{work}:/task',
             image, '--work-dir', '/task/build'])


if __name__ == '__main__':
    main()
