"""Behavior tests for installing the locked Sherpa ONNX Linux libraries."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "linux/packaging/install-sherpa-onnx-runtime.py"
SPEC = importlib.util.spec_from_file_location("install_sherpa_onnx_runtime", SCRIPT)
assert SPEC and SPEC.loader
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class InstallSherpaOnnxRuntimeTest(unittest.TestCase):
    def test_resolves_absolute_file_uri(self) -> None:
        with tempfile.TemporaryDirectory(prefix="plezy-sherpa-config-") as directory:
            root = Path(directory) / "sherpa package"
            root.mkdir()
            config = Path(directory) / "package_config.json"
            config.write_text(
                json.dumps(
                    {
                        "packages": [
                            {
                                "name": "sherpa_onnx_linux",
                                "rootUri": root.as_uri(),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                INSTALLER.resolve_package_root(config, "sherpa_onnx_linux"),
                root.resolve(),
            )

    def test_resolves_relative_uri(self) -> None:
        with tempfile.TemporaryDirectory(prefix="plezy-sherpa-config-") as directory:
            config_dir = Path(directory) / ".dart_tool"
            config_dir.mkdir()
            root = Path(directory) / "package"
            root.mkdir()
            config = config_dir / "package_config.json"
            config.write_text(
                json.dumps(
                    {
                        "packages": [
                            {"name": "sherpa_onnx_linux", "rootUri": "../package"}
                        ]
                    }
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                INSTALLER.resolve_package_root(config, "sherpa_onnx_linux"),
                root.resolve(),
            )

    def test_installs_architecture_matched_library_pair(self) -> None:
        with tempfile.TemporaryDirectory(prefix="plezy-sherpa-copy-") as directory:
            root = Path(directory)
            package = root / "package"
            source = package / "linux/aarch64"
            source.mkdir(parents=True)
            bundle_lib = root / "bundle/lib"
            bundle_lib.mkdir(parents=True)
            config = root / "package_config.json"
            config.write_text(
                json.dumps(
                    {
                        "packages": [
                            {
                                "name": "sherpa_onnx_linux",
                                "rootUri": package.as_uri(),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            for name in INSTALLER.LIBRARIES:
                (source / name).write_bytes(("locked:" + name).encode())
                (bundle_lib / name).write_bytes(b"stale bundle copy")

            result = type(
                "Result",
                (),
                {
                    "returncode": 0,
                    "stdout": (
                        "libonnxruntime.so => "
                        f"{bundle_lib / 'libonnxruntime.so'} (0x0)\n"
                    ),
                    "stderr": "",
                },
            )()
            with patch.object(INSTALLER.subprocess, "run", return_value=result):
                INSTALLER.install_runtime_pair(config, root / "bundle", "arm64")

            for name in INSTALLER.LIBRARIES:
                self.assertEqual(
                    (bundle_lib / name).read_bytes(),
                    (source / name).read_bytes(),
                )

    def test_fails_when_locked_package_is_missing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="plezy-sherpa-missing-") as directory:
            config = Path(directory) / "package_config.json"
            config.write_text('{"packages": []}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing from"):
                INSTALLER.resolve_package_root(config, "sherpa_onnx_linux")


if __name__ == "__main__":
    unittest.main()
