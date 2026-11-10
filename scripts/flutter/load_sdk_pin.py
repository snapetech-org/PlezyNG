#!/usr/bin/env python3
"""Load the single reviewed application SDK pin, rejecting environment injection."""
import argparse
import json
import os
from pathlib import Path
import re

PATH = Path(__file__).with_name('sdk-pin.json')


def load(path=PATH):
    pin = json.loads(Path(path).read_text())
    if (not isinstance(pin, dict) or type(pin.get('schemaVersion')) is not int
            or pin['schemaVersion'] != 1
            or not isinstance(pin.get('version'), str)
            or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', pin['version'])
            or any(not isinstance(pin.get(k), str) or not re.fullmatch(r'[0-9a-f]{40}', pin[k])
                   for k in ('frameworkRevision', 'engineRevision'))):
        raise ValueError('Invalid immutable Flutter SDK manifest')
    return pin


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-env', action='store_true')
    args = parser.parse_args()
    pin = load()
    if args.github_env:
        with Path(os.environ['GITHUB_ENV']).open('a', encoding='utf-8') as output:
            output.write('FLUTTER_VERSION=' + pin['version'] + '\n')
    else:
        print(json.dumps(pin))
