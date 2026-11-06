#!/usr/bin/env python3
"""Render the bundled presets through an actual Linux EGL/native runtime.

Requires Mesa EGL or a compatible surfaceless driver and a source-built runtime.
This is a bounded software/driver smoke check, not device qualification. No
preset, texture, library or audio is downloaded by this check.
"""
from __future__ import annotations

import argparse
import ctypes as c
import ctypes.util
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
P, I, U, F, Z, Q = c.c_void_p, c.c_int, c.c_uint, c.c_float, c.c_size_t, c.c_uint64
LOADER = c.CFUNCTYPE(P, c.c_char_p)


def bind(library, name, result, arguments):
    function = getattr(library, name)
    function.restype, function.argtypes = result, arguments
    return function


def render(runtime: Path, profile: str):
    egl_name = ctypes.util.find_library('EGL')
    if not egl_name:
        raise RuntimeError('EGL is required for this native render check')
    egl = c.CDLL(egl_name)
    get = bind(egl, 'eglGetProcAddress', P, [c.c_char_p])
    error = bind(egl, 'eglGetError', I, [])
    get_platform = get(b'eglGetPlatformDisplayEXT')
    if not get_platform:
        raise RuntimeError('Surfaceless EGL display discovery is unavailable')
    platform = c.CFUNCTYPE(P, U, P, c.POINTER(I))(get_platform)
    display = platform(0x31DD, None, None)  # EGL_PLATFORM_SURFACELESS_MESA
    surface = context = None
    handle = 0
    native = None

    def require(value, action):
        if not value:
            raise RuntimeError(f'{action} failed: EGL {error():#x}')
        return value

    try:
        major, minor = I(), I()
        require(bind(egl, 'eglInitialize', U, [P, c.POINTER(I), c.POINTER(I)])(
            display, c.byref(major), c.byref(minor)), 'initialize')
        gles = profile == 'gles'
        require(bind(egl, 'eglBindAPI', U, [U])(0x30A0 if gles else 0x30A2), 'bind API')
        attrs = (I * 13)(0x3033, 1, 0x3040, 0x40 if gles else 8,
                         0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038)
        config, count = P(), I()
        require(bind(egl, 'eglChooseConfig', U, [P, c.POINTER(I), c.POINTER(P), I, c.POINTER(I)])(
            display, attrs, c.byref(config), 1, c.byref(count)) and count.value, 'choose config')
        surface = require(bind(egl, 'eglCreatePbufferSurface', P, [P, P, c.POINTER(I)])(
            display, config, (I * 5)(0x3057, 160, 0x3056, 90, 0x3038)), 'create pbuffer')
        context_attrs = ((I * 3)(0x3098, 3, 0x3038) if gles else
                         (I * 7)(0x3098, 3, 0x30FB, 3, 0x30FD, 1, 0x3038))
        context = require(bind(egl, 'eglCreateContext', P, [P, P, P, c.POINTER(I)])(
            display, config, None, context_attrs), 'create context')
        require(bind(egl, 'eglMakeCurrent', U, [P, P, P, P])(
            display, surface, surface, context), 'make current')
        gl_string = c.CFUNCTYPE(c.c_char_p, U)(get(b'glGetString'))
        renderer, version = gl_string(0x1F01).decode(), gl_string(0x1F02).decode()
        native = c.CDLL(str(runtime))
        if bind(native, 'milkrust_abi_version', U, [])() != 2:
            raise RuntimeError('Expected the application ABI v2')
        create = bind(native, 'milkrust_create', Q, [LOADER, I])
        load = bind(native, 'milkrust_load', I, [Q, P, Z])
        pcm = bind(native, 'milkrust_pcm', I, [Q, P, Z, U])
        draw = bind(native, 'milkrust_render_rgba', I, [Q, U, U, c.c_double, P, Z])
        destroy = bind(native, 'milkrust_destroy', I, [Q])
        last_error = bind(native, 'milkrust_last_error', Z, [P, Z])
        loader = LOADER(lambda name: get(name))  # Keep the callback alive through teardown.

        def native_check(result, action):
            if result != 0:
                message = c.create_string_buffer(4096)
                last_error(message, len(message))
                raise RuntimeError(f'{action}: {message.value.decode(errors="replace")}')

        results = []
        with zipfile.ZipFile(ROOT / 'assets/visualizer/milkrust-sample-pack-0.1.0.rmpack') as pack:
            presets = [name for name in pack.namelist() if name.endswith('.milk')]
            if not presets:
                raise RuntimeError('The bundled pack has no presets to exercise')
            for name in presets:
                handle = create(loader, int(gles))
                if not handle:
                    native_check(-1, 'create')
                source = pack.read(name)
                native_check(load(handle, source, len(source)), 'load ' + name)
                pixels = (c.c_ubyte * (160 * 90 * 4))()
                hashes = []
                for frame in range(12):
                    samples = (F * 2048)(*[
                        .3 * math.sin(2 * math.pi * 440 * ((frame * 1024 + i // 2) / 44100))
                        for i in range(2048)])
                    native_check(pcm(handle, samples, 1024, 1), 'PCM')
                    native_check(draw(handle, 160, 90, frame / 30, pixels, len(pixels)), 'render')
                    hashes.append(hashlib.sha256(bytes(pixels)).hexdigest())
                rgb = [pixels[i] for i in range(len(pixels)) if i % 4 != 3]
                if len(set(hashes)) <= 1 or max(rgb) == 0 or len(set(rgb)) <= 8:
                    raise RuntimeError(f'{name}: static, blank or flat render output')
                native_check(destroy(handle), 'destroy')
                handle = 0
                results.append({'preset': name, 'frames': len(hashes),
                                'differentFrames': len(set(hashes)), 'rgbValues': len(set(rgb)),
                                'finalFrameSha256': hashes[-1]})
        if len(results) > 1 and len({result['finalFrameSha256'] for result in results}) != len(results):
            raise RuntimeError('Distinct bundled presets produced the same output')
        print(json.dumps({'profile': profile, 'version': version, 'renderer': renderer,
                          'presets': results, 'deviceQualified': False}), flush=True)
    finally:
        if handle and native:
            native.milkrust_destroy(handle)
        if display:
            bind(egl, 'eglMakeCurrent', U, [P, P, P, P])(display, None, None, None)
            if context:
                bind(egl, 'eglDestroyContext', U, [P, P])(display, context)
            if surface:
                bind(egl, 'eglDestroySurface', U, [P, P])(display, surface)
            bind(egl, 'eglTerminate', U, [P])(display)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--profile', choices=('gl', 'gles'), default='gles')
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    runtime = args.runtime.resolve(strict=True)
    if args.worker:
        render(runtime, args.profile)
    else:
        # Bound a driver/compiler hang independently of the native call stack.
        subprocess.run([sys.executable, str(Path(__file__).resolve()), '--worker',
                        '--runtime', str(runtime), '--profile', args.profile], check=True, timeout=30)
