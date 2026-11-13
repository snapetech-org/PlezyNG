#!/usr/bin/env python3
"""Behavior tests for the privileged build-workflow guard."""

from pathlib import Path
from contextlib import redirect_stderr
import io
import runpy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import yaml


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/checks/check_build_workflow.py"
WORKFLOW = ROOT / ".github/workflows/build.yml"
SETUP_FLUTTER_GIT = ROOT / ".github/actions/setup-flutter-git/action.yml"
WINDOWS_CMAKE = ROOT / "windows/CMakeLists.txt"
WINDOWS_MPV_DOWNLOADER = ROOT / "windows/tool/download-pinned-mpv.ps1"
MPV_BUILD_LOCK = ROOT / "mpv-build.lock.json"
WINDOWS_SIMDUTF_DOWNLOADER = ROOT / "windows/tool/download-pinned-simdutf.ps1"
WINDOWS_WINSPARKLE_DOWNLOADER = ROOT / "windows/tool/download-pinned-winsparkle.ps1"
WINDOWS_SDL3_DOWNLOADER = ROOT / "windows/tool/download-pinned-sdl3.ps1"
WINDOWS_TORRENT_DEPENDENCIES_DOWNLOADER = (
    ROOT / "windows/tool/download-pinned-torrent-dependencies.ps1"
)
WINDOWS_TOOLCHAIN_LOCK = ROOT / "windows/tool/build-toolchain.lock.json"
PLEZY_TORRENT_CMAKE = ROOT / "packages/plezy_torrent/src/CMakeLists.txt"
STEAM_CMAKE = ROOT / "native/games/steam/CMakeLists.txt"


class BuildWorkflowGuardTest(unittest.TestCase):
    def test_profile_preflight_cannot_leave_trusted_native_bounded_route_or_break_core_serialization(self):
        original = self._workflow()
        begin = original.index('  apple-signing-preflight:\n')
        end = original.index('  capture-candidate:\n', begin)
        job = original[begin:end]
        for invalid in (job.replace("github.ref == 'refs/heads/main'", 'true'),
                        job.replace('macos-26-intel', 'ubuntu-24.04'),
                        job.replace('timeout-minutes: 10', 'timeout-minutes: 100'),
                        job.replace('--prepare-ios-worker-profile --public-report', '--platform ios'),
                        job.replace("inputs.action == 'apple-signing-preflight'", "inputs.action == 'apple-signing-preflight' || true"),
                        job + '      - run: xcodebuild build\n'):
            with self.subTest(invalid=invalid):
                result = self._run(original[:begin] + invalid + original[end:])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('iOS profile preflight must stay separate', result.stderr)
        for group in ('pleazyng-core-release-v2', 'pleazyng-versioned-release-v2',
                      'pleazyng-candidate-build-v2'):
            with self.subTest(group=group):
                changed = original.replace(f"'{group}'", "github.run_id")
                self.assertNotEqual(changed, original)
                self.assertNotEqual(self._run(changed).returncode, 0)

    def test_ios_steam_preparation_retries_network_failure_and_stops_at_bound(self):
        step = next(step for step in yaml.safe_load(self._workflow())['jobs']['build-ios']['steps']
                    if step.get('name') == 'Prepare pinned iOS Steam sources before Xcode')
        self.assertEqual(step['working-directory'], '${{ env.PLEZYNG_APPLE_WORKSPACE }}')
        with tempfile.TemporaryDirectory(prefix='ios-steam-prefetch-') as directory:
            root = Path(directory)
            tools = root / 'tools'
            tools.mkdir()
            script = tools / 'python3'
            script.write_text(f'#!{sys.executable}\n' + '''import json, os, pathlib, sys
p = pathlib.Path(os.environ['CALLS'])
calls = json.loads(p.read_text()) if p.exists() else []
calls.append({'cwd': os.getcwd(), 'args': sys.argv[1:]})
p.write_text(json.dumps(calls))
sys.exit(1 if len(calls) <= int(os.environ['FAIL_UNTIL']) else 0)
''')
            script.chmod(0o700)
            sleep = tools / 'sleep'
            sleep.write_text('#!/bin/sh\nexit 0\n')
            sleep.chmod(0o700)
            for failures, expected_calls, success in [(0, 1, True), (2, 3, True), (3, 3, False)]:
                calls = root / f'calls-{failures}.json'
                result = subprocess.run(['bash', '-c', step['run']], cwd=root,
                                        env={**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH'],
                                             'CALLS': str(calls), 'FAIL_UNTIL': str(failures)},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                observed = json.loads(calls.read_text())
                self.assertEqual(len(observed), expected_calls)
                self.assertTrue(all(call == {'cwd': str(root), 'args': ['scripts/games/prepare_steam.py']}
                                    for call in observed))

    def test_ios_steam_preparation_cannot_be_skipped_or_use_original_checkout(self):
        original = self._workflow()
        start = original.index('      - name: Prepare pinned iOS Steam sources before Xcode\n')
        end = original.index('      - name: Refresh pinned mpv Swift packages\n', start)
        step = original[start:end]
        for invalid in [step.replace('        working-directory:', '        if: false\n        working-directory:'),
                        step.replace('${{ env.PLEZYNG_APPLE_WORKSPACE }}', '${{ github.workspace }}'),
                        step.replace('timeout-minutes: 15', 'timeout-minutes: 150'),
                        step.replace('for attempt in 1 2 3;', 'for attempt in 1 2 3 4;')]:
            with self.subTest(invalid=invalid):
                result = self._run(original[:start] + invalid + original[end:])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('iOS must prepare pinned Steam sources', result.stderr)

    def test_recovery_builds_must_evaluate_after_skipped_capture_ancestors(self):
        original = self._workflow()
        for prefix in ("always() && ", "!cancelled() && ", "needs.validate-trusted-ref.result == 'success' && "):
            changed = original.replace(prefix, '')
            self.assertNotEqual(changed, original)
            self.assertNotEqual(self._run(changed).returncode, 0)

    def test_apple_architecture_and_public_source_credit_cannot_be_removed(self):
        original = self._workflow()
        for old, new in [('ARCHS = arm64', 'ARCHS = arm64 arm64e'),
                         ('cat UPSTREAM_ATTRIBUTION.md >> release-notes.md', 'true'),
                         ('"$COMPILE_SOURCE_SHA"', '"$GITHUB_SHA"')]:
            with self.subTest(removed=old):
                changed = original.replace(old, new)
                self.assertNotEqual(changed, original)
                result = self._run(changed)
                self.assertNotEqual(result.returncode, 0)

    def test_linux_runtime_cannot_skip_registered_tests_or_unavailable_entropy(self):
        ci_path = ROOT / '.github/workflows/ci.yml'
        original = Path.read_text
        ci = original(ci_path, encoding='utf-8')
        variants = [ci.replace('            music_dual_core_test \\\n', ''),
                    ci.replace('      - name: Run Linux native reliability tests\n',
                               '      - name: Run Linux native reliability tests\n        if: false\n')]
        for invalid in variants:
            self.assertNotEqual(invalid, ci)

            def read(path, *args, **kwargs):
                return invalid if path == ci_path else original(path, *args, **kwargs)

            errors = io.StringIO()
            with patch.object(Path, 'read_text', read), patch.object(sys, 'argv', [str(CHECKER)]), \
                    redirect_stderr(errors), self.assertRaises(SystemExit) as result:
                runpy.run_path(str(CHECKER), run_name='__main__')
            self.assertEqual(result.exception.code, 1)
            self.assertIn('Linux native', errors.getvalue())

    def test_captured_release_cannot_skip_qualified_source_or_inherit_ci_secrets(self):
        original = self._workflow()
        variants = [original.replace("needs.release-ci.result == 'success'", "needs.release-ci.result == 'skipped'"),
                    original.replace('    needs: freeze-qualified-source\n', '    needs: capture-candidate\n'),
                    original.replace('    uses: ./.github/workflows/ci.yml\n',
                                     '    uses: ./.github/workflows/ci.yml\n    secrets: inherit\n')]
        for workflow in variants:
            with self.subTest(workflow=workflow[:20]):
                result = self._run(workflow)
                self.assertNotEqual(result.returncode, 0)

    def test_ios_recovery_cannot_skip_fresh_success_or_locked_worker_prebuild(self):
        original = self._workflow()
        skipped = original.replace("inputs.rebuild_ios && needs.build-ios.result == 'success'",
                                   "inputs.rebuild_ios && needs.build-ios.result == 'skipped'")
        unstaged = original.replace('-scheme Pods-RommWorker', '-scheme Pods-Runner')
        wrong_lipo_order = original.replace(
            "['xcrun', 'lipo', str(binary), '-verify_arch', 'arm64']",
            "['xcrun', 'lipo', '-verify_arch', 'arm64', str(binary)]",
        )
        for workflow in (skipped, unstaged, wrong_lipo_order):
            with self.subTest(skipped=workflow is skipped):
                result = self._run(workflow)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("iOS recovery must stage", result.stderr)

    def test_tvos_recovery_rejects_incompatible_host_and_missing_fresh_success(self):
        original = self._workflow()
        start = original.index("  build-tvos:\n")
        end = original.index("  build-macos:\n", start)
        incompatible = (original[:start] + original[start:end].replace("&& 'macos-26' ||", "&& 'macos-26-intel' ||")
                        + original[end:])
        skipped = original.replace("inputs.rebuild_tvos && needs.build-tvos.result == 'success'",
                                   "inputs.rebuild_tvos && needs.build-tvos.result == 'skipped'")
        for workflow in (incompatible, skipped):
            with self.subTest(workflow=workflow is incompatible):
                self.assertNotEqual(workflow, original)
                result = self._run(workflow)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("tvOS AOT recovery", result.stderr)

    def _run(
        self,
        workflow: str,
        action: str | None = None,
        cmake: str | None = None,
        mpv_downloader: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="plezy-build-workflow-test-") as directory:
            # The checker resolves Windows bootstrap files and native CMake
            # sources beside the workflow, so the fixture mirrors them.
            github = Path(directory) / ".github"
            fixture = github / "workflows/build.yml"
            fixture.parent.mkdir(parents=True)
            fixture.write_text(workflow, encoding="utf-8")
            bootstrap = github / "actions/setup-flutter-git/action.yml"
            bootstrap.parent.mkdir(parents=True)
            bootstrap.write_text(action if action is not None else self._action(), encoding="utf-8")
            cmake_fixture = Path(directory) / "windows/CMakeLists.txt"
            cmake_fixture.parent.mkdir(parents=True)
            cmake_fixture.write_text(cmake if cmake is not None else self._cmake(), encoding="utf-8")
            downloader_fixture = Path(directory) / "windows/tool/download-pinned-mpv.ps1"
            downloader_fixture.parent.mkdir(parents=True)
            downloader_fixture.write_text(
                (
                    mpv_downloader
                    if mpv_downloader is not None
                    else WINDOWS_MPV_DOWNLOADER.read_text(encoding="utf-8")
                ),
                encoding="utf-8",
            )
            (Path(directory) / "mpv-build.lock.json").write_text(
                MPV_BUILD_LOCK.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            simdutf_downloader_fixture = (
                Path(directory) / "windows/tool/download-pinned-simdutf.ps1"
            )
            simdutf_downloader_fixture.write_text(
                WINDOWS_SIMDUTF_DOWNLOADER.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            winsparkle_downloader_fixture = (
                Path(directory) / "windows/tool/download-pinned-winsparkle.ps1"
            )
            winsparkle_downloader_fixture.write_text(
                WINDOWS_WINSPARKLE_DOWNLOADER.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            sdl3_downloader_fixture = Path(directory) / "windows/tool/download-pinned-sdl3.ps1"
            sdl3_downloader_fixture.write_text(
                WINDOWS_SDL3_DOWNLOADER.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            torrent_dependencies_downloader_fixture = (
                Path(directory) / "windows/tool/download-pinned-torrent-dependencies.ps1"
            )
            torrent_dependencies_downloader_fixture.write_text(
                WINDOWS_TORRENT_DEPENDENCIES_DOWNLOADER.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            lock_fixture = Path(directory) / "windows/tool/build-toolchain.lock.json"
            lock_fixture.write_text(
                WINDOWS_TOOLCHAIN_LOCK.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            torrent_cmake_fixture = (
                Path(directory) / "packages/plezy_torrent/src/CMakeLists.txt"
            )
            torrent_cmake_fixture.parent.mkdir(parents=True)
            torrent_cmake_fixture.write_text(
                PLEZY_TORRENT_CMAKE.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            steam_cmake_fixture = (
                Path(directory) / "native/games/steam/CMakeLists.txt"
            )
            steam_cmake_fixture.parent.mkdir(parents=True)
            steam_cmake_fixture.write_text(
                STEAM_CMAKE.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            return subprocess.run(
                [sys.executable, str(CHECKER), str(fixture)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

    def _workflow(self) -> str:
        return WORKFLOW.read_text(encoding="utf-8")

    def _action(self) -> str:
        return SETUP_FLUTTER_GIT.read_text(encoding="utf-8")

    def _cmake(self) -> str:
        return WINDOWS_CMAKE.read_text(encoding="utf-8")

    def _mutate_signer(self, old: str, new: str) -> str:
        prefix, signing = self._workflow().split("      - name: Sign installer for WinSparkle (EdDSA)\n", 1)
        changed = signing.replace(old, new, 1)
        self.assertNotEqual(changed, signing, "signer mutation must match")
        return prefix + "      - name: Sign installer for WinSparkle (EdDSA)\n" + changed

    def test_apple_native_tests_preserve_architecture_and_asset_compatible_toolchains(self):
        ci_path = ROOT / '.github/workflows/ci.yml'
        original = Path.read_text
        ci = original(ci_path, encoding='utf-8')
        selection = "inputs.execution_profile == 'hybrid' && (inputs.apple_runner_pool != 'private' || matrix.platform != 'macOS') && 'macos-26' || fromJSON(format("
        self.assertIn(selection, ci)
        changes = [
            ("'macos-26'", "'macos-26-intel'"),
            ("'macos-26'", "'macos-15'"),
            ("hosted-xcode-version: '26.5'",
             "hosted-xcode-version: '26.3'"),
            ('test "$(uname -m)" = arm64', 'true'),
        ]
        for before, after in changes:
            with self.subTest(before=before, after=after):
                # Restrict label mutations to this native matrix, preserving
                # unrelated jobs so a different guard cannot mask this check.
                if before.startswith("'macos-"):
                    invalid = ci.replace(selection, selection.replace(before, after), 1)
                else:
                    invalid = ci.replace(before, after, 1)
                self.assertNotEqual(invalid, ci)
                def read(path, *args, **kwargs):
                    return invalid if path == ci_path else original(path, *args, **kwargs)
                errors = io.StringIO()
                with patch.object(Path, 'read_text', read), patch.object(sys, 'argv', [str(CHECKER)]):
                    with redirect_stderr(errors), self.assertRaises(SystemExit) as result:
                        runpy.run_path(str(CHECKER), run_name='__main__')
                self.assertEqual(result.exception.code, 1)
                self.assertIn('Apple arm64 native qualification', errors.getvalue())

    def test_locked_root_signer_passes(self) -> None:
        result = self._run(self._workflow())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("architecture matrix checks passed", result.stdout)

    def test_webos_link_exception_requires_its_exact_change_verifier(self) -> None:
        workflow = self._workflow()
        command = 'python3 scripts/verify_webos_link_patch.py "$release_commit" "$GITHUB_SHA"'
        self.assertIn(command, workflow)
        result = self._run(workflow.replace(command, ':', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('immutable ancestors', result.stderr)

    def test_assembly_checkout_must_include_transitive_script_imports(self) -> None:
        workflow = self._workflow()
        result = self._run(workflow.replace('            scripts/**\n', '            scripts/recover_release_platforms.py\n', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('sparse checkout', result.stderr)

    def test_store_msix_cannot_reuse_unlocked_direct_payload(self) -> None:
        workflow = self._workflow()
        result = self._run(workflow.replace('-X64BuildDir "build-store-x64"', '-X64BuildDir "build-x64"', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('separate trial/IAP payloads', result.stderr)

    def test_msix_arm64_does_not_widen_the_direct_installer(self) -> None:
        workflow = self._workflow()
        original = 'run: .\\windows\\build-installer.ps1 -X64BuildDir "build-x64"'
        self.assertIn(original, workflow)
        result = self._run(workflow.replace(original, original + ' -Arm64BuildDir "build-store-arm64"', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('installer and Chocolatey packages remain x64', result.stderr)

    def test_recovery_requires_source_verification_and_public_provenance(self) -> None:
        for original in ("--download artifacts", "needs.validate-trusted-ref.outputs.reuse_source_sha != ''",
                         "needs.validate-trusted-ref.outputs.android_source_sha != ''",
                         "needs.validate-trusted-ref.outputs.webos_source_sha != ''"):
            with self.subTest(original=original):
                changed = self._workflow().replace(original, "REMOVED", 1)
                result = self._run(changed)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("platform artifact recovery must verify", result.stderr)

    def test_apple_release_jobs_require_utf8_locale(self) -> None:
        workflow = self._workflow()
        self.assertIn("      LANG: en_US.UTF-8\n", workflow)
        workflow = workflow.replace("      LANG: en_US.UTF-8\n", "", 1)

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "build-ios must use a UTF-8 locale for CocoaPods and Ruby",
            result.stderr,
        )

    def test_macos_release_build_uses_flutter_xcode_signing_overrides(self) -> None:
        workflow = self._workflow()
        mutations = (
            (
                "flutter build macos --release",
                "flutter build macos --release --no-codesign",
            ),
            (
                'FLUTTER_XCODE_CODE_SIGNING_ALLOWED: "NO"',
                'FLUTTER_XCODE_CODE_SIGNING_ALLOWED: "YES"',
            ),
            (
                'FLUTTER_XCODE_CODE_SIGNING_REQUIRED: "NO"',
                'FLUTTER_XCODE_CODE_SIGNING_REQUIRED: "YES"',
            ),
            (
                'FLUTTER_XCODE_CODE_SIGNING_IDENTITY: ""',
                'FLUTTER_XCODE_CODE_SIGNING_IDENTITY: "-"',
            ),
        )
        for original, mutated in mutations:
            with self.subTest(original=original):
                self.assertIn(original, workflow, f"missing macOS setting: {original}")
                changed = workflow.replace(original, mutated, 1)
                result = self._run(changed)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "macOS release build must use Flutter's Xcode build-setting overrides",
                    result.stderr,
                )

    def test_macos_private_route_and_bounded_build_timeouts_are_enforced(self) -> None:
        workflow = self._workflow()
        start = workflow.index("  build-macos:\n")
        end = workflow.index("  build-windows:\n", start)
        macos = workflow[start:end]
        self.assertIn("inputs.tvos_runner_pool == 'hosted' && 'macos-26-intel' || fromJSON(format(", macos)
        self.assertIn("timeout-minutes: 150", macos)
        self.assertIn("timeout-minutes: 100", macos)

        mutations = (
            (
                "inputs.tvos_runner_pool == 'hosted' && 'macos-26-intel' ||",
                "inputs.execution_profile == 'hybrid' && 'macos-26-intel' ||",
                "the explicit private Apple route must include macOS",
            ),
            (
                "timeout-minutes: 150",
                "timeout-minutes: 360",
                "Apple package jobs and the macOS compile step must have explicit bounded timeouts",
            ),
            (
                "timeout-minutes: 100",
                "timeout-minutes: 360",
                "Apple package jobs and the macOS compile step must have explicit bounded timeouts",
            ),
        )
        for original, replacement, expected in mutations:
            with self.subTest(original=original):
                changed = workflow[:start] + macos.replace(original, replacement, 1) + workflow[end:]
                self.assertNotEqual(changed, workflow)
                result = self._run(changed)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_macos_signing_preflight_cannot_move_after_compilation(self) -> None:
        workflow = self._workflow()
        start = workflow.index("      - name: Import Code Signing Certificate\n")
        end = workflow.index("      - name: Verify Apple notarization credentials before compilation\n", start)
        block = workflow[start:end]
        changed = workflow[:start] + workflow[end:]
        insertion = changed.index("      - name: Sign Application\n")
        changed = changed[:insertion] + block + changed[insertion:]
        result = self._run(changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signing and notary preflights must precede Flutter", result.stderr)

    def test_readonly_framework_signing_preparation_is_required(self) -> None:
        workflow = self._workflow()
        command = ('          python3 scripts/apple/prepare_macos_app_for_signing.py "$APP_PATH" \\\n'
                   '            --entitlements-source macos/Runner/Release.entitlements \\\n'
                   '            --entitlements-output "$RUNNER_TEMP/macos-release-entitlements.plist"\n')
        self.assertIn(command, workflow)
        result = self._run(workflow.replace(command, '', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('prepare read-only embedded copies', result.stderr)

    def test_release_sparse_checkout_cannot_omit_coverage_validator(self) -> None:
        workflow = self._workflow()
        entry = '            scripts/**\n'
        self.assertIn(entry, workflow)
        result = self._run(workflow.replace(entry, '', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('sparse checkout must include every executed script', result.stderr)

    def test_successful_compilation_must_be_retained_before_signing(self) -> None:
        workflow = self._workflow()
        command = 'run: python3 "$GITHUB_WORKSPACE/scripts/retain_macos_app.py" capture'
        self.assertIn(command, workflow)
        result = self._run(workflow.replace(command, 'run: echo missing snapshot', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('snapshots must survive packaging failure', result.stderr)

    def test_macos_signing_preflight_requires_public_chain_and_real_probe(self) -> None:
        for removed in (
            '          security import "$CHAIN_PATH" -k "$KEYCHAIN_PATH"\n',
            '          codesign --verify --strict "$RUNNER_TEMP/macos-signing-probe"\n',
        ):
            with self.subTest(removed=removed):
                workflow = self._workflow()
                self.assertIn(removed, workflow)
                result = self._run(workflow.replace(removed, "", 1))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("preflight must qualify its isolated keychain", result.stderr)

    def test_github_only_macos_release_skips_optional_developer_id_signing(self) -> None:
        workflow = self._workflow().replace(
            'if [[ "$REQUIRE_HOMEBREW_CASK" != "true" ]]; then',
            "if false; then",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "signing mutation must match")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "GitHub-only macOS releases must ignore optional Developer ID secrets",
            result.stderr,
        )

    def test_windows_release_requires_pinned_torrent_dependencies(self) -> None:
        workflow = self._workflow()
        step = (
            "      - name: Download and verify pinned Windows torrent dependencies\n"
            "        shell: pwsh\n"
            "        run: .\\windows\\tool\\download-pinned-torrent-dependencies.ps1\n\n"
        )
        self.assertIn(step, workflow, "torrent dependency step changed")
        workflow = workflow.replace(step, "", 1)

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Windows release builds must predownload and verify Boost/libtorrent",
            result.stderr,
        )

    def test_windows_cmake_install_prefix_stays_concrete_and_bundles_use_target_dir(self) -> None:
        cmake = self._cmake()
        mutations = (
            (
                'set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}" CACHE PATH',
                'set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH',
            ),
            (
                'set(INSTALL_BUNDLE_LIB_DIR "${BUILD_BUNDLE_DIR}")',
                'set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")',
            ),
            (
                'set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${BUILD_BUNDLE_DIR}")',
                'set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION ".")',
            ),
        )
        for original, mutated in mutations:
            with self.subTest(original=original):
                self.assertIn(original, cmake, f"missing Windows install setting: {original}")
                result = self._run(self._workflow(), cmake=cmake.replace(original, mutated, 1))

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "Windows must keep CMAKE_INSTALL_PREFIX concrete and route app bundle files",
                    result.stderr,
                )

    def test_windows_release_build_requires_native_jdk_for_jni(self) -> None:
        prefix, windows = self._workflow().split("  build-windows:\n", 1)
        java_step = (
            '      - name: Setup Java\n'
            '        uses: actions/setup-java@77dd5b2ce225ea11469928ac317850245a74ae78 # v6.2.0\n'
            '        with:\n'
            '          distribution: "temurin"\n'
            '          java-version: "21"\n'
            "          architecture: ${{ matrix.arch == 'arm64' && 'aarch64' || 'x64' }}\n"
        )
        self.assertIn(java_step, windows)
        workflow = prefix + "  build-windows:\n" + windows.replace(java_step, "", 1)

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Windows release builds must provision pinned native JDK 21 for JNI",
            result.stderr,
        )

    def test_sdk_manifest_loader_cannot_be_removed(self) -> None:
        workflow = self._workflow().replace(
            'run: python3 scripts/flutter/load_sdk_pin.py --github-env',
            'run: echo skipped', 1)
        result = self._run(workflow)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('single immutable SDK manifest', result.stderr)

    def test_windows_arm_flutter_without_release_tag_is_rejected(self) -> None:
        action = self._action().replace(
            'git -C $root fetch --depth 1 origin "refs/tags/${version}:refs/tags/${version}"',
            "git -C $root fetch --depth 1 origin 6655482ec06e547f90abf8ae7590466f4415978d",
            1,
        )
        self.assertNotEqual(action, self._action(), "fixture mutation no longer matches the action")

        result = self._run(self._workflow(), action)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refs/tags/${version}", result.stderr)

    def test_mutable_download_in_signing_step_is_rejected(self) -> None:
        workflow = self._mutate_signer(
            "          try {\n",
            "          Invoke-WebRequest -Uri https://raw.githubusercontent.com/example/main/sign.dart -OutFile sign.dart\n"
            "          try {\n",
        )

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mutable or ad-hoc input: raw.githubusercontent.com", result.stderr)
        self.assertIn("mutable or ad-hoc input: invoke-webrequest", result.stderr)

    def test_inline_dependency_resolution_in_signing_step_is_rejected(self) -> None:
        workflow = self._mutate_signer(
            "          try {\n",
            "          Set-Content -Path pubspec.yaml -Value 'dependencies: {}'\n"
            "          dart pub get\n"
            "          try {\n",
        )

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mutable or ad-hoc input: pubspec.yaml", result.stderr)
        self.assertIn("mutable or ad-hoc input: dart pub get", result.stderr)

    def test_downloaded_signer_execution_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            "dart run auto_updater:sign_update pleazyng-windows-installer.exe $keyPath",
            "dart run sign.dart pleazyng-windows-installer.exe $keyPath",
            1,
        )

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must execute the locked auto_updater package", result.stderr)

    def test_unlocked_install_is_rejected(self) -> None:
        prefix, package_and_after = self._workflow().split("  package-windows:\n", 1)
        workflow = prefix + "  package-windows:\n" + package_and_after.replace(
            "flutter pub get --enforce-lockfile --no-example",
            "flutter pub get",
            1,
        )

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("enforced root dependency lock", result.stderr)

    def test_missing_finally_cleanup_is_rejected(self) -> None:
        workflow = self._mutate_signer("          } finally {\n", "          }\n")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cleanup must run from a finally block", result.stderr)

    def test_libmpv_cache_without_lock_identity_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            "hashFiles('mpv-build.lock.json', 'scripts/fetch_linux_libmpv.py')",
            "hashFiles('linux/packaging/native-inputs.json')",
            1,
        )

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mpv-build lock", result.stderr)

    def test_windows_mpv_download_must_allow_the_locked_fork(self) -> None:
        downloader = WINDOWS_MPV_DOWNLOADER.read_text(encoding="utf-8").replace(
            "snapetech-org/mpv-build",
            "edde746/mpv-build",
            1,
        )
        self.assertNotEqual(downloader, WINDOWS_MPV_DOWNLOADER.read_text(encoding="utf-8"))

        result = self._run(self._workflow(), mpv_downloader=downloader)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Windows MPV downloader must validate the locked snapetech-org/mpv-build artifact base",
            result.stderr,
        )

    def test_windows_mpv_download_must_reject_nonstandard_https_ports(self) -> None:
        downloader = WINDOWS_MPV_DOWNLOADER.read_text(encoding="utf-8").replace(
            "    $base.Port -ne 443 -or\n",
            "",
            1,
        )
        self.assertNotEqual(downloader, WINDOWS_MPV_DOWNLOADER.read_text(encoding="utf-8"))

        result = self._run(self._workflow(), mpv_downloader=downloader)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Windows MPV downloader must validate the locked snapetech-org/mpv-build artifact base",
            result.stderr,
        )

    def test_windows_native_cache_without_lock_identity_is_rejected(self) -> None:
        cache_identity = (
            "hashFiles('windows/CMakeLists.txt', 'mpv-build.lock.json', "
            "'windows/tool/build-toolchain.lock.json')"
        )
        workflow = self._workflow().replace(
            cache_identity,
            "hashFiles('windows/CMakeLists.txt')",
            1,
        )

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Windows native cache identity", result.stderr)

    def test_windows_cmake_with_literal_checksum_is_rejected(self) -> None:
        cmake = self._cmake().replace(
            'string(JSON MPV_SHA256 GET "${MPV_LOCK}" artifacts windows assets "${MPV_ARCH}" checksum)',
            'set(MPV_SHA256 "94c0e4d27794fb3bb754b0c62409c6b0cf17161fbafa16c3213d0239821a6836")',
            1,
        )
        self.assertNotEqual(cmake, self._cmake())

        result = self._run(self._workflow(), cmake=cmake)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a literal", result.stderr)

    def test_linux_fetch_without_shared_script_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            "python3 scripts/fetch_linux_libmpv.py --dest libmpv-prefix",
            "tar --zstd -xf libmpv.tar.zst -C libmpv-prefix",
            1,
        )

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fetch_linux_libmpv.py", result.stderr)

    def test_linux_bundle_without_the_pinned_vulkan_loader_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            '          cp -a libmpv-prefix/lib/libvulkan.so* "$BUNDLE_LIB/"\n',
            '',
            1,
        )
        self.assertNotEqual(workflow, self._workflow())
        result = self._run(workflow)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned Vulkan loader", result.stderr)

    def test_draft_release_with_tag_mismatched_to_pubspec_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            'if [[ "$ACTION" == "release" && "$RELEASE_TAG" != "v$PACKAGE_VERSION" ]]; then',
            'if false; then',
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release mode must validate the requested version", result.stderr)

    def test_release_tag_must_be_an_ancestor_with_only_allowlisted_changes(self) -> None:
        workflow = self._workflow().replace(
            'if ! git merge-base --is-ancestor "$release_commit" "$GITHUB_SHA"; then',
            "if false; then",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release tags must be immutable ancestors of trusted main", result.stderr)

    def test_release_tag_changed_path_allowlist_is_required(self) -> None:
        workflow = self._workflow().replace(
            "tools/webos/compatibility.json|",
            "",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release tags must be immutable ancestors of trusted main", result.stderr)

    def test_release_run_without_tagged_name_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            next(line for line in self._workflow().splitlines(keepends=True) if line.startswith("run-name:")),
            "",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "build and release run names must uniquely identify tvOS runner recovery attempts",
            result.stderr,
        )

    def test_automatic_release_triggers_are_rejected(self) -> None:
        workflow = self._workflow().replace(
            "on:\n  workflow_dispatch:\n",
            "on:\n  push:\n    tags: ['v*']\n  workflow_dispatch:\n",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be manually dispatched", result.stderr)

    def test_build_only_mode_cannot_create_a_draft_release(self) -> None:
        workflow = self._workflow().replace("needs.validate-trusted-ref.outputs.action == 'release' && ", "", 1)
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches release guard")
        result = self._run(workflow)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("draft release creation must require a successful complete build", result.stderr)

    def test_webos_candidate_build_is_independent_of_public_release_opt_in(self) -> None:
        workflow = self._workflow()
        start = workflow.index("  build-webos:\n")
        end = workflow.index("  build-tizen:\n", start)
        webos_job = workflow[start:end].replace(
            "outputs.include_webos_build == 'true'",
            "outputs.include_webos_release == 'true'",
            1,
        )
        workflow = workflow[:start] + webos_job + workflow[end:]

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("versioned builds must build webOS independently", result.stderr)

    def test_webos_release_cannot_skip_package_source_verification(self) -> None:
        workflow = self._workflow().replace(
            'python3 tools/webos/check_release_package.py',
            'echo missing package verification', 1,
        )
        self.assertNotEqual(workflow, self._workflow())
        result = self._run(workflow)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('verify the built webOS package', result.stderr)

    def test_tizen_cannot_assume_host_rustup_or_skip_early_validation(self):
        path = ROOT / '.github/workflows/tizen.yml'
        original = Path.read_text
        workflow = original(path)
        for before, after in [
            ('if ! command -v rustup >/dev/null; then packages+=(rustup); fi', 'true'),
            ('          rustup --version', '          true'),
            ('      - name: Install Tizen host build prerequisites\n',
             '      - name: Install Tizen host build prerequisites\n        if: false\n'),
        ]:
            with self.subTest(before=before):
                invalid = workflow.replace(before, after, 1)
                self.assertNotEqual(invalid, workflow)
                def read(candidate, *args, **kwargs):
                    return invalid if candidate == path else original(candidate, *args, **kwargs)
                errors = io.StringIO()
                with patch.object(Path, 'read_text', read), patch.object(sys, 'argv', [str(CHECKER)]), \
                        redirect_stderr(errors), self.assertRaises(SystemExit) as result:
                    runpy.run_path(str(CHECKER), run_name='__main__')
                self.assertEqual(result.exception.code, 1)
                self.assertIn('provision and verify rustup', errors.getvalue())

    def test_versioned_tizen_build_stays_arm_and_store_gated(self) -> None:
        workflow = self._workflow().replace(
            "      architecture: arm\n", "      architecture: x64\n", 1
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches Tizen call")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ARM Tizen tester workflow without store handoff", result.stderr)

    def test_webos_private_retention_requires_mounted_storage_preflight(self) -> None:
        workflow = self._workflow().replace(
            "python3 tools/webos/retain_private_candidate.py --preflight",
            "echo missing private output check",
            1,
        )
        self.assertNotEqual(workflow, self._workflow())
        result = self._run(workflow)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("webOS candidates must survive guest cleanup", result.stderr)

    def test_release_must_attach_the_verified_tizen_tester_handoff(self) -> None:
        workflow = self._workflow().replace(
            "            echo artifacts/tizen/pleazyng-tizen-arm-tester-handoff.zip\n",
            "",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches Tizen release asset")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verified ARM Tizen tester handoff must be attached", result.stderr)

    def test_release_creation_cannot_request_historical_workflow_target(self) -> None:
        workflow = self._workflow().replace(
            "          target_commitish: main\n",
            "          target_commitish: ${{ needs.validate-trusted-ref.outputs.release_commit }}\n",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("default branch permission target", result.stderr)

    def test_release_tag_preflight_binds_annotated_and_lightweight_tags(self) -> None:
        workflow = yaml.safe_load(self._workflow())
        body = next(s['run'] for s in workflow['jobs']['create-release']['steps']
                    if s.get('name') == 'Verify existing immutable release tag')
        script = body.split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        expected = 'a' * 40
        cases = [
            ([{'object': {'type': 'commit', 'sha': expected}}], True),
            ([{'object': {'type': 'tag', 'sha': 'b' * 40}},
              {'object': {'type': 'commit', 'sha': expected}}], True),
            ([{'object': {'type': 'commit', 'sha': 'c' * 40}}], False),
        ]
        for responses, succeeds in cases:
            with self.subTest(responses=responses), patch.dict(os.environ, {
                    'GITHUB_REPOSITORY': 'snapetech-org/pleazyng', 'RELEASE_TAG': 'v3.0.3',
                    'EXPECTED_RELEASE_COMMIT': expected}), patch.object(
                        subprocess, 'check_output', side_effect=[json.dumps(r) for r in responses]) as api:
                if succeeds:
                    with patch('builtins.print'):
                        exec(compile(script, 'release-tag-preflight', 'exec'), {})
                else:
                    with self.assertRaisesRegex(ValueError, 'Immutable release tag changed'):
                        exec(compile(script, 'release-tag-preflight', 'exec'), {})
                self.assertEqual(api.call_args_list[0].args[0][-1],
                                 'repos/snapetech-org/pleazyng/git/ref/tags/v3.0.3')
                self.assertEqual(api.call_count, len(responses))

    def test_release_tag_preflight_must_compare_the_validated_source(self) -> None:
        workflow = self._workflow().replace("if obj['sha'] != expected:", "if False:", 1)
        self.assertNotEqual(workflow, self._workflow())
        result = self._run(workflow)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must remain bound to the validated immutable tag commit', result.stderr)



if __name__ == "__main__":
    unittest.main()
