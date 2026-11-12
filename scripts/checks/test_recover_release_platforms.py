#!/usr/bin/env python3
"""Recovery must prove product equivalence, source checks, and artifact integrity."""

import copy
import base64
import hashlib
import io
import json
import shutil
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

    def test_cancelled_or_timed_out_android_requires_a_new_build(self):
        for conclusion in ("cancelled", "timed_out"):
            with self.subTest(conclusion=conclusion):
                self.jobs[-2]["conclusion"] = conclusion
                proof = recovery.compose_proof(self.prove())
                self.assertIn("build-android", proof["rebuilt_jobs"])
                self.assertNotIn("build-android", proof["reused_jobs"])
                self.assertNotIn("android_source", proof)

    def test_webos_only_failure_keeps_a_successful_android_build_reusable(self):
        self.jobs[-2]["conclusion"] = "success"
        self.jobs.append({"name": "Build WebOS TV package (ARMv7)", "status": "completed", "conclusion": "failure"})
        self.assertEqual(self.prove()["source_sha"], "a" * 40)

    def test_unstarted_cancelled_release_assembly_is_safe_for_platform_recovery(self):
        self.jobs[-1] = {"name": "create-release", "status": "completed", "conclusion": "cancelled",
                         "runner_id": 0, "runner_name": "", "steps": []}
        self.assertEqual(self.prove()["source_sha"], "a" * 40)
        self.jobs[-1]["steps"] = [{"name": "Create release"}]
        with self.assertRaisesRegex(recovery.RecoveryError, "Other source jobs failed"):
            self.prove()

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

    def test_failed_linux_must_be_rebuilt_and_cannot_be_reused(self):
        next(job for job in self.jobs if job["name"] == "Build Linux (x64)")["conclusion"] = "failure"
        with self.assertRaises(recovery.RecoveryError):
            self.prove()
        proof = self.prove(rebuild_linux=True)
        self.assertNotIn("Build Linux (x64)", proof["reused_jobs"])
        self.assertIn("Build Linux (x64)", proof["rebuilt_jobs"])
        self.assertIn("Build Linux (arm64)", proof["rebuilt_jobs"])

    def test_failed_tvos_requires_explicit_rebuild_and_keeps_other_jobs_strict(self):
        name = "Build tvOS developer package (arm64)"
        next(job for job in self.jobs if job["name"] == name)["conclusion"] = "failure"
        with self.assertRaises(recovery.RecoveryError):
            self.prove()
        proof = self.prove(rebuild_tvos=True)
        self.assertTrue(proof["rebuild_tvos"])
        self.assertNotIn(name, proof["reused_jobs"])
        self.assertIn(name, proof["rebuilt_jobs"])
        self.assertIn("build-ios", proof["reused_jobs"])
        next(job for job in self.jobs if job["name"] == "build-ios")["conclusion"] = "failure"
        with self.assertRaises(recovery.RecoveryError):
            self.prove(rebuild_tvos=True)

    def test_failed_ios_requires_explicit_rebuild_and_keeps_tvos_strict(self):
        next(job for job in self.jobs if job["name"] == "build-ios")["conclusion"] = "failure"
        with self.assertRaises(recovery.RecoveryError):
            self.prove()
        proof = self.prove(rebuild_ios=True)
        self.assertTrue(proof["rebuild_ios"])
        self.assertNotIn("build-ios", proof["reused_jobs"])
        self.assertIn("build-ios", proof["rebuilt_jobs"])
        next(job for job in self.jobs if job["name"] == "Build tvOS developer package (arm64)")["conclusion"] = "failure"
        with self.assertRaises(recovery.RecoveryError):
            self.prove(rebuild_ios=True)
        proof = self.prove(rebuild_ios=True, rebuild_tvos=True)
        self.assertIn("build-ios", proof["rebuilt_jobs"])
        self.assertIn("Build tvOS developer package (arm64)", proof["rebuilt_jobs"])

    def test_tvos_rebuild_rejects_product_drift_and_repaired_substitution(self):
        self.compare["files"] = [{"filename": "lib/main.dart"}]
        with self.assertRaises(recovery.RecoveryError):
            self.prove(rebuild_tvos=True)
        with self.assertRaises(recovery.RecoveryError):
            self.prove(rebuild_tvos=True, repaired_run=84)

    def test_successful_android_and_webos_reuse_leaves_only_tvos_to_build(self):
        name = "Build tvOS developer package (arm64)"
        next(job for job in self.jobs if job["name"] == name)["conclusion"] = "failure"
        next(job for job in self.jobs if job["name"] == "build-android")["conclusion"] = "success"
        proof = self.prove(rebuild_tvos=True)
        source = {"source_run_id": 42, "source_sha": "a" * 40, "platforms_complete": True}
        with patch.object(recovery, "verify_android_run", return_value=source), \
             patch.object(recovery, "verify_repaired_run", return_value=source):
            final = recovery.compose_proof(proof, android_run=42, webos_run=42)
        self.assertEqual(final["rebuilt_jobs"], [name])

    def test_cask_recovery_requires_the_reused_mac_qualification(self):
        with self.assertRaisesRegex(recovery.RecoveryError, "qualification"):
            self.prove(require_homebrew_cask=True)
        mac = next(job for job in self.jobs if job["name"] == "build-macos")
        mac["steps"] = [{"name": name, "status": "completed", "conclusion": "success"} for name in ("Notarize Application", "Verify Gatekeeper acceptance for Homebrew Cask")]
        self.assertTrue(self.prove(require_homebrew_cask=True)["macos_cask_qualified"])

    def test_original_failed_linux_and_mac_require_verified_repair_sources(self):
        for job in self.jobs:
            if job["name"] in {"build-macos", "Build Linux (x64)"}:
                job["conclusion"] = "failure"
        repaired = {"source_run_id": 84, "source_sha": "c" * 40,
                    "reused_jobs": ["build-macos", "Build Linux (x64)", "Build Linux (arm64)"],
                    "pending_jobs": [], "platforms_complete": True, "macos_cask_qualified": True}
        with patch.object(recovery, "verify_repaired_run", return_value=repaired):
            proof = self.prove(repaired_run=84, require_homebrew_cask=True)
        self.assertEqual(proof["repaired_source"]["source_run_id"], 84)
        self.assertTrue(proof["macos_cask_qualified"])
        self.assertNotIn("build-macos", proof["rebuilt_jobs"])

    def test_failed_mac_requires_a_fresh_build_and_qualification(self):
        next(job for job in self.jobs if job["name"] == "build-macos")["conclusion"] = "failure"
        with self.assertRaises(recovery.RecoveryError):
            self.prove()
        proof = self.prove(rebuild_macos=True, require_homebrew_cask=True)
        self.assertNotIn("build-macos", proof["reused_jobs"])
        self.assertIn("build-macos", proof["rebuilt_jobs"])
        self.assertFalse(proof["macos_cask_qualified"])

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

    def test_android_may_remain_pending_only_during_preflight(self):
        self.source["status"] = "in_progress"
        next(job for job in self.jobs if job["name"] == "build-android").update(status="in_progress", conclusion=None)
        proof = self.prove(allow_pending=True)
        self.assertIn("build-android", proof["pending_jobs"])
        self.assertFalse(proof["platforms_complete"])
        with self.assertRaises(recovery.RecoveryError):
            self.prove()
        self.source["status"] = "completed"
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
        original = "import sys\nprint('verified')\nPDFIUM_PINS = {'asset': 'pinned'}\ndef prepare_webos_python(cache):\n return 1\n"
        loader_fix = original.replace("return 1", "return 2").replace("print('verified')", "print('verified', file=sys.stderr)")
        native_change = loader_fix.replace("'pinned'", "'different'")
        def encoded(code):
            return {"encoding": "base64", "content": base64.b64encode(code.encode()).decode()}
        for replacement in (loader_fix, native_change):
            recovery.immutable_content.cache_clear()  # Each fixture models different immutable commits.
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


    def frozen(self, **options):
        self.compare['files'] = [{'filename': 'tools/dv-engine/build_apple_runtime.py'}]
        next(job for job in self.jobs if job['name'] == 'build-android')['conclusion'] = 'success'
        return self.prove(packaging_source_sha='b' * 40, workflow_source_sha='c' * 40,
                          include_apple_store_build=True, **options)

    def test_frozen_exception_requires_independent_exact_approval(self):
        with patch('verify_frozen_packaging_repair.verify_frozen_packaging_repair',
                   side_effect=ValueError('unapproved blob')):
            with self.assertRaisesRegex(recovery.RecoveryError, 'approval failed'):
                self.frozen(rebuild_ios=True, rebuild_tvos=True)
        with patch('verify_frozen_packaging_repair.verify_frozen_packaging_repair',
                   return_value={'approved_files': {'reviewed': 'blob'}}) as verify:
            proof = self.frozen(rebuild_ios=True, rebuild_tvos=True)
        self.assertEqual(proof['product_source_sha'], 'a' * 40)
        self.assertEqual(proof['packaging_source_sha'], 'b' * 40)
        self.assertEqual(proof['workflow_source_sha'], 'c' * 40)
        verify.assert_called_once()
        with self.assertRaisesRegex(recovery.RecoveryError, 'inputs changed'):
            self.prove()

    def test_frozen_reuse_requires_actual_signed_store_steps(self):
        with patch('verify_frozen_packaging_repair.verify_frozen_packaging_repair', return_value={}):
            with self.assertRaisesRegex(recovery.RecoveryError, 'signed Store archive'):
                self.frozen()
            for name, step in [('build-ios', 'Build signed iOS App Store IPA'),
                               ('Build tvOS developer package (arm64)', 'Build signed tvOS App Store IPA')]:
                next(job for job in self.jobs if job['name'] == name)['steps'] = [
                    {'name': step, 'conclusion': 'success', 'status': 'completed'}]
            self.assertTrue(self.frozen()['include_apple_store_build'])
            with self.assertRaisesRegex(recovery.RecoveryError, 'full signed Apple builds'):
                self.frozen(rebuild_linux=True)

    def test_frozen_aliases_keep_original_successful_android_and_webos_only(self):
        proof = {'recovery_policy': 'frozen-apple-packaging-v1', 'source_run_id': 42,
                 'source_sha': 'a' * 40, 'rebuilt_jobs': list(recovery.REBUILT_JOBS)}
        jobs = [{'id': i, 'name': name, 'status': 'completed', 'conclusion': 'success'}
                for i, name in enumerate(['build-android', 'Build WebOS TV package (ARMv7)'], 1)]
        with patch.object(recovery, 'collection', return_value=jobs):
            result = recovery.compose_proof(proof, android_run=42, webos_run=42)
            self.assertEqual(result['android_source']['source_sha'], 'a' * 40)
            self.assertEqual(result['webos_source']['job_id'], 2)
            self.assertNotIn('build-android', result['rebuilt_jobs'])
            for options in ({'android_run': 43, 'webos_run': 42},
                            {'android_run': 42, 'webos_run': 43},
                            {'android_run': 42, 'webos_run': 42, 'include_webos_build': False}):
                with self.assertRaises(recovery.RecoveryError):
                    recovery.compose_proof(proof, **options)
            jobs[0]['conclusion'] = 'failure'
            with self.assertRaisesRegex(recovery.RecoveryError, 'not uniquely successful'):
                recovery.compose_proof(proof, android_run=42, webos_run=42)

    def test_tv_sibling_reuse_replaces_original_failed_tv_without_rebuilding_it(self):
        tv = {'source_run_id': 84, 'source_sha': 'd' * 40, 'workflow_source_sha': 'e' * 40}
        with patch('verify_frozen_packaging_repair.verify_frozen_packaging_repair', return_value={'approved': True}), \
                patch.object(recovery, 'verify_frozen_tvos_run', return_value=tv) as reused:
            proof = self.frozen(rebuild_ios=True, tvos_run=84)
        self.assertEqual(proof['tvos_source'], tv)
        self.assertFalse(proof['rebuild_tvos'])
        self.assertNotIn('Build tvOS developer package (arm64)', proof['rebuilt_jobs'])
        self.assertIn('Build tvOS developer package (arm64)', proof['reused_jobs'])
        reused.assert_called_once()

    def test_two_signed_apple_siblings_replace_both_failed_original_jobs(self):
        tv = {'source_run_id': 84, 'source_sha': 'd' * 40}
        ios = {'source_run_id': 85, 'source_sha': 'e' * 40}
        with patch('verify_frozen_packaging_repair.verify_frozen_packaging_repair', return_value={'approved': True}), \
                patch.object(recovery, 'verify_frozen_tvos_run', return_value=tv), \
                patch.object(recovery, 'verify_frozen_ios_run', return_value=ios):
            proof = self.frozen(tvos_run=84, ios_run=85)
        self.assertEqual(proof['tvos_source'], tv)
        self.assertEqual(proof['ios_source'], ios)
        self.assertFalse(proof['rebuild_ios'])
        self.assertFalse(proof['rebuild_tvos'])
        self.assertNotIn('build-ios', proof['rebuilt_jobs'])
        self.assertNotIn('Build tvOS developer package (arm64)', proof['rebuilt_jobs'])
        with self.assertRaisesRegex(recovery.RecoveryError, 'Dual signed Apple'):
            self.frozen(tvos_run=84, ios_run=84)


class FrozenTvosReuseTests(unittest.TestCase):
    def setUp(self):
        self.product, self.repair, self.prior_repair, self.workflow = ('a' * 40, 'b' * 40, 'd' * 40, 'e' * 40)
        self.proof = {'source_run_id': 42, 'product_source_sha': self.product,
                      'packaging_source_sha': self.repair, 'version': '3.0.31'}
        self.run = {'id': 84, 'head_sha': self.workflow, 'status': 'completed', 'conclusion': 'failure',
                    'event': 'workflow_dispatch', 'head_branch': 'main', 'path': '.github/workflows/build.yml',
                    'repository': {'id': 1433487464}, 'head_repository': {'full_name': recovery.REPOSITORY},
                    'run_attempt': 1,
                    'display_title': 'action:release:pool:private:tag:v3.0.31:repair:' + self.prior_repair}
        def job(name, conclusion, steps=()):
            return {'id': len(name), 'name': name, 'status': 'completed', 'conclusion': conclusion,
                    'steps': [{'name': step, 'status': 'completed', 'conclusion': 'success'} for step in steps]}
        self.jobs = [job('Validate release request', 'success', (
            'Verify approved frozen packaging checkout', 'Verify reusable platform source')),
            job('Build tvOS developer package (arm64)', 'success', (
                'Build tvOS app', 'Build signed tvOS App Store IPA', 'Attest unsigned tvOS developer package',
                'Attest signed tvOS App Store package', 'Upload tvOS package')),
            job('build-ios', 'failure'), job('create-release', 'skipped'), job('build-macos', 'skipped')]
        self.artifact = {'id': 7, 'name': 'tvos-ipa', 'expired': False, 'digest': 'sha256:' + 'f' * 64,
                         'workflow_run': {'id': 84, 'head_sha': self.workflow}}
        self.prior = {'source_sha': self.product, 'platforms_complete': True, 'packaging_approval': {'exact': True}}

    def prove(self):
        with patch.object(recovery, 'api', side_effect=[self.run, self.artifact]), \
                patch.object(recovery, 'collection', side_effect=[self.jobs, [self.artifact]]), \
                patch.object(recovery, 'verify_source_run', return_value=self.prior) as source:
            result = recovery.verify_frozen_tvos_run(84, self.proof)
        self.assertEqual(source.call_args.args[:2], (42, self.prior_repair))
        self.assertEqual(source.call_args.kwargs['workflow_source_sha'], self.workflow)
        self.assertTrue(source.call_args.kwargs['include_apple_store_build'])
        return result

    def test_signed_tv_uses_actual_packaging_source_but_workflow_artifact_identity(self):
        result = self.prove()
        self.assertEqual(result['source_sha'], self.prior_repair)
        self.assertEqual(result['workflow_source_sha'], self.workflow)
        self.assertEqual(result['artifact_id'], 7)
        self.assertEqual(result['artifact_digest'], self.artifact['digest'])
        self.assertEqual(result['packaging_approval'], self.prior['packaging_approval'])

    def test_tvos_only_sibling_can_fail_assembly_before_publication(self):
        self.jobs[2]['conclusion'] = 'skipped'
        self.jobs[3]['conclusion'] = 'failure'
        self.jobs[3]['steps'] = [
            {'name': 'Recover verified platform artifacts', 'status': 'completed', 'conclusion': 'failure'},
            {'name': 'Create Release', 'status': 'completed', 'conclusion': 'skipped'},
        ]
        self.prove()
        self.jobs[3]['steps'][1]['conclusion'] = 'success'
        with self.assertRaisesRegex(recovery.RecoveryError, 'before publication'):
            self.prove()

    def test_untrusted_wrong_product_unsigned_and_publication_attempt_sources_are_rejected(self):
        original = {key: copy.deepcopy(getattr(self, key)) for key in ('run', 'jobs', 'artifact', 'prior')}
        for change in ('foreign', 'wrong-product', 'failed-ci', 'missing-signed', 'missing-attestation',
                       'publication', 'unrelated-built', 'duplicate-tv', 'expired', 'bad-artifact-source'):
            self.__dict__.update(copy.deepcopy(original))
            if change == 'foreign':
                self.run['head_repository']['full_name'] = 'other/project'
            elif change == 'wrong-product':
                self.prior['source_sha'] = 'c' * 40
            elif change == 'failed-ci':
                self.prior['platforms_complete'] = False
            elif change in ('missing-signed', 'missing-attestation'):
                self.jobs[1]['steps'][1 if change == 'missing-signed' else 3]['conclusion'] = 'skipped'
            elif change == 'publication':
                self.jobs[3]['conclusion'] = 'failure'
            elif change == 'unrelated-built':
                self.jobs[4]['conclusion'] = 'success'
            elif change == 'duplicate-tv':
                self.jobs.append(copy.deepcopy(self.jobs[1]))
            elif change == 'expired':
                self.artifact['expired'] = True
            elif change == 'bad-artifact-source':
                self.artifact['workflow_run']['head_sha'] = self.prior_repair
            with self.subTest(change=change), self.assertRaises(recovery.RecoveryError):
                self.prove()

    def test_tv_reuse_never_bypasses_independent_original_product_approval(self):
        with patch.object(recovery, 'api', return_value=self.run), \
                patch.object(recovery, 'verify_source_run', side_effect=recovery.RecoveryError('unapproved')):
            with self.assertRaisesRegex(recovery.RecoveryError, 'unapproved'):
                recovery.verify_frozen_tvos_run(84, self.proof)
        with self.assertRaisesRegex(recovery.RecoveryError, 'iOS-only'):
            recovery.verify_source_run(42, self.repair, '3.0.31', tvos_run=84)

    def test_both_original_tv_package_certificates_must_bind_workflow_and_run(self):
        source = {'source_run_id': 84, 'workflow_source_sha': self.workflow, 'run_attempt': 1}
        certificate = {'sourceRepositoryIdentifier': '1433487464', 'sourceRepositoryDigest': self.workflow,
                       'runInvocationURI': 'https://github.com/' + recovery.REPOSITORY + '/actions/runs/84/attempts/1'}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ('pleazyng-tvos-unsigned.ipa', 'pleazyng-tvos-appstore.ipa'):
                (directory / name).write_bytes(name.encode())
            for change in (None, {'sourceRepositoryDigest': self.prior_repair},
                           {'runInvocationURI': 'https://github.com/' + recovery.REPOSITORY + '/actions/runs/85'}):
                cert = {**certificate, **(change or {})}
                verified = SimpleNamespace(stdout=json.dumps([{'verificationResult': {
                    'signature': {'certificate': cert}}}]))
                with self.subTest(change=change), patch.object(recovery.subprocess, 'run', return_value=verified) as verify:
                    if change:
                        with self.assertRaisesRegex(recovery.RecoveryError, 'attestation'):
                            recovery.verify_tvos_package_attestations(directory, source)
                    else:
                        digests = recovery.verify_tvos_package_attestations(directory, source)
                        self.assertEqual(len(digests), 2)
                        self.assertEqual(verify.call_count, 2)
                        for name, digest in digests.items():
                            self.assertEqual(digest, hashlib.sha256(name.encode()).hexdigest())


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

    def test_tvos_is_not_downloaded_from_failed_original_when_rebuilt(self):
        proof = {"source_run_id": 42, "source_sha": "a" * 40, "rebuild_tvos": True}
        with patch.object(recovery, "ARTIFACTS", {"tvos-ipa": "tvos-ipa"}), \
             patch.object(recovery, "collection", return_value=[]), \
             patch.object(recovery.subprocess, "run") as download:
            result = recovery.download_platforms(proof, self.root)
            download.assert_not_called()
            self.assertEqual(result["artifacts"], [])
        proof["rebuild_tvos"] = False
        with patch.object(recovery, "ARTIFACTS", {"tvos-ipa": "tvos-ipa"}), \
             patch.object(recovery, "collection", return_value=[]):
            with self.assertRaises(recovery.RecoveryError):
                recovery.download_platforms(proof, self.root)

    def test_ios_is_not_downloaded_from_failed_original_when_rebuilt(self):
        proof = {"source_run_id": 42, "source_sha": "a" * 40, "rebuild_ios": True}
        with patch.object(recovery, "ARTIFACTS", {"ios-ipa": "ios-ipa"}), \
             patch.object(recovery, "collection", return_value=[]), \
             patch.object(recovery.subprocess, "run") as download:
            result = recovery.download_platforms(proof, self.root)
            download.assert_not_called()
            self.assertEqual(result["artifacts"], [])
        proof["rebuild_ios"] = False
        with patch.object(recovery, "ARTIFACTS", {"ios-ipa": "ios-ipa"}), \
             patch.object(recovery, "collection", return_value=[]):
            with self.assertRaises(recovery.RecoveryError):
                recovery.download_platforms(proof, self.root)

    def test_repaired_linux_and_mac_artifacts_use_the_repaired_run_and_digest(self):
        archive = self.archive()
        names = ("linux-x64", "macos-dmg")
        items = [{"id": index, "name": name, "expired": False,
                  "digest": "sha256:" + hashlib.sha256(archive).hexdigest(),
                  "workflow_run": {"id": 84, "head_sha": "b" * 40}} for index, name in enumerate(names, 1)]
        proof = {"source_run_id": 42, "source_sha": "a" * 40,
                 "repaired_source": {"source_run_id": 84, "source_sha": "b" * 40}}
        def download(_args, stdout):
            stdout.write(archive)
            return SimpleNamespace(returncode=0)
        with patch.object(recovery, "ARTIFACTS", {name: name for name in names}), \
             patch.object(recovery, "collection", side_effect=[[], items]), \
             patch.object(recovery.subprocess, "run", side_effect=download):
            result = recovery.download_platforms(proof, self.root)
        self.assertEqual([record["source_run_id"] for record in result["artifacts"]], [84, 84])

    def test_webos_artifact_uses_its_successful_run_identity(self):
        archive = self.archive()
        item = {"id": 7, "name": "webos-ipk", "expired": False,
                "digest": "sha256:" + hashlib.sha256(archive).hexdigest(),
                "workflow_run": {"id": 84, "head_sha": "b" * 40}}
        proof = {"source_run_id": 42, "source_sha": "a" * 40,
                 "webos_source": {"source_run_id": 84, "source_sha": "b" * 40}}
        def download(_args, stdout):
            stdout.write(archive)
            return SimpleNamespace(returncode=0)
        with patch.object(recovery, "ARTIFACTS", {}), \
             patch.object(recovery, "collection", side_effect=[[], [item]]), \
             patch.object(recovery.subprocess, "run", side_effect=download):
            result = recovery.download_platforms(proof, self.root)
        self.assertEqual(result["artifacts"][0]["source_run_id"], 84)
        self.assertEqual((self.root / "webos/payload.exe").read_bytes(), b"binary")

    def test_tv_download_rechecks_exact_artifact_and_workflow_then_verifies_both_ipas(self):
        archive = self.archive()
        item = {'id': 7, 'name': 'tvos-ipa', 'expired': False,
                'digest': 'sha256:' + hashlib.sha256(archive).hexdigest(),
                'workflow_run': {'id': 84, 'head_sha': 'e' * 40}}
        source = {'source_run_id': 84, 'source_sha': 'd' * 40, 'workflow_source_sha': 'e' * 40,
                  'artifact_id': 7, 'artifact_digest': item['digest']}
        proof = {'source_run_id': 42, 'source_sha': 'a' * 40, 'tvos_source': source}
        def download(_args, stdout):
            stdout.write(archive)
            return SimpleNamespace(returncode=0)
        with patch.object(recovery, 'ARTIFACTS', {'tvos-ipa': 'tvos-ipa'}), \
                patch.object(recovery, 'collection', side_effect=[[], [item]]), \
                patch.object(recovery.subprocess, 'run', side_effect=download), \
                patch.object(recovery, 'verify_tvos_package_attestations', return_value={'verified': 'hash'}) as cert:
            result = recovery.download_platforms(proof, self.root)
        cert.assert_called_once()
        self.assertEqual(result['tvos_source']['package_sha256'], {'verified': 'hash'})
        self.assertEqual(result['artifacts'][0]['source_sha'], 'd' * 40)
        for change in ({'artifact_id': 8}, {'artifact_digest': 'sha256:' + 'f' * 64}):
            with self.subTest(change=change), patch.object(recovery, 'ARTIFACTS', {'tvos-ipa': 'tvos-ipa'}), \
                    patch.object(recovery, 'collection', side_effect=[[], [item]]), \
                    patch.object(recovery.subprocess, 'run') as download:
                with self.assertRaisesRegex(recovery.RecoveryError, 'ID/digest changed'):
                    recovery.download_platforms({**proof, 'tvos_source': {**source, **change}}, self.root)
                download.assert_not_called()

    def test_original_artifact_uses_product_head_even_with_later_workflow(self):
        archive = self.archive()
        item = {'id': 7, 'name': 'pleazyng-tizen-arm-experimental', 'expired': False,
                'digest': 'sha256:' + hashlib.sha256(archive).hexdigest(),
                'workflow_run': {'id': 42, 'head_sha': 'a' * 40}}
        proof = {'source_run_id': 42, 'source_sha': 'a' * 40,
                 'workflow_source_sha': 'c' * 40}
        def download(_args, stdout):
            stdout.write(archive)
            return SimpleNamespace(returncode=0)
        with patch.object(recovery, 'ARTIFACTS', {item['name']: 'tizen'}), \
                patch.object(recovery, 'collection', return_value=[item]), \
                patch.object(recovery.subprocess, 'run', side_effect=download):
            result = recovery.download_platforms(proof, self.root)
        self.assertEqual(result['artifacts'][0]['source_sha'], 'a' * 40)

    def test_frozen_assembly_binds_actual_checkout_workflow_run_and_linux_hash(self):
        proof = {'source_run_id': 42, 'source_sha': 'a' * 40,
                 'recovery_policy': 'frozen-apple-packaging-v1',
                 'packaging_source_sha': 'b' * 40, 'workflow_source_sha': 'c' * 40}
        linux = self.root / 'linux-x64/pleazyng-linux-x64.tar.gz'
        linux.parent.mkdir(); linux.write_bytes(b'original immutable Linux archive')
        with patch.object(recovery, 'ARTIFACTS', {}), \
             patch.object(recovery, 'collection', return_value=[]), \
             patch.object(recovery.subprocess, 'check_output', return_value='b' * 40), \
             patch.dict('os.environ', {'GITHUB_SHA': 'c' * 40, 'GITHUB_RUN_ID': '84'}):
            result = recovery.download_platforms(proof, self.root)
            self.assertEqual(result['assembly_run_id'], 84)
            self.assertEqual(result['actual_checkout_sha'], 'b' * 40)
            self.assertEqual(result['linux_archive_sha256'], hashlib.sha256(linux.read_bytes()).hexdigest())
            with patch.dict('os.environ', {'GITHUB_SHA': 'd' * 40}):
                with self.assertRaisesRegex(recovery.RecoveryError, 'workflow identity'):
                    recovery.download_platforms(proof, self.root)
            with patch.object(recovery.subprocess, 'check_output', return_value='d' * 40):
                with self.assertRaisesRegex(recovery.RecoveryError, 'did not check out'):
                    recovery.download_platforms(proof, self.root)

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
    @patch.object(controller, "verify_unacquired_hosted_tvos_run", return_value={"run_id": 77})
    @patch.object(controller, "matching_run")
    @patch.object(controller, "ensure_remote_main_sha")
    @patch.object(controller, "dispatch", return_value={
        "databaseId": 78, "status": "completed", "conclusion": "success",
    })
    def test_hosted_tvos_non_acquisition_recovers_only_tvos_on_private_jit(
        self, dispatch, ensure_main, matching, _allocation_evidence, verify
    ):
        matching.side_effect = [
            {"databaseId": 77, "status": "completed", "conclusion": "failure"},
            None,
        ]

        result = controller.ensure_release("v3.0.0", "b" * 40, include_webos_release=True)

        self.assertEqual(result["databaseId"], 78)
        ensure_main.assert_called_once_with("b" * 40, "dispatching the v3.0.0 release build")
        verify.assert_called_once_with(77, "b" * 40, "3.0.0", rebuild_tvos=True,
                                       webos_run=77, android_run=77)
        fields = dispatch.call_args.args[3]
        self.assertEqual(fields["tvos_runner_pool"], "private")
        self.assertEqual(fields["reuse_platform_run_id"], "77")
        self.assertEqual(fields["reuse_android_run_id"], "77")
        self.assertEqual(fields["reuse_webos_run_id"], "77")
        self.assertEqual(fields["rebuild_tvos"], "true")
        self.assertEqual(dispatch.call_args.kwargs["expected_title"],
                         "action:release:pool:private:tag:v3.0.0:recovery:source:77:tvos")

    @patch.object(controller, "verify_platform_recovery")
    @patch.object(controller, "matching_run", return_value=None)
    @patch.object(controller, "ensure_remote_main_sha")
    @patch.object(controller, "dispatch")
    def test_tvos_only_recovery_explicitly_reuses_android_and_webos(self, dispatch, _main, _matching, verify):
        controller.ensure_release("v3.0.0", "b" * 40, include_webos_release=True,
                                  reuse_platform_run_id=42, reuse_android_run_id=42,
                                  reuse_webos_run_id=42, rebuild_tvos=True)
        verify.assert_called_once_with(42, "b" * 40, "3.0.0", rebuild_tvos=True,
                                       webos_run=42, android_run=42)
        fields = dispatch.call_args.args[3]
        self.assertEqual(fields["rebuild_tvos"], "true")
        self.assertEqual(fields["reuse_android_run_id"], "42")
        self.assertEqual(fields["reuse_webos_run_id"], "42")
        self.assertNotIn("rebuild_macos", fields)
        self.assertNotIn("rebuild_linux", fields)

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

    def prove(self, **options):
        with patch.object(recovery, "api", side_effect=[self.source, self.compare]), \
             patch.object(recovery, "collection", return_value=self.jobs):
            return recovery.verify_android_run(84, "b" * 40, "3.0.0", **options)

    def test_pending_android_is_deferred_preflight_evidence_and_never_a_final_success(self):
        self.source["status"] = "in_progress"
        self.jobs[0].update(status="in_progress", conclusion=None)
        self.assertTrue(self.prove(allow_pending=True)["pending"])
        with self.assertRaises(recovery.RecoveryError):
            self.prove()
        self.jobs[0].update(status="completed", conclusion="failure")
        with self.assertRaisesRegex(recovery.RecoveryError, "uniquely successful"):
            self.prove(allow_pending=True)
        self.jobs[0]["conclusion"] = "success"
        self.assertNotIn("pending", self.prove(allow_pending=True))

    def test_reuses_only_successful_android_from_equivalent_product_inputs(self):
        self.assertEqual(self.prove()["job_id"], 71)
        self.compare["files"] = [{"filename": "android/app/build.gradle.kts"}]
        with self.assertRaisesRegex(recovery.RecoveryError, "input equivalence"):
            self.prove()

    def test_failed_or_untrusted_android_cannot_be_reused(self):
        for conclusion in ("failure", "cancelled", "timed_out"):
            with self.subTest(conclusion=conclusion):
                self.jobs[0]["conclusion"] = conclusion
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

    def test_pending_source_android_cannot_trigger_a_duplicate_fresh_android_build(self):
        with self.assertRaisesRegex(recovery.RecoveryError, "duplicate build"):
            recovery.compose_proof({"pending_jobs": ["build-android"]})


class RepairedSourceTests(unittest.TestCase):
    def setUp(self):
        recovery.immutable_content.cache_clear()
        self.run = {"status": "completed", "event": "workflow_dispatch", "head_branch": "main",
                    "head_repository": {"full_name": recovery.REPOSITORY}, "head_sha": "a" * 40,
                    "path": ".github/workflows/build.yml", "display_title": "action:release:pool:private:tag:v3.0.7"}
        self.compare = {"status": "ahead", "merge_base_commit": {"sha": "a" * 40}, "files": []}
        self.jobs = [{"name": name, "status": "completed", "conclusion": "success"} for name in
                     ("Validate release request", "Build Linux (x64)", "Build Linux (arm64)", "build-macos")]
        self.jobs[-1]["steps"] = [{"name": name, "status": "completed", "conclusion": "success"} for name in
                                  ("Build macOS", "Notarize Application", "Verify Gatekeeper acceptance for Homebrew Cask")]
        self.jobs += [{"name": "Build WebOS TV package (ARMv7)", "status": "completed", "conclusion": "failure"},
                      {"name": "create-release", "status": "completed", "conclusion": "skipped"}]
        self.workflow = 'env:\n  SDK: pinned\njobs:\n  build-macos:\n    run: compile-mac\n  build-linux:\n    run: compile-linux\n  other:\n'

    def prove(self, *, workflows=None, **options):
        with patch.object(recovery, "api", side_effect=[self.run, self.compare]), \
             patch.object(recovery, "collection", return_value=self.jobs), \
             patch.object(recovery, "immutable_content", side_effect=workflows or [self.workflow, self.workflow]):
            return recovery.verify_repaired_run(84, "b" * 40, "3.0.7", recovery.REPOSITORY, **options)

    def test_unrelated_failure_does_not_erase_the_three_verified_repaired_jobs(self):
        proof = self.prove(require_homebrew_cask=True)
        self.assertTrue(proof["platforms_complete"])
        self.assertTrue(proof["macos_cask_qualified"])
        self.assertEqual(len(proof["reused_jobs"]), 3)

    def test_pending_mac_is_allowed_only_in_preflight(self):
        self.run["status"] = "in_progress"
        self.jobs[3].update(status="queued", conclusion=None, steps=[])
        self.assertEqual(self.prove(allow_pending=True)["pending_jobs"], ["build-macos"])
        with self.assertRaises(recovery.RecoveryError):
            self.prove()

    def test_missing_mac_qualification_or_a_failed_repaired_job_is_rejected(self):
        self.jobs[3]["steps"].pop()
        with self.assertRaisesRegex(recovery.RecoveryError, "qualification"):
            self.prove(require_homebrew_cask=True)
        self.jobs[1]["conclusion"] = "failure"
        with self.assertRaisesRegex(recovery.RecoveryError, "did not succeed"):
            self.prove()

    def test_changed_compiler_contract_inputs_or_publication_are_rejected(self):
        with self.assertRaisesRegex(recovery.RecoveryError, "contracts changed"):
            self.prove(workflows=[self.workflow, self.workflow.replace('compile-mac', 'different-flags')])
        self.compare["files"] = [{"filename": "lib/main.dart"}]
        with self.assertRaisesRegex(recovery.RecoveryError, "inputs changed"):
            self.prove()
        self.compare["files"] = []
        self.jobs[-1]["conclusion"] = "success"
        with self.assertRaisesRegex(recovery.RecoveryError, "publication"):
            self.prove()

    def test_webos_can_be_reused_after_assembly_failed_before_publishing(self):
        self.jobs = [self.jobs[0], {"name": "Build WebOS TV package (ARMv7)", "status": "completed", "conclusion": "success"},
                     {"name": "create-release", "status": "completed", "conclusion": "failure",
                      "steps": [{"name": "Create Release", "conclusion": "skipped"}]}]
        before = 'env:\n  SDK: pinned\njobs:\n  build-webos:\n    if: ${{ trusted }}\n    run: compile-webos\n  other:\n'
        after = before.replace('if: ${{ ', "if: ${{ inputs.reuse_webos_run_id == '' && ")
        proof = self.prove(workflows=[before, after], webos_only=True)
        self.assertEqual(proof["reused_jobs"], ["Build WebOS TV package (ARMv7)"])
        self.jobs[-1]["steps"][0]["conclusion"] = "failure"
        with self.assertRaisesRegex(recovery.RecoveryError, "publication"):
            self.prove(workflows=[before, after], webos_only=True)


class AssemblyCheckoutTests(unittest.TestCase):
    def test_actual_sparse_checkout_imports_recovery_and_all_transitive_helpers(self):
        import subprocess
        root = Path(recovery.__file__).resolve().parents[1]
        workflow = (root / '.github/workflows/build.yml').read_text().split('\n  create-release:\n', 1)[1]
        selection = workflow.split('          sparse-checkout: |\n', 1)[1].split('          sparse-checkout-cone-mode:', 1)[0]
        patterns = [line.strip() for line in selection.splitlines() if line.strip()]
        tracked = sorted(set(
            subprocess.check_output(['git', 'ls-files', '-z', '--', 'scripts'], cwd=root).decode().split('\0')
            + ['scripts/verify_tvos_runner_acquisition.py']
        ))
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            for name in [name for name in tracked if name] + [name for name in patterns if '*' not in name]:
                target = checkout / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(root / name, target)
            def git(*args, **kwargs):
                return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
                                       '-c', 'core.autocrlf=false', *args], cwd=checkout, capture_output=True, text=True, check=True, **kwargs)
            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Assembly Test', '-c', 'user.email=assembly-test@example.invalid', 'commit', '-qm', 'fixture')
            git('sparse-checkout', 'set', '--no-cone', '--stdin', input='\n'.join(patterns) + '\n')
            code = "import sys; sys.path.insert(0, 'scripts'); import recover_release_platforms, release_all_platforms, verify_webos_link_patch; recover_release_platforms.release_ci._manifest_gate()"
            result = subprocess.run([sys.executable, '-I', '-c', code], cwd=checkout, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
