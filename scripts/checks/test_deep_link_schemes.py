"""Keep installed URI registrations and native Apple routing in agreement."""
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("scheme_guard", Path(__file__).with_name("check_deep_link_schemes.py"))
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class AppleSchemeGuardTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="plezy-scheme-guard-")
        self.root = Path(self.temporary.name)
        for name in (
            "ios/Runner/Info.plist", "macos/Runner/Info.plist", "tvos/Runner/Info.plist",
            "android/app/src/main/AndroidManifest.xml",
            "android/app/src/main/kotlin/com/edde746/plezy/deeplink/DeepLinkPlugin.kt",
            "shared/apple/DeepLink/DeepLinkPlugin.swift", "windows/build-msix.ps1",
            "windows/build-installer.ps1", "windows/runner/main.cpp", "windows/runner/flutter_window.cpp",
        ):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        self.root_patch = patch.object(guard, "ROOT", self.root)
        self.root_patch.start()

    def tearDown(self):
        self.root_patch.stop()
        self.temporary.cleanup()

    def test_current_handlers_and_registrations_agree(self):
        with redirect_stdout(io.StringIO()):
            guard.check()

    def test_legacy_only_apple_handler_is_rejected(self):
        source = self.root / "shared/apple/DeepLink/DeepLinkPlugin.swift"
        text, count = re.subn(
            r'private static let schemes:\s*Set<String>\s*=\s*\[[^]]+\]',
            'private static let schemes: Set<String> = ["plezy", "plezxyng"]', source.read_text(),
        )
        self.assertEqual(count, 1)
        source.write_text(text)
        with self.assertRaisesRegex(SystemExit, r"DeepLinkPlugin.swift: native handler rejects registered pleazyng, plezyng"):
            guard.check()

    def test_legacy_acceptance_does_not_register_upstream_protocol(self):
        source = self.root / "tvos/Runner/Info.plist"
        info = plistlib.loads(source.read_bytes())
        info["CFBundleURLTypes"][0]["CFBundleURLSchemes"].append("plezy")
        source.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(SystemExit, "upstream plezy protocol must not be registered"):
            guard.check()


if __name__ == "__main__":
    unittest.main()
