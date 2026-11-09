#!/usr/bin/env python3
"""Recovery must prove product equivalence, source checks, and artifact integrity."""

import copy
import base64
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

    def test_webos_only_failure_keeps_a_successful_android_build_reusable(self):
        self.jobs[-2]["conclusion"] = "success"
        self.jobs.append({"name": "Build WebOS TV package (ARMv7)", "status": "completed", "conclusion": "failure"})
        self.assertEqual(self.prove()["source_sha"], "a" * 40)

    def test_ci_tag_reuse_requires_complete_product_equivalence(self):
        tag = "c" * 40
        comparison = {"status": "ahead", "merge_base_commit": {"sha": tag}, "files": [{"filename": "scripts/prepare_native_downloads.py"}]}
        for changed in (comparison, {**comparison, "files": [{"filename": "pubspec.lock"}]},
                        {**comparison, "files": [{"filename": "CHANGELOG.md", "previous_filename": "lib/main.dart"}]},
                        {**comparison, "files": comparison["files"] * 300}):
            with self.subTest(changed=changed), patch.object(recovery, "api", side_effect=[{"object": {"type": "commit", "sha": tag}}, changed]):
                if changed is comparison:
                    self.assertEqual(recovery.immutable_ci_source(recovery.REPOSITORY, "a" * 40, "3.0.0"), tag)
                else:
                    with self.assertRaises(recovery.RecoveryError):
                        recovery.immutable_ci_source(recovery.REPOSITORY, "a" * 40, "3.0.0")

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
                       {"head_repository": {"full_name": "fork/Pleazyng"}}):
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

    def test_transport_recovery_cannot_change_native_pins_outside_python_bootstrap(self):
        original = "PDFIUM_PINS = {'asset': 'pinned'}\ndef prepare_webos_python(cache):\n return 1\n"
        loader_fix = original.replace("return 1", "return 2")
        native_change = loader_fix.replace("'pinned'", "'different'")
        def encoded(code):
            return {"encoding": "base64", "content": base64.b64encode(code.encode()).decode()}
        for replacement in (loader_fix, native_change):
            with self.subTest(replacement=replacement), patch.object(recovery, "api", side_effect=[encoded(original), encoded(replacement)]):
                if replacement == loader_fix:
                    recovery.verify_webos_transport_patch(recovery.REPOSITORY, "a" * 40, "b" * 40, [{"filename": "scripts/prepare_native_downloads.py"}])
                else:
                    with self.assertRaisesRegex(recovery.RecoveryError, "Native download pins"):
                        recovery.verify_webos_transport_patch(recovery.REPOSITORY, "a" * 40, "b" * 40, [{"filename": "scripts/prepare_native_downloads.py"}])

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

    def test_android_artifact_uses_its_own_verified_run_identity(self):
        archive = self.archive()
        item = {"id": 7, "name": "android-apk", "expired": False,
                "digest": "sha256:" + hashlib.sha256(archive).hexdigest(),
                "workflow_run": {"id": 84, "head_sha": "b" * 40}}
        proof = {"source_run_id": 42, "source_sha": "a" * 40,
                 "android_source": {"source_run_id": 84, "source_sha": "b" * 40}}
        def download(_args, stdout):
            stdout.write(archive)
            return SimpleNamespace(returncode=0)
        with patch.object(recovery, "ARTIFACTS", {}), \
             patch.object(recovery, "collection", side_effect=[[], [item]]), \
             patch.object(recovery.subprocess, "run", side_effect=download):
            result = recovery.download_platforms(proof, self.root)
        self.assertEqual(result["artifacts"][0]["source_run_id"], 84)
        self.assertEqual((self.root / "android-apk/payload.exe").read_bytes(), b"binary")

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
        controller.ensure_release("v3.0.0", "b" * 40, include_webos_release=True,
                                  reuse_platform_run_id=42)
        verify.assert_called_once_with(42, "b" * 40, "3.0.0")
        self.assertEqual(dispatch.call_args.args[3]["reuse_platform_run_id"], "42")
        self.assertEqual(dispatch.call_args.kwargs["expected_title"],
                         "action:release:pool:private:tag:v3.0.0")
        self.assertEqual(dispatch.call_args.kwargs["expected_sha"], "b" * 40)
        self.assertEqual(dispatch.call_args.args[3]["include_webos_release"], "true")
        self.assertEqual(dispatch.call_args.args[3]["include_webos_build"], "true")

    def test_recovery_rejects_signed_store_mode(self):
        with self.assertRaises(controller.ReleaseError):
            controller.ensure_release("v3.0.0", "b" * 40, include_webos_release=True,
                                      include_apple_store_build=True, reuse_platform_run_id=42)

    def test_recovery_cannot_omit_required_webos_artifact_or_build(self):
        for include_release, include_build in ((False, True), (True, False), (False, False)):
            with self.subTest(release=include_release, build=include_build), \
                 patch.object(controller, "verify_platform_recovery") as verify, \
                 self.assertRaises(controller.ReleaseError):
                controller.ensure_release("v3.0.0", "b" * 40,
                    include_webos_release=include_release, include_webos_build=include_build,
                    reuse_platform_run_id=42)
            verify.assert_not_called()


class AndroidSourceTests(unittest.TestCase):
    def setUp(self):
        self.source = {"status": "completed", "event": "workflow_dispatch", "head_branch": "main",
                       "head_repository": {"full_name": recovery.REPOSITORY},
                       "path": ".github/workflows/build.yml", "head_sha": "a" * 40,
                       "display_title": "action:release:pool:private:tag:v3.0.0"}
        self.compare = {"status": "ahead", "merge_base_commit": {"sha": "a" * 40}, "files": []}
        self.jobs = [{"id": 71, "name": "build-android", "status": "completed", "conclusion": "success"},
                     {"name": "create-release", "conclusion": "skipped"}]

    def prove(self):
        with patch.object(recovery, "api", side_effect=[self.source, self.compare]), \
             patch.object(recovery, "collection", return_value=self.jobs):
            return recovery.verify_android_run(84, "b" * 40, "3.0.0")

    def test_reuses_only_successful_android_from_equivalent_product_inputs(self):
        self.assertEqual(self.prove()["job_id"], 71)
        self.compare["files"] = [{"filename": "android/app/build.gradle.kts"}]
        with self.assertRaisesRegex(recovery.RecoveryError, "input equivalence"):
            self.prove()

    def test_failed_or_untrusted_android_cannot_be_reused(self):
        self.jobs[0]["conclusion"] = "failure"
        with self.assertRaisesRegex(recovery.RecoveryError, "uniquely successful"):
            self.prove()
        self.source["head_branch"] = "feature"
        with self.assertRaisesRegex(recovery.RecoveryError, "trusted-main"):
            self.prove()

    def test_composition_records_optional_exclusions_and_real_android_source(self):
        with patch.object(recovery, "verify_android_run", return_value={"source_run_id": 84}):
            proof = recovery.compose_proof({"head_sha": "b" * 40, "version": "3.0.0"}, 84, False)
        self.assertEqual(proof["rebuilt_jobs"], [])
        self.assertEqual(proof["android_source"]["source_run_id"], 84)
        self.assertEqual(proof["excluded_optional_jobs"], ["Build WebOS TV package (ARMv7)"])


if __name__ == "__main__":
    unittest.main()
