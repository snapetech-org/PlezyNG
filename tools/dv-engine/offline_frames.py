#!/usr/bin/env python3
"""Bounded raw-frame worker for the bundled converter's generated recipe."""
import argparse
from pathlib import Path
import sys


def main():
    root = Path(sys.executable).resolve().parents[1]
    sys.path.insert(0, str(root / 'lib/python3.12/site-packages'))
    import vapoursynth as vs
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', action='store_true')
    parser.add_argument('--requests', type=int, default=2)
    parser.add_argument('script', type=Path, nargs='?')
    parser.add_argument('output', nargs='?', default='-')
    args = parser.parse_args()
    if args.version:
        print('PlezyNG offline raw-frame worker; VapourSynth ' + str(vs.__version__))
        return
    if args.script is None or args.output != '-' or not 1 <= args.requests <= 2:
        parser.error('provide a local generated script, stdout output and at most two frame requests')
    vs.core.num_threads = 2
    script = args.script.resolve(strict=True)
    scope = {'__name__': '__vapoursynth__', '__file__': str(script)}
    exec(compile(script.read_bytes(), str(script), 'exec'), scope)
    clip = vs.get_output(0).clip
    clip.output(sys.stdout.buffer, y4m=False, prefetch=args.requests)


if __name__ == '__main__':
    main()
