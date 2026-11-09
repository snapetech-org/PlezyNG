#!/usr/bin/env python3
"""Exercise repository continuity and strict signature failures after renaming."""

import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "verify_release_attestation", Path(__file__).resolve().parents[1] / "verify_release_attestation.py",
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class ReleaseAttestationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.asset = Path(self.temp.name) / "artifact.bin"
        self.asset.write_bytes(b"release artifact")
        self.identity = json.dumps({"id": VERIFY.REPOSITORY_ID, "full_name": VERIFY.REPOSITORY})

    def test_current_publisher_verifies_without_legacy_lookup(self):
        with patch.object(VERIFY.subprocess, "check_output", return_value=self.identity) as api, \
                patch.object(VERIFY.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            self.assertEqual(VERIFY.verify(self.asset), VERIFY.REPOSITORY)
        self.assertEqual(api.call_count, 1)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][-1], VERIFY.REPOSITORY)

    def test_historical_publisher_requires_same_repository_redirect(self):
        with patch.object(VERIFY.subprocess, "check_output", return_value=self.identity) as api, \
                patch.object(VERIFY.subprocess, "run", side_effect=[
                    SimpleNamespace(returncode=1), SimpleNamespace(returncode=0),
                ]) as run:
            self.assertEqual(VERIFY.verify(self.asset), VERIFY.LEGACY_REPOSITORY)
        self.assertEqual(api.call_count, 2)
        self.assertEqual(api.call_args.args[0][-1], f"repos/{VERIFY.LEGACY_REPOSITORY}")
        self.assertEqual(run.call_args.args[0][-1], VERIFY.LEGACY_REPOSITORY)

    def test_recreated_old_name_cannot_inherit_release_trust(self):
        other = json.dumps({"id": 999, "full_name": VERIFY.LEGACY_REPOSITORY})
        with patch.object(VERIFY.subprocess, "check_output", side_effect=[self.identity, other]), \
                patch.object(VERIFY.subprocess, "run", return_value=SimpleNamespace(returncode=1)) as run:
            with self.assertRaisesRegex(ValueError, "original Pleazyng repository ID"):
                VERIFY.verify(self.asset)
        self.assertEqual(run.call_count, 1)

    def test_invalid_signatures_still_fail_under_both_names(self):
        with patch.object(VERIFY.subprocess, "check_output", return_value=self.identity), \
                patch.object(VERIFY.subprocess, "run", return_value=SimpleNamespace(returncode=1)) as run:
            with self.assertRaisesRegex(ValueError, "did not verify"):
                VERIFY.verify(self.asset)
        self.assertEqual(run.call_count, 2)

    def test_changed_current_repository_id_stops_before_verification(self):
        other = json.dumps({"id": 999, "full_name": VERIFY.REPOSITORY})
        with patch.object(VERIFY.subprocess, "check_output", return_value=other), \
                patch.object(VERIFY.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "original Pleazyng repository ID"):
                VERIFY.verify(self.asset)
        run.assert_not_called()

    def test_unrelated_repository_is_rejected_without_contacting_it(self):
        with patch.object(VERIFY.subprocess, "check_output") as api:
            with self.assertRaisesRegex(ValueError, "restricted"):
                VERIFY.verify(self.asset, "another/project")
        api.assert_not_called()


if __name__ == "__main__":
    unittest.main()
