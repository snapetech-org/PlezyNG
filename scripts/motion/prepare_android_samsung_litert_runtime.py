#!/usr/bin/env python3
"""Build the pinned Samsung provider for ordinary Android release packaging.

SDK inputs and Bazel caches stay private. Only the provider and SDK object code
embedded in the app, with original licensing, enter the application bundle.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request

SOURCE_COMMIT = '4352e261d3f1b3cda00345db5dbd75859d3bf0d3'
SDK_SHA256 = 'a107f154bfa9bfafa0e26789919d89aa4062dd22e24292c66fd4f912d9a3498f'
SDK_URL = 'https://soc-developer.semiconductor.samsung.com/api/v1/resource/download-file/ai-litecore-ubuntu2404-v1.2.0.tar.gz'
BAZEL_SHA256 = 'fe7e799cbc9140f986b063e06800a3d4c790525075c877d00a7112669824acbf'
BAZEL_URL = 'https://github.com/bazelbuild/bazel/releases/download/7.7.0/bazel-7.7.0-linux-x86_64'
SOURCE_PATCH = Path(__file__).with_name('android_litert_samsung_flatbuffers.patch')
PINS = {'litertCommit': SOURCE_COMMIT, 'sdkSha256': SDK_SHA256, 'bazelSha256': BAZEL_SHA256,
        'sourcePatchSha256': hashlib.sha256(SOURCE_PATCH.read_bytes()).hexdigest(),
        'packagingSchema': 1}
REQUIRED = ('arm64-v8a/libLiteRtCompilerPlugin_Samsung.so',
            'arm64-v8a/libLiteRtDispatch_Samsung.so',
            'Exynos_AI_LiteCore_License.pdf') + tuple(
    'litecore/lib/arm64-v8a/' + name for name in (
        'libcdi_9955.so', 'libcdi_9965.so', 'libcdi_wrapper.so', 'libcommon.so',
        'libcompiler_api_lib.so', 'libgraph_wrapper.so', 'libgraphgen.so', 'libgraphgen_api.so',
        'libir.so', 'libisa.so', 'libncp_wrapper_lib.so', 'libnpu_compiler.so', 'libodt.so',
        'libsait_npu_compiler_lib.so', 'libsnc_api.so', 'libveriben_lib.so'))


def sha256(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


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
    partial = destination.with_suffix(destination.suffix + '.partial')
    try:
        with urllib.request.urlopen(url, timeout=60) as response, partial.open('wb') as target:
            shutil.copyfileobj(response, target)
        if sha256(partial) != expected:
            raise ValueError(f'Pinned download checksum mismatch: {destination.name}')
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def prepare(output, cache):
    if cache_valid(output):
        return
    if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'AMD64'):
        raise RuntimeError('Build Samsung Android providers on the supported Linux x64 release host')
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    sdk_archive = cache / 'samsung-ai-litecore-1.2.0.tar.gz'
    download(SDK_URL, sdk_archive, SDK_SHA256)
    sdk = cache / 'samsung-sdk' / 'exynos-ai-litecore-v1.2.0'
    if not (sdk / 'include/graph_wrapper_api.h').is_file():
        with tarfile.open(sdk_archive) as archive:
            archive.extractall(cache / 'samsung-sdk', filter='data')

    source = cache / 'LiteRT'
    if not source.exists():
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', 'v2.3.0',
                        'https://github.com/google-ai-edge/LiteRT.git', str(source)], check=True)
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != SOURCE_COMMIT:
        raise ValueError('LiteRT source does not match the pinned v2.3.0 commit')
    applied = subprocess.run(['git', '-C', str(source), 'apply', '--reverse', '--check', str(SOURCE_PATCH)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not applied:
        subprocess.run(['git', '-C', str(source), 'apply', str(SOURCE_PATCH)], check=True)

    tools = cache / 'tools'
    tools.mkdir(exist_ok=True)
    binary = tools / 'bazel-7.7.0-linux-x86_64'
    download(BAZEL_URL, binary, BAZEL_SHA256)
    binary.chmod(0o755)
    # A private Bazel server and bounded parallelism avoid mutating or shutting
    # down another build's server. The wrapper uses Python string literals and
    # execv so paths never pass through shell expansion.
    wrapper = tools / 'bazel'
    wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\n'
        f'args=[{str(binary)!r}, {"--output_user_root=" + str(cache / "bazel")!r}, '
        '"--host_jvm_args=-XX:ActiveProcessorCount=2", "--host_jvm_args=-Xmx3g"]+sys.argv[1:]\n'
        'if sys.argv[1:2]==["build"]: args += ["--jobs=2", "--local_ram_resources=4096"]\n'
        'os.execv(args[0],args)\n')
    wrapper.chmod(0o755)
    if output.exists():
        output.rename(output.with_name(output.name + f'.retained-{time.time_ns()}'))
    output.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                       PLEZY_LITERT_SOURCE_ROOT=str(source), EXYNOS_AI_LITECORE_ROOT=str(sdk),
                       PLEZY_LITERT_SAMSUNG_RUNTIME_OUTPUT=str(output))
    sdk_root = environment.get('ANDROID_HOME') or environment.get('ANDROID_SDK_ROOT')
    if sdk_root:
        environment.setdefault('ANDROID_SDK_HOME', sdk_root)
        ndk = Path(sdk_root) / 'ndk/29.0.14206865'
        if ndk.is_dir():
            environment.setdefault('ANDROID_NDK_HOME', str(ndk))
    builder = Path(__file__).with_name('build_android_samsung_litert_runtime.sh')
    try:
        subprocess.run(['bash', str(builder)], env=environment, check=True)
    finally:
        subprocess.run([str(wrapper), 'shutdown'], env=environment, cwd=source, check=False)
    shutil.copy2(sdk / 'Exynos_AI_LiteCore_License.pdf', output)
    files = {str(path.relative_to(output)): sha256(path)
             for path in output.rglob('*') if path.is_file()}
    if any(name not in files for name in REQUIRED):
        raise ValueError('Samsung runtime is missing required compiled components')
    (output / 'source.json').write_text(json.dumps(
        {'inputs': PINS, 'files': files, 'executionQualified': False}, indent=2, sort_keys=True) + '\n')
    if not cache_valid(output):
        raise ValueError('Samsung provider output failed architecture/integrity inspection')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cache', type=Path)
    args = parser.parse_args()
    # Do not place the proprietary SDK into Gradle/Actions public caches.
    private = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir()))
    cache = (args.cache or private / 'pleazyng-samsung-build').resolve()
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (cache / '.build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prepare(args.output.resolve(), cache)


if __name__ == '__main__':
    main()
