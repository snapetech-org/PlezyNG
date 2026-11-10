"""Keep verified GitHub publication independent of downstream delivery."""
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_all_platforms as release


class CorePublicationTests(unittest.TestCase):
    def setUp(self):
        automatic = patch.object(release, 'dispatch_automatic_play', return_value=None)
        automatic.start()
        self.addCleanup(automatic.stop)
        aerynos = patch.object(release, 'dispatch_aerynos_delivery', return_value={})
        aerynos.start()
        self.addCleanup(aerynos.stop)
        embedded = patch.object(release, 'embedded_ci_proof',
                                return_value={'mode': 'embedded', 'run_id': 2, 'attempt': 1})
        embedded.start()
        self.addCleanup(embedded.stop)

    def test_only_channel_metadata_is_optional_and_collected_when_present(self):
        workflow = yaml.safe_load((Path(__file__).resolve().parents[2] / ".github/workflows/build.yml").read_text())
        jobs = workflow["jobs"]
        windows = next(job for job in jobs.values() if any(step.get("name") == "Package Chocolatey release" for step in job.get("steps", [])))
        steps = {step.get("name"): step for step in windows["steps"]}
        for name in ("Build installer and portables", "Attest Windows artifacts", "Upload installer"):
            self.assertFalse(steps[name].get("continue-on-error", False))
        self.assertTrue(steps["Package Chocolatey release"]["continue-on-error"])
        linux = {step.get("name"): step for step in jobs["build-linux"]["steps"]}
        for name in ("Build Flatpak bundle", "Build Snap package"):
            self.assertFalse(linux[name].get("continue-on-error", False))
        release_steps = {step.get("name"): step for step in jobs["create-release"]["steps"]}
        self.assertFalse(release_steps["Require every release platform before publication"].get("continue-on-error", False))
        self.assertTrue(release_steps["Generate WinGet manifest bundle"]["continue-on-error"])
        script = release_steps["Collect release files"]["run"]
        for metadata in (False, True):
            with self.subTest(metadata=metadata), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                package = root / "artifacts/windows-chocolatey/pleazyng.3.0.1.nupkg"
                manifest = root / "artifacts/pleazyng-winget-manifests-3.0.1.zip"
                if metadata:
                    package.parent.mkdir(parents=True)
                    package.write_bytes(b"metadata")
                    manifest.write_bytes(b"metadata")
                output = root / "output"
                env = {**os.environ, "GITHUB_OUTPUT": str(output), "RELEASE_VERSION": "3.0.1",
                       "INCLUDE_WEBOS_RELEASE": "true", "EXECUTION_PROFILE": "hybrid", "PREPARE_HOMEBREW_CASK": "false"}
                subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=root, env=env, check=True, capture_output=True)
                files = output.read_text()
                self.assertEqual("windows-chocolatey" in files, metadata)
                self.assertEqual("winget-manifests" in files, metadata)
                self.assertIn("artifacts/windows-installer/pleazyng-windows-installer.exe", files)
                self.assertIn("artifacts/webos/*.ipk", files)
                self.assertIn("artifacts/webos/pleazyng-lg-webos-submission.zip", files)
                for evidence in ("webos-app-provenance.json", "webos-engine-provenance.json", "webos-compatibility.json", "macos-compilation-recovery.json"):
                    self.assertNotIn(evidence, files)
        webos_steps = {step.get("name"): step for step in jobs['build-webos']['steps']}
        handoff = webos_steps['Prepare LG Seller Lounge handoff bundle']['run']
        for evidence in ("webos-app-provenance.json", "webos-engine-provenance.json", "webos-compatibility.json"):
            self.assertIn('--evidence "$OUTPUT_DIR/' + evidence + '"', handoff)


    def test_notification_and_channel_failures_are_separate_results(self):
        for fail in (False, True):
            with self.subTest(exception=fail), patch.object(release, "command", side_effect=release.ReleaseError("notice offline")), \
                 patch.object(release, "publish_configured_channels", side_effect=release.ReleaseError("store configuration") if fail else None,
                              return_value=([], [], ["store upload refused"])):
                result = release.post_release_actions("v3.0.1", "3.0.1", release_sha="a" * 40,
                    include_webos_release=True, publish_channels=True)
                self.assertEqual(result["notification_failures"], ["notice offline"])
                self.assertTrue(result["channel_failures"])

    def test_published_core_stays_successful_when_followups_fail(self):
        for publish, invalid_core in ((False, False), (True, False), (False, True)):
            with self.subTest(channels=publish, invalid_core=invalid_core), tempfile.TemporaryDirectory() as scratch, contextlib.ExitStack() as stack:
                flags = ["--publish"] if publish else ["--publish-github-only"]
                stack.enter_context(patch.object(sys, "argv", ["release", "--version", "3.0.1", *flags, "--scratch", scratch]))
                def command(args, **kwargs):
                    if args[:3] == ["gh", "workflow", "run"]:
                        progress = json.loads((Path(scratch) / "release-progress.json").read_text())
                        self.assertTrue(progress["release_published"])
                        self.assertEqual(progress["status"], "success")
                        raise release.ReleaseError("notification service unavailable")
                    return subprocess.CompletedProcess(args, 0, "3.0.1" if args[0] == "python3" else "a" * 40, "")
                stack.enter_context(patch.object(release, "command", side_effect=command))
                core = {}
                for name in ("validate_immutable_release_tag", "ensure_remote_main_sha", "ensure_frozen_release_source", "refresh_latest_published_facts", "validate_release_outputs", "publish_github_release"):
                    core[name] = stack.enter_context(patch.object(release, name))
                core["refresh_latest_published_facts"].return_value = "b" * 40
                stack.enter_context(patch.object(release, "gh_json", return_value={"commit": {"sha": "b" * 40}}))
                stack.enter_context(patch.object(release, "create_plezy_worktree", return_value=Path(scratch) / "plezyng-main"))
                stack.enter_context(patch.object(release, "existing_release_tag_commit", return_value="a" * 40))
                stack.enter_context(patch.object(release, "ensure_ci", return_value={"databaseId": 1}))
                build = stack.enter_context(patch.object(release, "ensure_release", return_value={"databaseId": 2}))
                channels = stack.enter_context(patch.object(release, "publish_configured_channels", side_effect=release.ReleaseError("store upload unavailable")))
                if invalid_core:
                    core["validate_release_outputs"].side_effect = release.ReleaseError("required platform missing")
                    with self.assertRaisesRegex(release.ReleaseError, "required platform missing"):
                        release.main()
                    core["publish_github_release"].assert_not_called()
                    channels.assert_not_called()
                    progress = json.loads((Path(scratch) / "release-progress.json").read_text())
                    self.assertEqual(progress["status"], "failed")
                    continue
                self.assertEqual(release.main(), 0)
                self.assertEqual(build.call_count, 2)
                self.assertTrue(build.call_args_list[0].kwargs['start_only'])
                self.assertEqual(build.call_args.kwargs['candidate_ref'], 'v3.0.1-candidate.' + 'a' * 40)
                self.assertNotIn('source_ref', build.call_args.kwargs)
                self.assertFalse(build.call_args.kwargs["include_apple_store_build"])
                self.assertFalse(build.call_args.kwargs["prepare_homebrew_cask"])
                self.assertEqual(channels.call_count, int(publish))
                report = json.loads((Path(scratch) / "release-summary.json").read_text())
                self.assertTrue(report["release_published"])
                self.assertEqual(report['ci_mode'], 'embedded')
                self.assertEqual(report["aerynos_automation"], [{}])
                self.assertTrue(report["notification_failures"])
                self.assertEqual(bool(report["channel_failures"]), publish)
                progress = json.loads((Path(scratch) / "release-progress.json").read_text())
                self.assertEqual(progress["status"], "success")
                self.assertEqual(progress["plezyng_commit"], "a" * 40)
                self.assertEqual(progress["delivery_tooling_commit"], "b" * 40)

    def test_bad_play_configuration_does_not_stop_another_channel(self):
        settings = {"GOOGLE_PLAY_TRACK": "production", "GOOGLE_PLAY_BOOTSTRAP_COMPLETE": "true",
                    "AMAZON_APPSTORE_BOOTSTRAP_COMPLETE": "true", "AMAZON_APPSTORE_APP_ID": "example"}
        secrets = {"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON", "AMAZON_APPSTORE_CLIENT_ID", "AMAZON_APPSTORE_CLIENT_SECRET"}
        assets = {"pleazyng-android-play.aab", "pleazyng-amazon-firetv.apk", "SHA256SUMS.txt"}
        with patch.object(release, "release_metadata", return_value={"assets": [{"name": name} for name in assets]}), \
             patch.object(release, "configured_repo_names", return_value=secrets), \
             patch.object(release, "configured_repo_variables", return_value=settings), \
             patch.object(release, "ensure_channel_run", return_value={"databaseId": 42}) as dispatch:
            completed, _, failures = release.publish_configured_channels("v3.0.1", "3.0.1", release_sha="a" * 40,
                                                                         include_webos_release=True)
            self.assertTrue(any("Google Play configuration" in error for error in failures))
            self.assertTrue(any(item["channel"] == "Amazon Appstore upload" for item in completed))
            self.assertTrue(all(call.args[2].get("channel") != "google-play" for call in dispatch.call_args_list))

    def test_tooling_lookup_and_unexpected_followup_failure_preserve_published_core(self):
        for failure in ('lookup', 'followup'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as scratch, contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(sys, 'argv', ['release', '--version', '3.0.30',
                    '--publish-github-only', '--scratch', scratch]))
                stack.enter_context(patch.object(release, 'command', side_effect=lambda args, **kwargs:
                    subprocess.CompletedProcess(args, 0, '3.0.30' if args[0] == 'python3' else 'a' * 40, '')))
                for name in ('ensure_frozen_release_source', 'validate_release_outputs', 'publish_github_release'):
                    stack.enter_context(patch.object(release, name))
                stack.enter_context(patch.object(release, 'create_plezy_worktree', return_value=Path(scratch) / 'product'))
                stack.enter_context(patch.object(release, 'existing_release_tag_commit', return_value='a' * 40))
                stack.enter_context(patch.object(release, 'ensure_ci', return_value={'databaseId': 1}))
                build = stack.enter_context(patch.object(release, 'ensure_release', return_value={'databaseId': 2}))
                stack.enter_context(patch.object(release, 'refresh_latest_published_facts', return_value='b' * 40))
                stack.enter_context(patch.object(release, 'gh_json',
                    side_effect=release.ReleaseError('main temporarily unavailable') if failure == 'lookup' else None,
                    return_value={'commit': {'sha': 'b' * 40}}))
                stack.enter_context(patch.object(release, 'post_release_actions',
                    side_effect=release.ReleaseError('unexpected delivery failure')))
                self.assertEqual(release.main(), 0)
                report = json.loads((Path(scratch) / 'release-summary.json').read_text())
                progress = json.loads((Path(scratch) / 'release-progress.json').read_text())
                self.assertTrue(report['release_published'])
                self.assertEqual(progress['status'], 'success')
                self.assertIn('Post-publication delivery:', report['channel_failures'][0])
                self.assertEqual(build.call_count, 2)


if __name__ == "__main__":
    unittest.main()
