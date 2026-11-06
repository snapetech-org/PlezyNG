#!/usr/bin/env python3
"""Exercise tvOS bundle metadata against real plists and Mach-O load commands."""
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tvos/scripts/xcode_appletv.sh"


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "Requires the real Apple SDK tools")
class FrameworkMetadataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiled = tempfile.TemporaryDirectory(prefix="plezy-tvos-metadata-binaries-")
        cls.binaries = Path(cls.compiled.name)
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "appletvsimulator", "--show-sdk-path"], text=True,
        ).strip()
        source = cls.binaries / "probe.c"
        source.write_text("int metadata_probe(void) { return 1; }\n")
        for architecture, minimum in (("arm64", "16.0"), ("arm64", "18.0"),
                                      ("arm64", "26.0"), ("x86_64", "16.0")):
            subprocess.run([
                "xcrun", "clang", "-target", f"{architecture}-apple-tvos{minimum}-simulator",
                "-isysroot", sdk, "-dynamiclib", str(source),
                "-o", str(cls.binaries / f"{architecture}-{minimum}"),
            ], check=True, capture_output=True)
        subprocess.run([
            "xcrun", "lipo", "-create", str(cls.binaries / "x86_64-16.0"),
            str(cls.binaries / "arm64-26.0"), "-output", str(cls.binaries / "universal"),
        ], check=True, capture_output=True)
        ios_sdk = subprocess.check_output(
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True,
        ).strip()
        subprocess.run([
            "xcrun", "clang", "-target", "arm64-apple-ios16.0-simulator",
            "-isysroot", ios_sdk, "-dynamiclib", str(source), "-o", str(cls.binaries / "ios"),
        ], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.compiled.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="plezy-tvos-metadata-")
        self.root = Path(self.temporary.name)
        # Source the production functions without invoking the script's build entry point.
        self.functions = self.root / "functions.sh"
        self.functions.write_text(SCRIPT.read_text().split("# Main entry point.", 1)[0])

    def tearDown(self):
        self.temporary.cleanup()

    def framework(self, parent, name, declared, binary="arm64-16.0", readonly=False):
        framework = parent / f"{name}.framework"
        framework.mkdir(parents=True)
        shutil.copy2(self.binaries / binary, framework / name)
        values = {"CFBundleExecutable": name, "CFBundleIdentifier": "test." + name}
        if declared is not None:
            values["MinimumOSVersion"] = declared
        plist = framework / "Info.plist"
        plist.write_bytes(plistlib.dumps(values))
        if readonly:
            plist.chmod(0o444)
        return framework

    def normalize(self, framework, minimum="16.0"):
        subprocess.run([
            "bash", "-c", 'source "$1"; NormalizeFrameworkMinimumOSVersion "$2" "$3"',
            "metadata-test", str(self.functions), str(framework), minimum,
        ], check=True, capture_output=True, text=True,
            env=os.environ | {"PLATFORM_NAME": "appletvsimulator"})

    def minimum(self, framework):
        return plistlib.loads((framework / "Info.plist").read_bytes())["MinimumOSVersion"]

    def test_readonly_stale_metadata_is_derived_from_binary(self):
        framework = self.framework(self.root, "AetherLibavcodec", "26.0", readonly=True)
        binary = (framework / "AetherLibavcodec").read_bytes()
        self.normalize(framework)
        self.assertEqual(self.minimum(framework), "16.0")
        self.assertEqual((framework / "AetherLibavcodec").read_bytes(), binary)
        self.assertFalse(stat.S_IMODE((framework / "Info.plist").stat().st_mode) & 0o022)

    def test_readonly_plist_is_raised_to_real_binary_floor(self):
        framework = self.framework(self.root, "OptionalRuntime", "16.0", "arm64-26.0", readonly=True)
        binary = (framework / "OptionalRuntime").read_bytes()
        self.normalize(framework)
        self.assertEqual(self.minimum(framework), "26.0")
        self.assertEqual((framework / "OptionalRuntime").read_bytes(), binary)

    def test_every_architecture_contributes_to_minimum(self):
        framework = self.framework(self.root, "Universal", "16.0", "universal")
        self.normalize(framework)
        self.assertEqual(self.minimum(framework), "26.0")

    def test_missing_metadata_uses_binary_floor(self):
        framework = self.framework(self.root, "OptionalRuntime", None, "arm64-18.0")
        self.normalize(framework)
        self.assertEqual(self.minimum(framework), "18.0")

    def test_higher_app_floor_is_respected(self):
        framework = self.framework(self.root, "Shared", "16.0", readonly=True)
        self.normalize(framework, "18.0")
        self.assertEqual(self.minimum(framework), "18.0")

    def test_wrong_platform_is_rejected_before_metadata_changes(self):
        framework = self.framework(self.root, "WrongPlatform", "26.0", "ios", readonly=True)
        before = (framework / "Info.plist").read_bytes()
        with self.assertRaises(subprocess.CalledProcessError):
            self.normalize(framework)
        self.assertEqual((framework / "Info.plist").read_bytes(), before)
        self.assertEqual(stat.S_IMODE((framework / "Info.plist").stat().st_mode), 0o444)

    def test_unreadable_slice_is_rejected_before_metadata_changes(self):
        framework = self.framework(self.root, "Truncated", "26.0", "universal", readonly=True)
        binary = framework / "Truncated"
        data = binary.read_bytes()
        self.assertEqual(struct.unpack_from(">I", data)[0], 0xCAFEBABE)
        # Preserve the first slice but truncate the second slice's load commands.
        second_offset = struct.unpack_from(">I", data, 8 + 20 + 8)[0]
        binary.write_bytes(data[:second_offset + 16])
        before = (framework / "Info.plist").read_bytes()
        with self.assertRaises(subprocess.CalledProcessError):
            self.normalize(framework)
        self.assertEqual((framework / "Info.plist").read_bytes(), before)

    def test_source_cache_symlinks_are_materialized_before_editing(self):
        products = self.root / "products"
        products.mkdir()
        cache = self.root / "cache"
        sources = {}
        for name in ("App", "Flutter"):
            sources[name] = self.framework(cache, name, "26.0", readonly=True)
            (products / f"{name}.framework").symlink_to(sources[name], target_is_directory=True)
        optional = self.framework(cache, "OptionalRuntime", "26.0", "arm64-18.0", readonly=True)
        sources["OptionalRuntime"] = optional
        embedded = products / "Runner.app/Frameworks"
        embedded.mkdir(parents=True)
        (embedded / "OptionalRuntime.framework").symlink_to(optional, target_is_directory=True)
        original = {name: (path / "Info.plist").read_bytes() for name, path in sources.items()}
        subprocess.run([
            "bash", "-c", 'source "$1"; EmbedFlutterFrameworks', "cache-test", str(self.functions),
        ], env=os.environ | {
            "TARGET_NAME": "Runner", "TARGET_BUILD_DIR": str(products),
            "BUILT_PRODUCTS_DIR": str(products), "WRAPPER_NAME": "Runner.app",
            "TVOS_DEPLOYMENT_TARGET": "16.0", "PLATFORM_NAME": "appletvsimulator",
            "CODE_SIGNING_ALLOWED": "NO",
        }, check=True, capture_output=True, text=True)
        for name, path in sources.items():
            self.assertEqual((path / "Info.plist").read_bytes(), original[name])
            self.assertEqual(stat.S_IMODE((path / "Info.plist").stat().st_mode), 0o444)
            copied = embedded / f"{name}.framework"
            self.assertFalse(copied.is_symlink())
            self.assertEqual(self.minimum(copied), "18.0" if name == "OptionalRuntime" else "16.0")
        self.assertEqual(list(embedded.glob(".framework-copy.*")), [])

    def test_sync_version_preserves_optional_runtime_floors(self):
        products = self.root / "products"
        app = products / "Runner.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "0",
            "MinimumOSVersion": "16.0",
        }))
        (self.root / "pubspec.yaml").write_text("version: 3.0.1+160\n")
        for name in ("App", "Flutter"):
            self.framework(products, name, "16.0")
        vendor = self.framework(app / "Frameworks", "AetherLibavcodec", "26.0", readonly=True)
        optional = self.framework(app / "Frameworks", "PlezyNGDVRuntime", "18.0", "arm64-18.0")
        environment = os.environ | {
            "FLUTTER_APPLICATION_PATH": str(self.root), "TARGET_NAME": "Runner",
            "TARGET_BUILD_DIR": str(products), "BUILT_PRODUCTS_DIR": str(products),
            "WRAPPER_NAME": "Runner.app", "INFOPLIST_PATH": "Runner.app/Info.plist",
            "TVOS_DEPLOYMENT_TARGET": "16.0", "PLATFORM_NAME": "appletvsimulator",
            "CODE_SIGNING_ALLOWED": "NO",
        }
        subprocess.run(["bash", str(SCRIPT), "sync_version"], env=environment,
                       check=True, capture_output=True, text=True)
        self.assertEqual(self.minimum(vendor), "16.0")
        self.assertEqual(self.minimum(optional), "18.0")
        self.assertEqual(self.minimum(app / "Frameworks/App.framework"), "16.0")
        runner = plistlib.loads((app / "Info.plist").read_bytes())
        self.assertEqual((runner["CFBundleShortVersionString"], runner["CFBundleVersion"]), ("3.0.1", "160"))


if __name__ == "__main__":
    unittest.main()
