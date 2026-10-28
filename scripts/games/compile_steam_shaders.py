#!/usr/bin/env python3
"""Rebuild/check the Vulkan presenter shaders; no compiler is needed at app startup."""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SHADERS = ROOT / 'native/games/steam/shaders'


def compile_shaders(compiler):
    result = ('// SPDX-License-Identifier: GPL-3.0-or-later\n'
              '// Generated from steam_video.vert/.frag; regenerate with scripts/games/compile_steam_shaders.py.\n'
              '#pragma once\n#include <cstdint>\n// clang-format off\n')
    with tempfile.TemporaryDirectory(prefix='steam-shaders-') as directory:
        for extension, name in [('vert', 'Vertex'), ('frag', 'Fragment')]:
            output = Path(directory) / (extension + '.spv')
            subprocess.run([compiler, '-V', '--target-env', 'vulkan1.1', '-o', str(output),
                            str(SHADERS / ('steam_video.' + extension))], check=True)
            data = output.read_bytes()
            words = struct.unpack('<' + 'I' * (len(data) // 4), data)
            result += 'inline constexpr uint32_t kSteamVideo' + name + '[] = {\n'
            for index in range(0, len(words), 8):
                result += '  ' + ', '.join(f'0x{word:08x}' for word in words[index:index+8]) + ',\n'
            result += '};\n'
    return result + '// clang-format on\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--compiler', default=shutil.which('glslang') or shutil.which('glslangValidator'))
    args = parser.parse_args()
    if not args.compiler:
        parser.error('glslang 15.1.0 is required (the committed SPIR-V producer)')
    content = compile_shaders(args.compiler)
    output = SHADERS / 'steam_video_spirv.h'
    if args.check:
        if output.read_text() != content:
            raise SystemExit('Steam shader output differs; regenerate with glslang 15.1.0')
    else:
        output.write_text(content)


if __name__ == '__main__':
    main()
