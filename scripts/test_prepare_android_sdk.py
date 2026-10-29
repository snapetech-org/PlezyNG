import importlib.util
import hashlib
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SPEC = importlib.util.spec_from_file_location("prepare_android_sdk", Path(__file__).with_name("prepare_android_sdk.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AndroidSdkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="plezy-android-sdk-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "android/steam").mkdir(parents=True)
        (self.root / "android/.gradle").mkdir()
        (self.root / "android/build.gradle.kts").write_text(
            'compileSdk = 37\nbuildToolsVersion = "37.0.0"\nndkVersion = "29.0.14206865"\n'
            'cmake { version = "4.1.2" }\n'
        )
        (self.root / "android/steam/build.gradle").write_text(
            "compileSdk 36\nexternalNativeBuild { cmake { version '3.22.1' } }\n"
        )
        self.env = {"HTTPS_PROXY": "http://10.0.2.100:3128"}

    def test_each_modules_tools_are_collected_including_older_cmake(self):
        packages = MODULE.required_packages(self.root)
        self.assertEqual(packages, ["build-tools;37.0.0", "cmake;3.22.1", "cmake;4.1.2",
                                    "ndk;29.0.14206865", "platform-tools",
                                    "platforms;android-36", "platforms;android-37.0"])
        (self.root / "android/steam/build.gradle").write_text("cmake { version '4.2.0' }\n")
        updated = MODULE.required_packages(self.root)
        self.assertIn("cmake;4.2.0", updated)
        self.assertNotIn("cmake;3.22.1", updated)

    def test_real_source_includes_steam_and_libass_toolchains(self):
        packages = MODULE.required_packages(MODULE.ROOT)
        for expected in ("cmake;3.22.1", "cmake;4.1.2", "platforms;android-34",
                         "platforms;android-35", "platforms;android-36", "platforms;android-37.0"):
            self.assertIn(expected, packages)

    def test_vendored_plugins_are_included_without_scanning_generated_builds(self):
        plugin = self.root / "packages/gamepad/android"
        plugin.mkdir(parents=True)
        (plugin / "build.gradle").write_text("compileSdk = 34\n")
        (plugin / "build").mkdir()
        (plugin / "build/generated.gradle").write_text("compileSdk = 999\n")
        packages = MODULE.required_packages(self.root)
        self.assertIn("platforms;android-34", packages)
        self.assertNotIn("platforms;android-999.0", packages)

    def archive(self, extras=None):
        archive = self.root / "tools.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("cmdline-tools/source.properties", "Pkg.Revision=22.0\n")
            manager = zipfile.ZipInfo("cmdline-tools/bin/sdkmanager")
            manager.external_attr = (stat.S_IFREG | 0o755) << 16
            output.writestr(manager, "#!/bin/sh\nexit 0\n")
            for key, value in (extras or {}).items():
                output.writestr(key, value)
        lock = self.root / "tools.lock.json"
        lock.write_text(json.dumps({"schema": 1, "version": "22.0", "archives": {
            "linux-x86_64": {"file": "commandlinetools-linux-15859902_latest.zip",
                             "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}}}))
        return archive, lock

    def test_offline_bootstrap_verifies_archive_and_preserves_existing_tools(self):
        archive, lock = self.archive()
        sdk = self.root / "sdk"
        old = sdk / "cmdline-tools/latest"
        old.mkdir(parents=True)
        (old / "source.properties").write_text("Pkg.Revision=21.0\n")
        with patch.object(MODULE, "TOOLS_LOCK", lock), patch.object(MODULE, "host_key", return_value="linux-x86_64"):
            manager = MODULE.bootstrap(sdk, archive)
            self.assertEqual(manager.parent.parent.name, "22.0")
            self.assertTrue(manager.stat().st_mode & stat.S_IXUSR)
            self.assertEqual(MODULE.bootstrap(sdk, archive), manager)
        self.assertEqual(MODULE.tools_version(old), "21.0")

    def test_wrong_hash_never_extracts_or_executes(self):
        archive, lock = self.archive()
        archive.write_bytes(archive.read_bytes() + b"corrupt")
        sdk = self.root / "sdk"
        with patch.object(MODULE, "TOOLS_LOCK", lock), patch.object(MODULE, "host_key", return_value="linux-x86_64"):
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                MODULE.bootstrap(sdk, archive)
        self.assertFalse((sdk / "cmdline-tools/22.0").exists())

    def test_archive_traversal_and_links_are_rejected_before_extraction(self):
        link = zipfile.ZipInfo("cmdline-tools/link")
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for name in ("cmdline-tools/../../escape", "/cmdline-tools/escape", "cmdline-tools\\escape", link):
            with self.subTest(name=name):
                archive, _ = self.archive({name: "../../escape"})
                destination = self.root / "unpacked"
                with self.assertRaisesRegex(ValueError, "Unsafe"):
                    MODULE.extract_tools(archive, destination)
                self.assertFalse(destination.exists())

    def test_verification_uses_windows_and_apple_executable_names(self):
        for system, host in (("Windows", "windows-x86_64"), ("Darwin", "darwin-x86_64")):
            sdk = self.root / system
            extension = ".exe" if system == "Windows" else ""
            for relative in (f"platform-tools/adb{extension}", f"build-tools/36.1.0/aapt2{extension}",
                             "build-tools/36.1.0/apksigner" + (".bat" if system == "Windows" else ""),
                             f"cmake/3.22.1/bin/cmake{extension}", f"cmake/3.22.1/bin/ninja{extension}",
                             "ndk/29.0.14206865/ndk-build" + (".cmd" if system == "Windows" else ""),
                             f"ndk/29.0.14206865/toolchains/llvm/prebuilt/{host}/bin/clang{extension}"):
                path = sdk / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("tool")
                path.chmod(0o755)
            (sdk / "ndk/29.0.14206865/source.properties").write_text("Pkg.Revision = 29.0.14206865\n")
            with patch.object(MODULE.platform, "system", return_value=system):
                MODULE.verify_packages(sdk, ["platform-tools", "build-tools;36.1.0", "cmake;3.22.1", "ndk;29.0.14206865"])

    def test_legacy_nested_platform_repair_preserves_original_container(self):
        sdk = self.root / "sdk"
        platform = sdk / "platforms/android-34"
        nested = platform / "android-34"
        nested.mkdir(parents=True)
        (nested / "android.jar").write_bytes(b"SDK bytes")
        (nested / "source.properties").write_text("AndroidVersion.ApiLevel=34\n")
        (platform / "package.xml").write_text('<repository><localPackage path="platforms;android-34"/></repository>')
        (platform / "retained").write_text("old container")
        with MODULE.sdk_lock(sdk):
            MODULE.repair_nested_platform(sdk, "platforms;android-34")
        self.assertEqual((platform / "android.jar").read_bytes(), b"SDK bytes")
        self.assertTrue((platform / "package.xml").is_file())
        self.assertEqual(len(list((self.root / "sdk-platform-layout").glob("*/retained"))), 1)
        MODULE.verify_packages(sdk, ["platforms;android-34"])
        MODULE.repair_nested_platform(sdk, "platforms;android-34")

    def test_nested_platform_with_wrong_api_is_not_modified(self):
        sdk = self.root / "sdk"
        nested = sdk / "platforms/android-34/android-34"
        nested.mkdir(parents=True)
        (nested / "android.jar").write_bytes(b"SDK bytes")
        (nested / "source.properties").write_text("AndroidVersion.ApiLevel=36\n")
        with self.assertRaisesRegex(ValueError, "requested API"):
            MODULE.repair_nested_platform(sdk, "platforms;android-34")
        self.assertTrue((nested / "android.jar").is_file())

    def test_sdk_java_and_gradle_both_receive_proxy_before_downloads(self):
        output = self.root / "github-env"
        MODULE.configure_proxy(self.env | {"GITHUB_ENV": str(output), "JAVA_TOOL_OPTIONS": "-Xmx2g"})
        entries = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(set(entries), {"JAVA_TOOL_OPTIONS", "GRADLE_OPTS"})
        for value in entries.values():
            self.assertIn("-Dhttps.proxyHost=10.0.2.100", value)
            self.assertIn("-Dhttp.proxyPort=3128", value)
        self.assertTrue(entries["JAVA_TOOL_OPTIONS"].startswith("-Xmx2g "))

    def test_invalid_proxy_or_multiline_environment_is_rejected(self):
        for proxy in ("", "https://host:3128", "http://user:secret@host:3128",
                      "http://host:3128?query=secret", "http://host:3128\nINJECTED=true"):
            with self.subTest(proxy=proxy), self.assertRaises(ValueError):
                MODULE.proxy_parts({"HTTPS_PROXY": proxy})
        with self.assertRaises(ValueError):
            MODULE.configure_proxy(self.env | {"GITHUB_ENV": str(self.root / "env"),
                                               "GRADLE_OPTS": "-Xmx2g\nINJECTED=true"})
        self.assertFalse((self.root / "env").exists())

    def test_partial_sdk_install_does_not_pass(self):
        sdk = self.root / "sdk"
        for name in ("cmake", "ninja"):
            path = sdk / "cmake/4.1.2/bin" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        MODULE.verify_packages(sdk, ["cmake;4.1.2"])
        with self.assertRaisesRegex(ValueError, "cmake;3.22.1"):
            MODULE.verify_packages(sdk, ["cmake;4.1.2", "cmake;3.22.1"])

    def test_installer_passes_exact_packages_and_proxy_to_sdkmanager(self):
        sdk = self.root / "sdk"
        manager = sdk / "cmdline-tools/latest/bin/sdkmanager"
        manager.parent.mkdir(parents=True)
        manager.touch()
        with patch.object(MODULE.subprocess, "run") as run, patch.object(MODULE, "verify_packages") as verify:
            MODULE.install(self.root, self.env | {"ANDROID_HOME": str(sdk)})
        packages = MODULE.required_packages(self.root)
        self.assertEqual(run.call_count, 1 + len(packages))
        for call, package in zip(run.call_args_list[1:], packages):
            arguments = call.args[0]
            self.assertIn("--proxy_host=10.0.2.100", arguments)
            self.assertIn("--proxy_port=3128", arguments)
            self.assertEqual(arguments[arguments.index("--install") + 1:], [package])
        self.assertEqual([c.args for c in verify.call_args_list], [(sdk, [package]) for package in packages])

    def test_ci_release_and_games_use_shared_setup_in_order(self):
        for filename in ("ci.yml", "build.yml", "games-native.yml"):
            source = (MODULE.ROOT / ".github/workflows" / filename).read_text()
            with self.subTest(workflow=filename):
                proxy = source.index("python3 scripts/prepare_android_sdk.py proxy")
                setup = source.index("uses: android-actions/setup-android@", proxy)
                install = source.index("python3 scripts/prepare_android_sdk.py install", setup)
                self.assertLess(proxy, setup)
                self.assertLess(setup, install)


if __name__ == "__main__":
    unittest.main()
