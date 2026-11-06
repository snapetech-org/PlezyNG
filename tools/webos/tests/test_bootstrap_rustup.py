import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "bootstrap_rustup.py"
SPEC = importlib.util.spec_from_file_location("bootstrap_rustup", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RustBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="webos-rust-bootstrap-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.payload = b"verified installer fixture"
        self.lock = self.root / "lock.json"
        self.lock.write_text(json.dumps({"rustupBootstrap": {
            "version": "1.29.2", "host": "x86_64-unknown-linux-gnu",
            "sha256": hashlib.sha256(self.payload).hexdigest(),
        }}))

    def fake_download(self, url, destination):
        self.assertEqual(url, "https://static.rust-lang.org/rustup/archive/1.29.2/x86_64-unknown-linux-gnu/rustup-init")
        destination.write_bytes(self.payload)

    @patch.object(MODULE.platform, "machine", return_value="x86_64")
    @patch.object(MODULE.platform, "system", return_value="Linux")
    def test_bootstrap_ignores_missing_image_rustup_and_isolates_homes(self, *_):
        result = subprocess.CompletedProcess([], 0, "rustup 1.29.2 (fixture)\n", "")
        with patch.object(MODULE, "download", side_effect=self.fake_download), patch.object(
            MODULE.subprocess, "run", return_value=result
        ) as run, patch.dict(MODULE.os.environ, {"PATH": "/missing"}):
            binary = MODULE.bootstrap(self.root, self.lock)
        install_args, install_kwargs = run.call_args_list[0]
        self.assertEqual(install_args[0][1:], ["-y", "--no-modify-path", "--profile", "minimal", "--default-toolchain", "none"])
        self.assertEqual(install_kwargs["env"]["RUSTUP_HOME"], str(self.root / "rustup-home"))
        self.assertEqual(install_kwargs["env"]["CARGO_HOME"], str(self.root / "cargo-home"))
        self.assertEqual(binary, self.root / "cargo-home/bin/rustup")
        self.assertEqual(run.call_args_list[1].args[0], [str(binary), "--version"])
        for name in ("rustup-bootstrap", "rustup-home", "cargo-home"):
            self.assertEqual((self.root / name).stat().st_mode & 0o777, 0o700)

    def test_corrupt_installer_is_never_executed(self):
        with patch.object(MODULE, "download", side_effect=lambda _, path: path.write_bytes(b"corrupt")), patch.object(MODULE.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "SHA-256 differs"):
                MODULE.bootstrap(self.root, self.lock)
        run.assert_not_called()

    def test_existing_home_or_symlink_is_rejected_before_execution(self):
        (self.root / "rustup-home").symlink_to(self.root / "missing")
        with patch.object(MODULE, "download") as download, patch.object(MODULE.subprocess, "run") as run:
            with self.assertRaises(FileExistsError):
                MODULE.bootstrap(self.root, self.lock)
        download.assert_not_called()
        run.assert_not_called()

    def test_builder_uses_isolated_binary_without_manager_self_update(self):
        builder = SCRIPT.with_name("build_milkrust_runtime.sh").read_text()
        self.assertIn('"$RUSTUP_BIN" toolchain install "$RUST_TOOLCHAIN" --profile minimal --target "$RUST_TARGET" --no-self-update', builder)
        self.assertNotIn("command -v rustup", builder)
        lock = json.loads(SCRIPT.with_name("compatibility.json").read_text())
        self.assertEqual(lock["milkrustBuild"]["toolchain"], "1.97.0")


if __name__ == "__main__":
    unittest.main()
