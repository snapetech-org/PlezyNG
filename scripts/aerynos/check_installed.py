#!/usr/bin/env python3
"""Inspect every installed dynamic ELF, including private tools and plugins."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


def inspect(bundle, helper):
    spec = importlib.util.spec_from_file_location('bundle_elf', helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    missing, errors, count = {}, {}, 0
    for path in bundle.rglob('*'):
        if path.is_symlink() or not path.is_file() or not module.is_dynamic_elf(path):
            continue
        count += 1
        result = subprocess.run(['ldd', str(path)], capture_output=True, text=True)
        for line in (result.stdout + result.stderr).splitlines():
            if 'not found' in line:
                missing.setdefault(line.strip().split()[0], []).append(str(path.relative_to(bundle)))
        if result.returncode and 'not a dynamic executable' not in result.stderr:
            errors[str(path.relative_to(bundle))] = result.stderr
    if not count:
        errors['bundle'] = 'No installed dynamic ELF files inspected'
    return {'elf_count': count, 'missing': missing, 'errors': errors}


if __name__ == '__main__':
    result = inspect(Path(sys.argv[1]), Path(sys.argv[2]))
    print(json.dumps(result, indent=2))
    sys.exit(bool(result['missing'] or result['errors']))
