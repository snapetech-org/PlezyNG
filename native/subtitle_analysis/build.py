#!/usr/bin/env python3
"""Build an audio-only FFmpeg helper with an explicit target SDK; never run it."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = json.loads((ROOT / 'ffmpeg.lock.json').read_text())


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def source(destination: Path):
    if destination.exists():
        raise ValueError('Source destination must be new')
    destination.mkdir(parents=True)
    run('git', 'init', destination)
    run('git', '-C', destination, 'remote', 'add', 'origin', PIN['repository'])
    run('git', '-C', destination, 'fetch', '--depth', '1', 'origin', PIN['revision'])
    run('git', '-C', destination, 'checkout', '--detach', 'FETCH_HEAD')
    verify_source(destination)


def verify_source(directory: Path):
    revision = subprocess.check_output(['git', '-C', str(directory), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(directory), 'status', '--porcelain', '--untracked-files=no'], text=True)
    if revision != PIN['revision'] or dirty or not (directory / 'configure').is_file():
        raise ValueError('Decoder sources differ from the pinned, unmodified FFmpeg tree')


def build(args):
    src, output = Path(args.source).resolve(strict=True), Path(args.output).resolve()
    verify_source(src)
    if not args.sysroot or not Path(args.sysroot).is_dir(): raise ValueError('A target SDK sysroot is required')
    if args.arch not in {'arm', 'aarch64', 'x86_64'}: raise ValueError('Unsupported target architecture')
    cc = Path(args.cc).resolve(strict=True)
    ar = Path(args.ar).resolve(strict=True)
    output.mkdir(parents=True, exist_ok=True)
    configure = [str(src / 'configure'), '--target-os=linux', '--enable-cross-compile', f'--arch={args.arch}',
        f'--cc={cc}', f'--ar={ar}', f'--sysroot={Path(args.sysroot).resolve()}',
        f'--extra-cflags={args.cflags}', f'--extra-ldflags={args.ldflags}',
        '--disable-autodetect', '--disable-gpl', '--disable-nonfree', '--disable-shared', '--enable-static',
        '--disable-debug', '--disable-doc', '--disable-stripping', '--disable-asm', '--enable-small',
        '--disable-everything', '--disable-programs', '--enable-ffmpeg', '--disable-avdevice', '--disable-swscale',
        '--enable-network', '--enable-protocol=file,http,tcp,pipe',
        '--enable-demuxer=matroska,mov,avi,mp3,wav,flac,ogg,aac,ac3,eac3,mpegts,mpeg,aiff,caf',
        '--enable-decoder=aac,aac_fixed,ac3,eac3,dca,flac,mp3,mp3float,opus,vorbis,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be',
        '--enable-parser=aac,aac_latm,ac3,dca,flac,mpegaudio,opus,vorbis',
        '--enable-encoder=pcm_s16le', '--enable-muxer=wav',
        '--enable-filter=abuffer,abuffersink,aresample,aformat,anull']
    signature = hashlib.sha256(json.dumps({'source': PIN, 'configure': configure}, sort_keys=True).encode()).hexdigest()
    stamp = output / 'configure-key.txt'
    if stamp.exists() and stamp.read_text() != signature: raise ValueError('Use a clean decoder build directory after changing SDK/configuration')
    run(*configure, cwd=output)
    stamp.write_text(signature)
    run('make', f'-j{args.jobs}', 'ffmpeg', cwd=output)
    target = output / 'plezy-subtitle-ffmpeg'
    shutil.copyfile(output / 'ffmpeg', target); target.chmod(0o755)
    if target.stat().st_size > 128*1024*1024: raise ValueError('Audio helper exceeds 128 MiB')
    with target.open('rb') as stream: header = stream.read(64)
    machine = int.from_bytes(header[18:20], 'little')
    if header[:6] != b'\x7fELF' + bytes([1 if args.arch == 'arm' else 2, 1]) or machine != {'arm':40, 'aarch64':183, 'x86_64':62}[args.arch]:
        raise ValueError('The SDK produced the wrong executable architecture')
    receipt = {'schema': 1, 'source': PIN, 'architecture': args.arch, 'configure': configure,
        'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'qualified': False,
        'licenseSha256': hashlib.sha256((src / 'COPYING.LGPLv2.1').read_bytes()).hexdigest(),
        'execution': 'not-executed-by-builder'}
    (output / 'subtitle-analysis-build.json').write_text(json.dumps(receipt, indent=2) + '\n')
    shutil.copyfile(src / 'COPYING.LGPLv2.1', output / 'COPYING.LGPLv2.1')
    shutil.copyfile(src / 'LICENSE.md', output / 'FFmpeg-LICENSE.md')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare = commands.add_parser('source'); prepare.add_argument('--destination', required=True)
    compile = commands.add_parser('build')
    for name in ('source','output','cc','ar','sysroot','arch'): compile.add_argument('--'+name, required=True)
    compile.add_argument('--cflags', default=''); compile.add_argument('--ldflags', default='')
    compile.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if args.command == 'source': source(Path(args.destination).resolve())
    else:
        if not 1 <= args.jobs <= 64: parser.error('jobs must be 1..64')
        build(args)

if __name__ == '__main__': main()
