import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import refresh_release_facts as facts
import check_capability_manifest as check


class ReleaseFactsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ['README.md', 'docs/maintainers/capability-manifest.json']:
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((facts.ROOT / name).read_bytes())
        self.metadata = json.loads((facts.ROOT / 'docs/maintainers/releases/v3.0.3.json').read_text())
        self.metadata['assets'] = [{'name': name, 'size': 100} for name in self.metadata.pop('assetNames')]

    def test_published_branch_target_is_separate_from_immutable_source_and_refresh_is_idempotent(self):
        commit = 'a' * 40
        self.metadata['target_commitish'] = 'main'
        changed = facts.update(self.root, self.metadata, commit, '2026-11-08')
        self.assertIn('docs/maintainers/capability-manifest.json', changed)
        self.assertIn('docs/maintainers/releases/v3.0.3.json', changed)
        manifest = json.loads((self.root / 'docs/maintainers/capability-manifest.json').read_text())['release']
        self.assertEqual(manifest['sourceCommit'], commit)
        self.assertEqual(manifest['targetCommitish'], 'main')
        self.assertTrue(manifest['publicLatestAvailable'])
        evidence = json.loads((self.root / manifest['evidence']).read_text())
        check.ERRORS.clear()
        check.check_published_release(manifest, evidence)
        self.assertEqual(check.ERRORS, [])
        evidence['tag_commit'] = 'b' * 40
        check.check_published_release(manifest, evidence)
        self.assertTrue(any('immutable tag' in error for error in check.ERRORS))
        self.assertEqual(facts.update(self.root, self.metadata, commit, '2026-11-08'), [])

    def test_draft_and_incomplete_release_cannot_change_public_facts(self):
        before = {path: path.read_bytes() for path in self.root.rglob('*') if path.is_file()}
        for failure in ['draft', 'missing-windows-arm64']:
            metadata = copy.deepcopy(self.metadata)
            if failure == 'draft':
                metadata['draft'] = True
            else:
                metadata['assets'] = [asset for asset in metadata['assets'] if 'windows-arm64' not in asset['name']]
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                facts.update(self.root, metadata, 'a' * 40, '2026-11-08')
            self.assertEqual(before, {path: path.read_bytes() for path in self.root.rglob('*') if path.is_file()})

    def test_annotated_tag_is_dereferenced_and_cycles_are_rejected(self):
        with patch.object(facts, 'github', side_effect=[
            {'object': {'type': 'tag', 'sha': 'a' * 40}},
            {'object': {'type': 'commit', 'sha': 'b' * 40}},
        ]):
            self.assertEqual(facts.tag_commit('v3.0.3'), 'b' * 40)
        with patch.object(facts, 'github', return_value={'object': {'type': 'tag', 'sha': 'a' * 40}}):
            with self.assertRaises(ValueError):
                facts.tag_commit('v3.0.3')

    def test_current_publication_ledger_matches_recorded_independent_evidence(self):
        release = json.loads((facts.ROOT / 'docs/maintainers/capability-manifest.json').read_text())['release']
        evidence = json.loads((facts.ROOT / release['evidence']).read_text())
        check.ERRORS.clear()
        check.check_published_release(release, evidence)
        self.assertEqual(check.ERRORS, [])


if __name__ == '__main__':
    unittest.main()
