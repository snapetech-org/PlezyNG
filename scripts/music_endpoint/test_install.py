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
            self.assertIn("systemctl --user enable --now", commands.read_text())

            subprocess.run(["bash", str(SCRIPT), "remove"], env=env, check=True, capture_output=True)
            self.assertFalse(unit.exists())
            self.assertFalse(launcher.exists())
            self.assertIn("systemctl --user disable --now", commands.read_text())


if __name__ == "__main__":
    unittest.main()
