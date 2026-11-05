#!/usr/bin/env python3
"""Recovery must prove product equivalence, source checks, and artifact integrity."""

import copy
import hashlib
import io
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import recover_release_platforms as recovery
import release_all_platforms as controller


class SourceProofTests(unittest.TestCase):
    def setUp(self):
        self.source = {
            "head_sha": "a" * 40, "status": "completed", "event": "workflow_dispatch",
            "head_branch": "main", "head_repository": {"full_name": recovery.REPOSITORY},
            "path": ".github/workflows/build.yml",
            "display_title": "action:release:pool:private:tag:v3.0.0",
        }
        self.compare = {"status": "ahead", "merge_base_commit": {"sha": "a" * 40},
                        "files": [{"filename": "scripts/prepare_gradle_repositories.py"}]}
        self.jobs = [{"name": name, "status": "completed", "conclusion": "success"}
                     for name in recovery.REQUIRED_JOBS]
        self.jobs += [{"name": "build-android", "status": "completed", "conclusion": "failure"},
                      {"name": "create-release", "status": "completed", "conclusion": "skipped"}]

    def prove(self, **options):
        with patch.object(recovery, "api", side_effect=[self.source, self.compare]), \
             patch.object(recovery, "collection", return_value=self.jobs), \
             patch.object(recovery, "ci_proof", return_value={"ci_run_id": 23}):
            return recovery.verify_source_run(42, "b" * 40, "3.0.0", **options)

    def test_all_platforms_can_be_recovered_after_only_bootstrap_fix(self):
        self.assertEqual(self.prove()["source_sha"], "a" * 40)

    def test_preflight_allows_running_native_jobs_but_never_a_failure(self):
        self.source["status"] = "queued"
        self.jobs[0].update(status="in_progress", conclusion=None)
        proof = self.prove(allow_pending=True)
        self.assertFalse(proof["platforms_complete"])
        self.assertIn(self.jobs[0]["name"], proof["pending_jobs"])
        with self.assertRaises(recovery.RecoveryError):
            self.prove()
        self.jobs[0].update(status="completed", conclusion="failure")
        with self.assertRaises(recovery.RecoveryError):
            self.prove(allow_pending=True)

    def test_assembly_waits_for_completion_and_has_a_deadline(self):
        with patch.object(recovery, "verify_source_run", side_effect=[
            {"platforms_complete": False, "pending_jobs": ["build-ios"]},
            {"platforms_complete": True},
        ]), patch.object(recovery.time, "sleep"):
            self.assertTrue(recovery.wait_for_source_run(42, "b" * 40, "3.0.0", 60)["platforms_complete"])
        with patch.object(recovery, "verify_source_run", return_value={"platforms_complete": False}), \
             self.assertRaisesRegex(recovery.RecoveryError, "Timed out"):
            recovery.wait_for_source_run(42, "b" * 40, "3.0.0", 0)

    def test_rejects_untrusted_active_or_wrong_version_source(self):
        for change in ({"head_branch": "feature"}, {"status": "in_progress"},
                       {"display_title": "action:release:pool:private:tag:v2.0.0"},
                       {"head_repository": {"full_name": "fork/PlezyNG"}}):
            with self.subTest(change=change):
                original = copy.deepcopy(self.source)
                self.source.update(change)
                with self.assertRaises(recovery.RecoveryError):
                    self.prove()
                self.source = original

    def test_product_changes_and_renames_are_rejected(self):
        for entry in ({"filename": "lib/main.dart"},
                      {"filename": "CHANGELOG.md", "previous_filename": "pubspec.lock"},
                      {"filename": "tools/webos/compatibility.json"}):
            with self.subTest(entry=entry):
                self.compare["files"] = [entry]
                with self.assertRaisesRegex(recovery.RecoveryError, "inputs changed"):
                    self.prove()

    def test_divergent_or_truncated_comparisons_are_rejected(self):
        for change in ({"status": "diverged"}, {"merge_base_commit": {"sha": "c" * 40}},
                       {"files": [{"filename": "CHANGELOG.md"}] * 300}):
            original = copy.deepcopy(self.compare)
            self.compare.update(change)
            with self.assertRaises(recovery.RecoveryError):
                self.prove()
            self.compare = original

    def test_missing_failed_or_ambiguous_platform_is_rejected(self):
        for jobs in (self.jobs[1:], self.jobs + [self.jobs[0]],
                     [{**job, "conclusion": "failure"} if job["name"] == "build-macos" else job
                      for job in self.jobs]):
            with self.subTest(jobs=jobs):
                original, self.jobs = self.jobs, jobs
                with self.assertRaises(recovery.RecoveryError):
                    self.prove()
                self.jobs = original

    def test_source_that_attempted_publication_is_rejected(self):
        self.jobs[-1]["conclusion"] = "success"
        with self.assertRaisesRegex(recovery.RecoveryError, "side effects"):
            self.prove()

    def test_source_ci_requires_complete_successful_exact_sha_checks(self):
        with patch.dict("os.environ", {"GH_TOKEN": "test-token"}), \
             patch.object(recovery.release_ci, "_manifest_gate", return_value={}), \
             patch.object(recovery.release_ci, "_latest_run", return_value={"status": "completed", "conclusion": "success"}), \
             patch.object(recovery.release_ci, "_check_jobs", return_value=["Windows arm64: skipped"]):
            with self.assertRaisesRegex(recovery.RecoveryError, "CI is incomplete"):
                recovery.ci_proof(recovery.REPOSITORY, "a" * 40)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def archive(self, name="payload.exe", contents=b"binary", symlink=False):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            info = zipfile.ZipInfo(name)
            if symlink:
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, contents)
        return stream.getvalue()

    def test_rejects_zip_traversal_symlinks_and_collisions(self):
        for name in ("../escape", "/absolute", "folder\\escape", "C:/escape"):
            with self.subTest(name=name), self.assertRaises(recovery.RecoveryError):
                recovery.extract_verified(io.BytesIO(self.archive(name)), self.root / "out")
        with self.assertRaises(recovery.RecoveryError):
            recovery.extract_verified(io.BytesIO(self.archive(symlink=True)), self.root / "out")
        recovery.extract_verified(io.BytesIO(self.archive()), self.root / "out")
        with self.assertRaises(recovery.RecoveryError):
            recovery.extract_verified(io.BytesIO(self.archive()), self.root / "out")

    def test_existing_destination_symlink_is_rejected(self):
        (self.root / "out").mkdir()
        (self.root / "out" / "nested").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(recovery.RecoveryError):
            recovery.extract_verified(io.BytesIO(self.archive("nested/escape")), self.root / "out")

    def test_verified_download_records_actual_source_and_digests(self):
        archive = self.archive()
        digest = "sha256:" + hashlib.sha256(archive).hexdigest()
        item = {"id": 7, "name": "native", "expired": False, "digest": digest,
                "workflow_run": {"id": 42, "head_sha": "a" * 40}}
        proof = {"source_run_id": 42, "source_sha": "a" * 40}

        def download(_args, stdout):
            stdout.write(archive)
            return SimpleNamespace(returncode=0)

        with patch.object(recovery, "ARTIFACTS", {"native": "native"}), \
             patch.object(recovery, "collection", return_value=[item]), \
             patch.object(recovery.subprocess, "run", side_effect=download):
            result = recovery.download_platforms(proof, self.root)
            self.assertEqual(result["artifacts"][0]["digest"], digest)
            self.assertEqual((self.root / "native/payload.exe").read_bytes(), b"binary")
            self.assertTrue((self.root / "platform-reuse-provenance.json").is_file())

    def test_artifact_identity_expiry_ambiguity_and_digest_fail_closed(self):
        archive = self.archive()
        item = {"id": 7, "name": "native", "expired": False,
                "digest": "sha256:" + "0" * 64,
                "workflow_run": {"id": 42, "head_sha": "a" * 40}}
        inventories = [[item], [item, item], [{**item, "expired": True}],
                       [{**item, "workflow_run": {"id": 43, "head_sha": "a" * 40}}],
                       [{**item, "digest": None}]]
        for inventory in inventories:
            with self.subTest(inventory=inventory), \
                 patch.object(recovery, "ARTIFACTS", {"native": "native"}), \
                 patch.object(recovery, "collection", return_value=inventory), \
                 patch.object(recovery.subprocess, "run", side_effect=lambda args, stdout: (stdout.write(archive), SimpleNamespace(returncode=0))[1]), \
                 self.assertRaises(recovery.RecoveryError):
                recovery.download_platforms({"source_run_id": 42, "source_sha": "a" * 40}, self.root)


class ControllerTests(unittest.TestCase):
    @patch.object(controller, "verify_platform_recovery")
    @patch.object(controller, "matching_run", return_value=None)
    @patch.object(controller, "ensure_remote_main_sha")
    @patch.object(controller, "dispatch")
    def test_recovery_dispatch_is_distinct_and_reuses_no_unverified_run(self, dispatch, _main, _matching, verify):
        controller.ensure_release("v3.0.0", "b" * 40, include_webos_release=False,
                                  reuse_platform_run_id=42)
        verify.assert_called_once_with(42, "b" * 40, "3.0.0")
        self.assertEqual(dispatch.call_args.args[3]["reuse_platform_run_id"], "42")
        self.assertEqual(dispatch.call_args.kwargs["expected_title"],
                         "action:release:pool:private:tag:v3.0.0")
        self.assertEqual(dispatch.call_args.kwargs["expected_sha"], "b" * 40)

    def test_recovery_rejects_signed_store_or_public_webos_mode(self):
        with self.assertRaises(controller.ReleaseError):
            controller.ensure_release("v3.0.0", "b" * 40, include_webos_release=True,
                                      reuse_platform_run_id=42)


if __name__ == "__main__":
    unittest.main()
