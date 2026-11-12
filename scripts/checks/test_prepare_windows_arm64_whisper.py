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
            + whisper.WHISPER_MSVC_WARNING_BLOCK
            + '\nafter\n'
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
        self.assertIn(
            "set_target_properties(whisper PROPERTIES\n"
            "    INTERFACE_LINK_LIBRARIES ggml)",
            patched,
        )
        self.assertIn(
            'set_target_properties(ggml PROPERTIES\n'
            '    INTERFACE_LINK_LIBRARIES "ggml-base;ggml-cpu")',
            patched,
        )
        self.assertIn(
            "get_target_property(_FW_TARGET_IS_IMPORTED ${_FW_THIRD_PARTY_TARGET} IMPORTED)",
            patched,
        )
        self.assertIn(
            "if(NOT _FW_TARGET_IS_IMPORTED)\n"
            "        target_compile_options(${_FW_THIRD_PARTY_TARGET} PRIVATE",
            patched,
        )
        self.assertNotIn(whisper.WHISPER_MSVC_WARNING_BLOCK + "\n", patched)

    def test_patch_rejects_missing_msvc_warning_block(self):
        source = (
            'add_subdirectory(\n'
            '  "${FLUTTER_WHISPER_CPP_DIR}"\n'
            '  "${CMAKE_CURRENT_BINARY_DIR}/whisper_cpp"\n'
            '  EXCLUDE_FROM_ALL)\n'
        )
        expected = hashlib.sha256(source.encode()).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            cmake_file = Path(temporary) / "CMakeLists.txt"
            cmake_file.write_text(source)
            with self.assertRaisesRegex(ValueError, "expected MSVC warning-options block"):
                whisper.patch_plugin_cmake(
                    cmake_file,
                    Path(temporary) / "whisper-libraries",
                    expected_sha256=expected,
                )

    def test_patch_accepts_its_exact_cached_output_on_a_repeat_build(self):
        source = (
            'before\n'
            'add_subdirectory(\n'
            '  "${FLUTTER_WHISPER_CPP_DIR}"\n'
            '  "${CMAKE_CURRENT_BINARY_DIR}/whisper_cpp"\n'
            '  EXCLUDE_FROM_ALL)\n'
            + whisper.WHISPER_MSVC_WARNING_BLOCK
            + '\nafter\n'
        )
        expected = hashlib.sha256(source.encode()).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            cmake_file = Path(temporary) / "CMakeLists.txt"
            cmake_file.write_text(source)
            whisper.patch_plugin_cmake(cmake_file, Path(temporary) / "whisper-libraries", expected_sha256=expected)
            patched_sha256 = hashlib.sha256(cmake_file.read_bytes()).hexdigest()

            whisper.patch_plugin_cmake(
                cmake_file,
                Path(temporary) / "whisper-libraries",
                expected_sha256=expected,
                expected_patched_sha256=patched_sha256,
            )

            self.assertEqual(hashlib.sha256(cmake_file.read_bytes()).hexdigest(), patched_sha256)

    def test_patch_rejects_an_unrecognized_dependency(self):
        with tempfile.TemporaryDirectory() as temporary:
            cmake_file = Path(temporary) / "CMakeLists.txt"
            cmake_file.write_text("unexpected dependency source")
            with self.assertRaisesRegex(ValueError, "Refusing to patch an unrecognized"):
                whisper.patch_plugin_cmake(cmake_file, Path(temporary) / "whisper-libraries")


if __name__ == "__main__":
    unittest.main()
