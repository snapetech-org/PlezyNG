#!/usr/bin/env python3
"""Independently verify a reviewed packaging repair of a frozen release.

The caller must separately verify artifact attestations and trusted workflow/run
identities. A recovery receipt alone never establishes product equivalence.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
from pathlib import PurePosixPath
import re

REPOSITORY = 'snapetech-org/pleazyng'
REPOSITORY_ID = 1433487464
APPROVAL_PATH = '.github/release-packaging-repairs.json'
POLICY = 'frozen-apple-packaging-v1'
# Each allowed path still requires the exact reviewed repair commit and blob.
# Application sources, manifests, dependency/native pins and project files are
# deliberately absent. This is not a general executable-script exception.
ALLOWED_REPAIR_FILES = frozenset({
    '.github/workflows/build.yml',
    'scripts/release_all_platforms.py',
    'scripts/recover_release_platforms.py',
    'scripts/build_apple_store_archive.py',
    'scripts/clean_appledouble_sidecars.sh',
    'scripts/checks/test_clean_appledouble_sidecars.py',
    'scripts/test_build_apple_store_archive.py',
    'scripts/verify_frozen_packaging_repair.py',
    'scripts/checks/test_verify_frozen_packaging_repair.py',
    'scripts/checks/check_build_workflow.py',
    'scripts/checks/test_check_build_workflow.py',
    'scripts/checks/test_recover_release_platforms.py',
    'scripts/checks/test_release_native_recovery.py',
    'scripts/checks/test_release_core_publication.py',
    'scripts/checks/test_release_platform_coverage.py',
    'scripts/checks/test_release_signing_options.py',
    'scripts/checks/test_frozen_release_source.py',
    'scripts/checks/test_apple_packaging_repair_controller.py',
    'scripts/checks/test_macos_packaging_recovery.py',
    'scripts/checks/test_macos_validation_request.py',
    'tools/dv-engine/build_apple_runtime.py',
    'tools/dv-engine/test_apple_runtime.py',
    'CHANGELOG.md',
    'docs/maintainers/full-release-build.md',
})


class FrozenPackagingRepairError(ValueError):
    pass


def _require(condition, message):
    if not condition:
        raise FrozenPackagingRepairError(message)


def _sha(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{40}', value) is not None


def _path(value):
    return (isinstance(value, str) and bool(value) and '\\' not in value
            and not any(ord(char) < 32 for char in value)
            and not PurePosixPath(value).is_absolute()
            and PurePosixPath(value).as_posix() == value
            and '..' not in PurePosixPath(value).parts)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, 'Duplicate key in packaging approval')
        result[key] = value
    return result


def _approval(metadata, product, packaging):
    _require(isinstance(metadata, dict) and metadata.get('type') == 'file'
             and metadata.get('encoding') == 'base64' and _sha(metadata.get('sha')),
             'Packaging approval must be an immutable regular JSON file')
    encoded = metadata.get('content')
    _require(isinstance(encoded, str) and len(encoded) <= 2 * 1024 * 1024,
             'Packaging approval content is missing or too large')
    try:
        payload = base64.b64decode(''.join(encoded.split()), validate=True)
        _require(len(payload) <= 1024 * 1024, 'Packaging approval is too large')
        blob = b'blob ' + str(len(payload)).encode('ascii') + b'\0' + payload
        _require(hashlib.sha1(blob).hexdigest() == metadata['sha'], 'Packaging approval blob digest mismatch')
        config = json.loads(payload.decode('utf-8'), object_pairs_hook=_unique_object)
    except (binascii.Error, UnicodeError, json.JSONDecodeError) as error:
        raise FrozenPackagingRepairError('Invalid packaging approval JSON') from error
    _require(isinstance(config, dict) and type(config.get('schema_version')) is int
             and config['schema_version'] == 1 and isinstance(config.get('repairs'), list),
             'Unsupported packaging approval schema')
    matches = []
    seen = set()
    for entry in config['repairs']:
        _require(isinstance(entry, dict) and _sha(entry.get('product_source_sha'))
                 and _sha(entry.get('packaging_source_sha')), 'Invalid packaging approval identity')
        pair = (entry['product_source_sha'], entry['packaging_source_sha'])
        _require(pair not in seen, 'Duplicate packaging approval')
        seen.add(pair)
        if pair == (product, packaging):
            matches.append(entry)
    _require(len(matches) == 1, 'Exact frozen product/packaging repair has not been approved')
    files = matches[0].get('files')
    _require(isinstance(files, dict) and 0 < len(files) < 300,
             'Packaging approval requires a bounded exact file/blob inventory')
    _require(all(_path(path) and path in ALLOWED_REPAIR_FILES and _sha(blob)
                 for path, blob in files.items()),
             'Approval includes application/native/pin/version or unsupported packaging changes')
    return files


def _tree(response, expected):
    _require(isinstance(response, dict) and response.get('sha') == expected
             and response.get('truncated') is False and isinstance(response.get('tree'), list),
             'Complete immutable source tree is required')
    leaves = {}
    paths = set()
    for entry in response['tree']:
        _require(isinstance(entry, dict) and _path(entry.get('path'))
                 and _sha(entry.get('sha')) and entry.get('type') in ('blob', 'tree', 'commit')
                 and entry['path'] not in paths, 'Invalid or duplicate source tree entry')
        modes = {'blob': ('100644', '100755', '120000'), 'tree': ('040000',), 'commit': ('160000',)}
        _require(entry.get('mode') in modes[entry['type']], 'Incomplete or unsupported source tree mode')
        paths.add(entry['path'])
        if entry['type'] != 'tree':
            leaves[entry['path']] = (entry['type'], entry.get('mode'), entry['sha'])
    return leaves


def _ancestor(comparison, base, *, strict):
    _require(isinstance(comparison, dict)
             and comparison.get('status') in (('ahead',) if strict else ('ahead', 'identical'))
             and comparison.get('base_commit', {}).get('sha') == base
             and comparison.get('merge_base_commit', {}).get('sha') == base
             and comparison.get('behind_by') == 0,
             'Packaging/workflow source is outside the reviewed canonical lineage')


def verify_frozen_packaging_repair(product_sha, packaging_sha, workflow_sha, api,
                                   repository=REPOSITORY):
    """Prove exact approved S -> R, R -> W -> main using public Git metadata."""
    _require(repository == REPOSITORY and all(_sha(value) for value in
             (product_sha, packaging_sha, workflow_sha)), 'Canonical repository and immutable sources are required')
    _require(len({product_sha, packaging_sha, workflow_sha}) == 3,
             'Approval must be added after the distinct frozen product and repair commits')
    prefix = f'repos/{repository}'
    identity = api(prefix)
    _require(isinstance(identity, dict) and identity.get('id') == REPOSITORY_ID
             and identity.get('full_name', '').lower() == REPOSITORY, 'Repository identity mismatch')
    approval = api(f'{prefix}/contents/{APPROVAL_PATH}?ref={workflow_sha}')
    files = _approval(approval, product_sha, packaging_sha)
    product = api(f'{prefix}/git/commits/{product_sha}')
    repair = api(f'{prefix}/git/commits/{packaging_sha}')
    for commit, expected in ((product, product_sha), (repair, packaging_sha)):
        _require(isinstance(commit, dict) and commit.get('sha') == expected
                 and _sha(commit.get('tree', {}).get('sha')), 'Immutable source commit/tree is missing')
    parents = repair.get('parents')
    _require(isinstance(parents, list) and len(parents) == 1
             and isinstance(parents[0], dict) and parents[0].get('sha') == product_sha,
             'Packaging repair must have the frozen product as its sole parent')
    comparison = api(f'{prefix}/compare/{product_sha}...{packaging_sha}')
    _ancestor(comparison, product_sha, strict=True)
    _require(comparison.get('ahead_by') == 1 and comparison.get('total_commits') == 1
             and isinstance(comparison.get('commits'), list) and len(comparison['commits']) == 1
             and isinstance(comparison['commits'][0], dict)
             and comparison['commits'][0].get('sha') == packaging_sha,
             'Packaging comparison must contain exactly the approved repair commit')
    changes = comparison.get('files')
    _require(isinstance(changes, list) and 0 < len(changes) < 300
             and comparison.get('truncated', False) is False,
             'Packaging comparison is missing or may be truncated')
    compared = {}
    for entry in changes:
        _require(isinstance(entry, dict) and entry.get('status') in ('added', 'modified')
                 and not entry.get('previous_filename') and _path(entry.get('filename'))
                 and entry['filename'] not in compared and _sha(entry.get('sha')),
                 'Packaging comparison contains a rename, removal or invalid file')
        compared[entry['filename']] = entry['sha']
    _require(compared == files, 'Packaging comparison differs from approved files/blobs')
    before = _tree(api(f"{prefix}/git/trees/{product['tree']['sha']}?recursive=1"), product['tree']['sha'])
    after = _tree(api(f"{prefix}/git/trees/{repair['tree']['sha']}?recursive=1"), repair['tree']['sha'])
    changed = {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}
    _require(changed == files.keys(), 'Source trees contain unapproved application/native/pin/version changes')
    for path, blob in files.items():
        _require(after.get(path) in (('blob', '100644', blob), ('blob', '100755', blob)),
                 'Approved packaging changes must be regular files with the exact reviewed blobs')
    _ancestor(api(f'{prefix}/compare/{packaging_sha}...{workflow_sha}'), packaging_sha, strict=True)
    _ancestor(api(f'{prefix}/compare/{workflow_sha}...main'), workflow_sha, strict=False)
    return {'recovery_policy': POLICY, 'product_source_sha': product_sha,
            'packaging_source_sha': packaging_sha, 'workflow_source_sha': workflow_sha,
            'approval_path': APPROVAL_PATH, 'approval_source_sha': workflow_sha,
            'approval_blob_sha': approval['sha'], 'approved_files': dict(sorted(files.items())),
            'product_tree_sha': product['tree']['sha'], 'packaging_tree_sha': repair['tree']['sha']}


def verify_receipt(receipt, *, product_source_sha, packaging_source_sha, workflow_source_sha,
                   source_run_id, assembly_run_id, api, repository=REPOSITORY):
    """Bind an already attestation-verified receipt to independent source proof."""
    _require(isinstance(receipt, dict) and type(receipt.get('schema_version')) is int
             and receipt['schema_version'] == 2 and receipt.get('recovery_policy') == POLICY,
             'Unsupported frozen packaging recovery receipt')
    for key, expected in (('product_source_sha', product_source_sha),
                          ('packaging_source_sha', packaging_source_sha),
                          ('workflow_source_sha', workflow_source_sha),
                          ('source_run_id', source_run_id), ('assembly_run_id', assembly_run_id)):
        _require(receipt.get(key) == expected, 'Recovery receipt identity mismatch: ' + key)
    _require(all(type(value) is int and value > 0 for value in
                 (source_run_id, assembly_run_id, receipt['source_run_id'], receipt['assembly_run_id'])),
             'Recovery receipt requires exact positive integer run identities')
    return verify_frozen_packaging_repair(product_source_sha, packaging_source_sha,
                                          workflow_source_sha, api, repository)
