#!/usr/bin/env python3
"""Store-only v3.0.7 version166 ->167 repack; never rebuilds application code."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

SOURCE_SHA256 = 'eb4b5836a86df75297d9465a80fb251eb44e7e2d06aaeda1665e004a6b0445dd'
BUNDLETOOL_SHA256 = 'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29'
MANIFEST = 'base/manifest/AndroidManifest.xml'
SIGNATURE = re.compile(r'META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))', re.I)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def payload_hashes(path):
    with zipfile.ZipFile(path) as bundle:
        names = bundle.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate bundle entries')
        result = {}
        for entry in bundle.infolist():
            if not entry.is_dir() and not SIGNATURE.fullmatch(entry.filename):
                with bundle.open(entry) as stream:
                    result[entry.filename] = hashlib.file_digest(stream, 'sha256').hexdigest()
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--bundletool', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--verify-signed', action='store_true')
    args = parser.parse_args()
    if digest(args.source) != SOURCE_SHA256 or digest(args.bundletool) != BUNDLETOOL_SHA256:
        raise ValueError('Expected original immutable v3.0.7 AAB and pinned official bundletool1.18.3')
    if args.source.resolve() == args.output.resolve():
        raise ValueError('Original artifact must never be overwritten')
    if args.verify_signed:
        receipt = json.loads(args.receipt.read_text())
        expected = payload_hashes(args.source)
        expected[MANIFEST] = receipt['repacked_manifest_sha256']
        if payload_hashes(args.output) != expected:
            raise ValueError('Signed repack contains unexpected changed, missing or added payload entries')
        receipt.update(signed_upload_sha256=digest(args.output),
                       all_signed_payload_entries_verified=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
        print('Signed repack preserves every original payload except the version-code manifest')
        return
    if args.output.exists():
        raise ValueError('Refusing to overwrite an existing repack')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    tool = args.bundletool.resolve()
    original_hashes = payload_hashes(args.source)
    with tempfile.TemporaryDirectory(prefix='play-repack-', dir=args.output.parent) as temporary:
        scratch = Path(temporary)
        classes = scratch / 'classes'
        classes.mkdir()
        subprocess.run(['javac', '-cp', str(tool), '-d', str(classes),
                        str(Path(__file__).with_name('ReversionPlayManifest.java'))], check=True)
        with zipfile.ZipFile(args.source) as original:
            if [n for n in original.namelist() if n.endswith('/manifest/AndroidManifest.xml')] != [MANIFEST]:
                raise ValueError('Unexpected module manifest set')
            before = scratch / 'original.pb'
            after = scratch / 'repacked.pb'
            before.write_bytes(original.read(MANIFEST))
            subprocess.run(['java', '-cp', f'{classes}:{tool}', 'ReversionPlayManifest',
                            str(before), str(after)], check=True)
            patched = after.read_bytes()
            with zipfile.ZipFile(args.output, 'x', allowZip64=True) as output:
                for entry in original.infolist():
                    if SIGNATURE.fullmatch(entry.filename):
                        continue
                    if entry.filename == MANIFEST:
                        output.writestr(copy.copy(entry), patched)
                    else:
                        with original.open(entry) as source, output.open(copy.copy(entry), 'w') as destination:
                            shutil.copyfileobj(source, destination, length=1024 * 1024)
    expected = dict(original_hashes)
    expected[MANIFEST] = hashlib.sha256(patched).hexdigest()
    if payload_hashes(args.output) != expected:
        raise ValueError('Unexpected payload difference in repacked bundle')
    if digest(args.source) != SOURCE_SHA256:
        raise ValueError('Original release artifact changed')
    receipt = {
        'source_release': 'v3.0.7', 'source_aab_sha256': SOURCE_SHA256,
        'package': 'org.snapetech.pleazyng', 'version_name': '3.0.7',
        'original_version_code': 166, 'store_version_code': 167,
        'reason': 'Google reserves archived166 but cannot attach it or accept its reupload',
        'build_performed': False, 'original_artifact_modified': False,
        'changed_payload_entries': [MANIFEST], 'payload_entry_count': len(expected),
        'original_manifest_sha256': original_hashes[MANIFEST],
        'repacked_manifest_sha256': expected[MANIFEST],
        'compiled_code_and_other_resources_identical': True,
        'bundletool': {'version': '1.18.3', 'sha256': BUNDLETOOL_SHA256},
        'unsigned_repack_sha256': digest(args.output),
    }
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'Verified {len(expected)} payload entries; only the manifest version code changed')


if __name__ == '__main__':
    main()
