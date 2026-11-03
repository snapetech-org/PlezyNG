"""Test the pinned Whisper plugin CMake rewrite used by Windows ARM64 builds."""

import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import prepare_windows_arm64_whisper as whisper


class WindowsArm64WhisperTest(unittest.TestCase):
    def test_patch_imports_clang_built_libraries_for_the_msvc_plugin(self):
        source = (
            'before\n'
            'add_subdirectory(\n'
            '  "${FLUTTER_WHISPER_CPP_DIR}"\n'
            '  "${CMAKE_CURRENT_BINARY_DIR}/whisper_cpp"\n'
            '  EXCLUDE_FROM_ALL)\n'
            'after\n'
        )
        expected = hashlib.sha256(source.encode()).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            cmake_file = Path(temporary) / "CMakeLists.txt"
            cmake_file.write_text(source)
            whisper.patch_plugin_cmake(cmake_file, Path(temporary) / "whisper-libraries", expected_sha256=expected)
            patched = cmake_file.read_text()

        self.assertIn('FLUTTER_WHISPER_PREBUILT_ROOT "$ENV{FLUTTER_WHISPER_PREBUILT_ROOT}"', patched)
        self.assertIn("add_library(${_target} SHARED IMPORTED GLOBAL)", patched)
        self.assertIn("IMPORTED_IMPLIB_RELEASE", patched)
        self.assertIn("add_subdirectory(", patched)
        self.assertIn('"${FLUTTER_WHISPER_CPP_DIR}"', patched)
        self.assertIn("foreach(_target IN ITEMS whisper ggml ggml-base ggml-cpu)", patched)

    def test_patch_rejects_an_unrecognized_dependency(self):
        with tempfile.TemporaryDirectory() as temporary:
            cmake_file = Path(temporary) / "CMakeLists.txt"
            cmake_file.write_text("unexpected dependency source")
            with self.assertRaisesRegex(ValueError, "Refusing to patch an unrecognized"):
                whisper.patch_plugin_cmake(cmake_file, Path(temporary) / "whisper-libraries")


if __name__ == "__main__":
    unittest.main()
