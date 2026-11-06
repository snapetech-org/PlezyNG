#!/usr/bin/env python3
"""Stage pinned Samsung providers for ordinary Android builds on every host.

SDK archives stay private. Only the provider and SDK object code
embedded in the app, with original licensing, enter the application bundle.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tarfile
import zipfile
import tempfile
import time
import urllib.request

SOURCE_COMMIT = '4352e261d3f1b3cda00345db5dbd75859d3bf0d3'
SDK_SHA256 = 'a107f154bfa9bfafa0e26789919d89aa4062dd22e24292c66fd4f912d9a3498f'
SDK_URL = 'https://soc-developer.semiconductor.samsung.com/api/v1/resource/download-file/ai-litecore-ubuntu2404-v1.2.0.tar.gz'
ADAPTER_SHA256 = 'c6cc754e1073eb36a8013823bbbb257c499daa0c2df1f7b4ec88b3b75a9b9662'
ADAPTER_URL = 'https://github.com/snapetech-org/mpv-build/releases/download/binaries-neural/litert-samsung-android-arm64-c6cc754e1073.zip'
SOURCE_PATCH = Path(__file__).with_name('android_litert_samsung_flatbuffers.patch')
PINS = {'litertCommit': SOURCE_COMMIT, 'sdkSha256': SDK_SHA256,
        'adapterSha256': ADAPTER_SHA256,
        'sourcePatchSha256': hashlib.sha256(SOURCE_PATCH.read_bytes()).hexdigest(),
        'packagingSchema': 2}
REQUIRED = ('arm64-v8a/libLiteRtCompilerPlugin_Samsung.so',
            'arm64-v8a/libLiteRtDispatch_Samsung.so',
            'Exynos_AI_LiteCore_License.pdf', 'LiteRT-LICENSE.txt') + tuple(
    'litecore/lib/arm64-v8a/' + name for name in (
        'libcdi_9955.so', 'libcdi_9965.so', 'libcdi_wrapper.so', 'libcommon.so',
        'libcompiler_api_lib.so', 'libgraph_wrapper.so', 'libgraphgen.so', 'libgraphgen_api.so',
        'libir.so', 'libisa.so', 'libncp_wrapper_lib.so', 'libnpu_compiler.so', 'libodt.so',
        'libsait_npu_compiler_lib.so', 'libsnc_api.so', 'libveriben_lib.so'))


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def cache_valid(output):
    try:
        receipt = json.loads((output / 'source.json').read_text())
        files = receipt['files']
        valid = receipt['inputs'] == PINS and all(name in files for name in REQUIRED) and all(
            not Path(name).is_absolute() and '..' not in Path(name).parts and
            sha256(output / name) == digest for name, digest in files.items())
        if not valid:
            return False
        for name in files:
            if name.endswith('.so'):
                with (output / name).open('rb') as library:
                    header = library.read(20)
                if header[:6] != b'\x7fELF\x02\x01' or header[18:20] != b'\xb7\x00':
                    return False
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def download(url, destination, expected):
    if destination.is_file() and sha256(destination) == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = None
    try:
        with tempfile.NamedTemporaryFile(prefix=destination.name + '.', dir=destination.parent,
                                         delete=False) as target:
            partial = Path(target.name)
            with urllib.request.urlopen(url, timeout=60) as response:
                while chunk := response.read(1024 * 1024):
                    target.write(chunk)
        if sha256(partial) != expected:
            raise ValueError(f'Pinned download checksum mismatch: {destination.name}')
        partial.replace(destination)
    finally:
        if partial is not None:
            partial.unlink(missing_ok=True)


def prepare(output, cache):
    if cache_valid(output):
        return
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    sdk_archive = cache / 'samsung-ai-litecore-1.2.0.tar.gz'
    adapter_archive = cache / 'litert-samsung-android-arm64-c6cc754e1073.zip'
    download(SDK_URL, sdk_archive, SDK_SHA256)
    download(ADAPTER_URL, adapter_archive, ADAPTER_SHA256)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.samsung-runtime-', dir=output.parent) as temporary:
        staged = Path(temporary) / 'payload'
        staged.mkdir()
        with tarfile.open(sdk_archive) as sdk:
            for name in REQUIRED:
                if name.startswith('litecore/'):
                    source = 'exynos-ai-litecore-v1.2.0/' + name.removeprefix('litecore/')
                elif name == 'Exynos_AI_LiteCore_License.pdf':
                    source = 'exynos-ai-litecore-v1.2.0/' + name
                else:
                    continue
                info = sdk.getmember(source)
                if not info.isfile() or not 0 < info.size <= 128 * 1024 * 1024:
                    raise ValueError('Invalid Samsung runtime member')
                destination = staged / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                with sdk.extractfile(info) as library:
                    destination.write_bytes(library.read())
        with zipfile.ZipFile(adapter_archive) as adapters:
            metadata = json.loads(adapters.read('source.json'))
            if metadata['sourceCommit'] != SOURCE_COMMIT or metadata['sdkLibrariesIncluded'] is not False:
                raise ValueError('Samsung adapter provenance differs from the pinned build')
            for name in REQUIRED[:2]:
                data = adapters.read(name)
                if hashlib.sha256(data).hexdigest() != metadata['files'][name]:
                    raise ValueError('Samsung adapter binary checksum mismatch')
                destination = staged / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            (staged / 'LiteRT-LICENSE.txt').write_bytes(adapters.read('LICENSE.txt'))
            (staged / 'adapter-source.json').write_bytes(adapters.read('source.json'))
        (staged / 'BUILD_INFO.txt').write_text(
            'LiteRT source tag: v2.3.0\nLiteRT source commit: ' + SOURCE_COMMIT +
            '\nAdapter archive SHA256: ' + ADAPTER_SHA256 + '\n')
        hashes = {path.relative_to(staged).as_posix(): sha256(path)
                  for path in staged.rglob('*') if path.is_file()}
        (staged / 'SHA256SUMS').write_text(''.join(
            f'{digest}  ./{name}\n' for name, digest in sorted(hashes.items()) if name.endswith('.so')))
        hashes['SHA256SUMS'] = sha256(staged / 'SHA256SUMS')
        (staged / 'source.json').write_text(json.dumps(
            {'inputs': PINS, 'files': hashes, 'executionQualified': False}, indent=2, sort_keys=True) + '\n')
        if not cache_valid(staged):
            raise ValueError('Samsung provider output failed architecture/integrity inspection')
        if output.exists():
            output.rename(output.with_name(output.name + f'.retained-{time.time_ns()}'))
        staged.rename(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cache', type=Path)
    args = parser.parse_args()
    # Do not place the proprietary SDK into Gradle/Actions public caches.
    private = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir()))
    cache = (args.cache or private / 'pleazyng-samsung-build').resolve()
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    prepare(args.output.resolve(), cache)


if __name__ == '__main__':
    main()
