#!/usr/bin/env python3
"""Bundled, offline FEL-derived HDR10/SDR export; never downloads components."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(sys.executable).resolve().parents[1]
    sys.path.insert(0, str(root / 'lib/python3.12/site-packages'))
    site = root / 'lib/python3.12/site-packages/vapoursynth'
    tools = {
        'vspipe': root / 'bin/plezyng-dv-frames', 'ffms-plugin': site / 'plugins/libffms2.so',
        'felbaker-plugin': root / 'plugins/libfelbaker.so',
        'ffmpeg': root / 'bin/ffmpeg', 'ffprobe': root / 'bin/ffprobe',
    }
    if sys.argv[1:] == ['--self-test']:
        for path in tools.values():
            if not path.is_file():
                raise RuntimeError(f'bundled dependency is missing: {path.name}')
        import vapoursynth as vs
        vs.core.num_threads = 2
        vs.core.std.LoadPlugin(str(tools['felbaker-plugin']))
        namespaces = {p.namespace for p in vs.core.plugins()}
        if not {'ffms2', 'fel'} <= namespaces:
            raise RuntimeError('bundled decode/composition plugins did not load')
        encoders = subprocess.check_output([str(tools['ffmpeg']), '-hide_banner', '-encoders'], text=True)
        filters = subprocess.check_output([str(tools['ffmpeg']), '-hide_banner', '-filters'], text=True)
        if not all(name in encoders for name in ('libx264', 'libx265', 'aac')) or not all(name in filters for name in ('zscale', 'tonemap')):
            raise RuntimeError('bundled encoder is missing HDR/SDR output support')
        subprocess.run([str(tools['vspipe']), '--version'], check=True, stdout=subprocess.DEVNULL)
        print(json.dumps({'dependencies': 'passed', 'network_downloads': False, 'device_output_qualified': False}))
        return 0
    spec = importlib.util.spec_from_file_location('plezyng_dv_companion', Path(__file__).with_name('companion.py'))
    companion = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(companion)
    return companion.main(bundled_tools=tools)


if __name__ == '__main__':
    raise SystemExit(main())
