import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("install.sh")


class EndpointInstallerTest(unittest.TestCase):
    def test_install_and_remove_manage_user_unit_without_touching_profile(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            commands = root / "commands"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            for name in ("systemctl", "journalctl", "xvfb-run", "xauth"):
                shim = fake_bin / name
                shim.write_text(f"#!/bin/sh\necho '{name}' \"$@\" >> \"{commands}\"\n")
                shim.chmod(0o755)
            app = root / "pleazyng"
            app.write_text("#!/bin/sh\nexit 0\n")
            app.chmod(0o755)
            config = root / "config"
            data = root / "data"
            env = os.environ.copy()
            env.update(
                XDG_CONFIG_HOME=str(config),
                XDG_DATA_HOME=str(data),
                PATH=f"{fake_bin}:{env['PATH']}",
            )

            subprocess.run(["bash", str(SCRIPT), "install", str(app)], env=env, check=True, capture_output=True)
            unit = config / "systemd/user/pleazyng-music-endpoint.service"
            launcher = data / "pleazyng/music-endpoint/launch.sh"
            self.assertTrue(unit.exists())
            self.assertTrue(launcher.exists())
            self.assertIn(f'ExecStart="{launcher}"', unit.read_text())
            self.assertIn("--pleazyng-music-endpoint", launcher.read_text())
            self.assertIn(str(app), launcher.read_text())
            self.assertIn("systemctl --user enable pleazyng-music-endpoint.service", commands.read_text())
            self.assertIn("systemctl --user restart pleazyng-music-endpoint.service", commands.read_text())

            subprocess.run(["bash", str(SCRIPT), "install", str(app)], env=env, check=True, capture_output=True)
            self.assertEqual(commands.read_text().count("systemctl --user restart"), 2)

            systemctl = fake_bin / "systemctl"
            systemctl.write_text("#!/bin/sh\nexit 7\n")
            failed = subprocess.run(["bash", str(SCRIPT), "remove"], env=env, capture_output=True)
            self.assertEqual(failed.returncode, 7)
            self.assertTrue(unit.exists())
            self.assertTrue(launcher.exists())

            status = subprocess.run(["bash", str(SCRIPT), "status"], env=env, capture_output=True)
            self.assertEqual(status.returncode, 7)
            self.assertIn("journalctl --user", commands.read_text())

            systemctl.write_text(f"#!/bin/sh\necho systemctl \"$@\" >> \"{commands}\"\n")

            subprocess.run(["bash", str(SCRIPT), "remove"], env=env, check=True, capture_output=True)
            self.assertFalse(unit.exists())
            self.assertFalse(launcher.exists())
            self.assertIn("systemctl --user disable --now", commands.read_text())

            subprocess.run(["bash", str(SCRIPT), "remove"], env=env, check=True, capture_output=True)

    def test_unsupported_service_paths_fail_before_writing_units(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            for name in ("systemctl", "xvfb-run", "xauth"):
                shim = fake_bin / name
                shim.write_text("#!/bin/sh\nexit 0\n")
                shim.chmod(0o755)
            app = root / "pleazyng"
            app.write_text("#!/bin/sh\nexit 0\n")
            app.chmod(0o755)
            for invalid in ("bad\npath", "bad%path", "bad$path", "bad\\path", 'bad"path'):
                env = dict(os.environ, PATH=f"{fake_bin}:{os.environ['PATH']}",
                           XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / invalid))
                result = subprocess.run(["bash", str(SCRIPT), "install", str(app)], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "config/systemd/user/pleazyng-music-endpoint.service").exists())
                self.assertIn(b"Unsupported character", result.stderr)


if __name__ == "__main__":
    unittest.main()
