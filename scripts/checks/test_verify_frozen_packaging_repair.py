#!/usr/bin/env python3
"""A receipt cannot waive frozen product inputs or approve an arbitrary repair."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_frozen_packaging_repair as repair

S, R, W = ('a' * 40, 'b' * 40, 'c' * 40)
ST, RT = ('d' * 40, 'e' * 40)
FILE = 'tools/dv-engine/build_apple_runtime.py'
OLD, NEW = ('1' * 40, '2' * 40)
PREFIX = 'repos/' + repair.REPOSITORY


class FrozenPackagingRepairTests(unittest.TestCase):
    def setUp(self):
        self.config = {'schema_version': 1, 'repairs': [{
            'product_source_sha': S, 'packaging_source_sha': R, 'files': {FILE: NEW}}]}
        self.responses = {
            PREFIX: {'id': repair.REPOSITORY_ID, 'full_name': repair.REPOSITORY},
            f'{PREFIX}/git/commits/{S}': {'sha': S, 'tree': {'sha': ST}},
            f'{PREFIX}/git/commits/{R}': {'sha': R, 'tree': {'sha': RT}, 'parents': [{'sha': S}]},
            f'{PREFIX}/compare/{S}...{R}': {
                'status': 'ahead', 'base_commit': {'sha': S}, 'merge_base_commit': {'sha': S},
                'ahead_by': 1, 'behind_by': 0, 'total_commits': 1, 'commits': [{'sha': R}],
                'files': [{'filename': FILE, 'status': 'modified', 'sha': NEW}]},
            f'{PREFIX}/compare/{R}...{W}': {
                'status': 'ahead', 'base_commit': {'sha': R}, 'merge_base_commit': {'sha': R}, 'behind_by': 0},
            f'{PREFIX}/compare/{W}...main': {
                'status': 'ahead', 'base_commit': {'sha': W}, 'merge_base_commit': {'sha': W}, 'behind_by': 0},
            f'{PREFIX}/git/trees/{ST}?recursive=1': self.tree(ST, OLD),
            f'{PREFIX}/git/trees/{RT}?recursive=1': self.tree(RT, NEW),
        }
        self.calls = []

    def tree(self, sha, blob):
        return {'sha': sha, 'truncated': False, 'tree': [
            {'path': FILE, 'type': 'blob', 'mode': '100644', 'sha': blob},
            {'path': 'lib/main.dart', 'type': 'blob', 'mode': '100644', 'sha': '3' * 40},
            {'path': 'pubspec.yaml', 'type': 'blob', 'mode': '100644', 'sha': '4' * 40},
            {'path': 'native/pins.json', 'type': 'blob', 'mode': '100644', 'sha': '5' * 40},
        ]}

    def api(self, path):
        self.calls.append(path)
        if path == f'{PREFIX}/contents/{repair.APPROVAL_PATH}?ref={W}':
            payload = json.dumps(self.config).encode()
            blob = b'blob ' + str(len(payload)).encode('ascii') + b'\0' + payload
            return {'type': 'file', 'encoding': 'base64', 'sha': hashlib.sha1(blob).hexdigest(),
                    'content': base64.b64encode(payload).decode()}
        return copy.deepcopy(self.responses[path])

    def verify(self):
        return repair.verify_frozen_packaging_repair(S, R, W, self.api)

    def test_exact_reviewed_repair_with_later_main_is_accepted(self):
        result = self.verify()
        self.assertEqual(result['product_source_sha'], S)
        self.assertEqual(result['packaging_source_sha'], R)
        self.assertEqual(result['workflow_source_sha'], W)
        self.assertEqual(result['approved_files'], {FILE: NEW})
        self.assertEqual(result['recovery_policy'], 'frozen-apple-packaging-v1')
        self.assertIn(f'{PREFIX}/contents/{repair.APPROVAL_PATH}?ref={W}', self.calls)
        self.assertFalse(any('/contents/' in call and 'ref=main' in call for call in self.calls))

    def test_workflow_equal_current_main_is_also_accepted(self):
        self.responses[f'{PREFIX}/compare/{W}...main']['status'] = 'identical'
        self.verify()

    def test_unapproved_or_duplicate_pair_is_rejected(self):
        for entries in ([], [dict(self.config['repairs'][0], packaging_source_sha='f' * 40)],
                        self.config['repairs'] * 2):
            with self.subTest(entries=entries):
                self.config['repairs'] = entries
                with self.assertRaises(repair.FrozenPackagingRepairError):
                    self.verify()

    def test_approval_cannot_authorize_product_native_pin_version_or_path_escape(self):
        for path in ('lib/main.dart', 'native/pins.json', 'pubspec.yaml', 'pubspec.lock',
                     'ios/Runner.xcodeproj/project.pbxproj', 'tools/dv-engine/pins.json',
                     'scripts/../lib/main.dart', repair.APPROVAL_PATH):
            with self.subTest(path=path):
                self.config['repairs'][0]['files'] = {path: NEW}
                with self.assertRaisesRegex(repair.FrozenPackagingRepairError, 'unsupported packaging'):
                    self.verify()

    def test_merge_or_wrong_parent_is_rejected(self):
        for parents in ([], [{'sha': 'f' * 40}], [{'sha': S}, {'sha': W}]):
            with self.subTest(parents=parents):
                self.responses[f'{PREFIX}/git/commits/{R}']['parents'] = parents
                with self.assertRaisesRegex(repair.FrozenPackagingRepairError, 'sole parent'):
                    self.verify()

    def test_unapproved_blob_rename_removal_or_incomplete_diff_is_rejected(self):
        baseline = copy.deepcopy(self.responses[f'{PREFIX}/compare/{S}...{R}'])
        mutations = [
            {'files': []}, {'files': baseline['files'] * 300}, {'truncated': True},
            {'files': [dict(baseline['files'][0], sha='f' * 40)]},
            {'files': [dict(baseline['files'][0], status='renamed', previous_filename='lib/main.dart')]},
            {'files': [dict(baseline['files'][0], status='modified', previous_filename='lib/main.dart')]},
            {'files': [dict(baseline['files'][0], status='removed')]},
            {'files': baseline['files'] * 2}, {'total_commits': 2}, {'commits': []},
            {'base_commit': {'sha': W}}, {'merge_base_commit': {'sha': W}},
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.responses[f'{PREFIX}/compare/{S}...{R}'] = {**baseline, **mutation}
                with self.assertRaises(repair.FrozenPackagingRepairError):
                    self.verify()

    def test_independent_trees_detect_omitted_product_changes_and_nonregular_files(self):
        baseline = self.tree(RT, NEW)
        for path in ('lib/main.dart', 'native/pins.json', 'pubspec.yaml'):
            altered = copy.deepcopy(baseline)
            next(item for item in altered['tree'] if item['path'] == path)['sha'] = 'f' * 40
            with self.subTest(path=path):
                self.responses[f'{PREFIX}/git/trees/{RT}?recursive=1'] = altered
                with self.assertRaisesRegex(repair.FrozenPackagingRepairError, 'Source trees'):
                    self.verify()
        for mutation in ({'mode': '120000'}, {'type': 'commit', 'mode': '160000'}, {'sha': OLD}):
            altered = copy.deepcopy(baseline)
            altered['tree'][0].update(mutation)
            with self.subTest(mutation=mutation):
                self.responses[f'{PREFIX}/git/trees/{RT}?recursive=1'] = altered
                with self.assertRaises(repair.FrozenPackagingRepairError):
                    self.verify()

    def test_truncated_missing_or_wrong_tree_is_rejected(self):
        for tree in ({**self.tree(RT, NEW), 'truncated': True},
                     {'sha': RT, 'tree': []}, {**self.tree(RT, NEW), 'sha': ST}):
            with self.subTest(tree=tree):
                self.responses[f'{PREFIX}/git/trees/{RT}?recursive=1'] = tree
                with self.assertRaisesRegex(repair.FrozenPackagingRepairError, 'Complete immutable'):
                    self.verify()

    def test_approval_blob_tampering_and_missing_tree_mode_are_rejected(self):
        def tampered(path):
            result = self.api(path)
            if '/contents/' in path:
                result['sha'] = 'f' * 40
            return result

        with self.assertRaisesRegex(repair.FrozenPackagingRepairError, 'blob digest mismatch'):
            repair.verify_frozen_packaging_repair(S, R, W, tampered)
        self.responses[f'{PREFIX}/git/trees/{RT}?recursive=1']['tree'][1].pop('mode')
        with self.assertRaisesRegex(repair.FrozenPackagingRepairError, 'source tree mode'):
            self.verify()

    def test_repair_must_reach_workflow_and_workflow_must_reach_main(self):
        for path in (f'{PREFIX}/compare/{R}...{W}', f'{PREFIX}/compare/{W}...main'):
            original = copy.deepcopy(self.responses[path])
            for change in ({'status': 'diverged'}, {'merge_base_commit': {'sha': S}}, {'behind_by': 1}):
                with self.subTest(path=path, change=change):
                    self.responses[path] = {**original, **change}
                    with self.assertRaisesRegex(repair.FrozenPackagingRepairError, 'canonical lineage'):
                        self.verify()
            self.responses[path] = original

    def test_invalid_sources_or_repository_fail_before_network(self):
        for sources in ((S, R, R), (S, S, W), ('main', R, W)):
            with self.subTest(sources=sources), self.assertRaises(repair.FrozenPackagingRepairError):
                repair.verify_frozen_packaging_repair(*sources, self.api)
        with self.assertRaises(repair.FrozenPackagingRepairError):
            repair.verify_frozen_packaging_repair(S, R, W, self.api, 'other/repo')
        self.assertEqual(self.calls, [])
        self.responses[PREFIX]['id'] = 99
        with self.assertRaisesRegex(repair.FrozenPackagingRepairError, 'Repository identity'):
            self.verify()

    def test_receipt_identity_is_checked_before_independent_proof(self):
        receipt = {'schema_version': 2, 'recovery_policy': repair.POLICY,
                   'product_source_sha': S, 'packaging_source_sha': R, 'workflow_source_sha': W,
                   'source_run_id': 42, 'assembly_run_id': 43}

        def verify(value):
            return repair.verify_receipt(value, product_source_sha=S, packaging_source_sha=R,
                workflow_source_sha=W, source_run_id=42, assembly_run_id=43, api=self.api)

        self.assertEqual(verify(receipt)['approved_files'], {FILE: NEW})
        for field, value in (('schema_version', 1), ('recovery_policy', 'other'),
                             ('product_source_sha', W), ('packaging_source_sha', S),
                             ('workflow_source_sha', R), ('source_run_id', 43), ('assembly_run_id', 42)):
            with self.subTest(field=field), self.assertRaises(repair.FrozenPackagingRepairError):
                verify({**receipt, field: value})
        with self.assertRaises(repair.FrozenPackagingRepairError):
            repair.verify_receipt({**receipt, 'source_run_id': True}, product_source_sha=S,
                packaging_source_sha=R, workflow_source_sha=W, source_run_id=True, assembly_run_id=43, api=self.api)


if __name__ == '__main__':
    unittest.main()
