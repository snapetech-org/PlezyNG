import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("hosted_apt", Path(__file__).parents[1] / "configure_hosted_apt.py")
apt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(apt)


class HostedAptTest(unittest.TestCase):
    def test_mirror_file_indirection_and_both_source_formats(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                "etc/apt/sources.list": "deb http://azure.archive.ubuntu.com/ubuntu noble main\n",
                "etc/apt/sources.list.d/ubuntu.sources": "URIs: mirror+file:/etc/apt/apt-mirrors.txt\nSuites: noble noble-updates\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n",
                "etc/apt/apt-mirrors.txt": "http://azure.archive.ubuntu.com/ubuntu/\nhttp://archive.ubuntu.com/ubuntu/\n",
                "etc/apt/apt-mirrors-security.txt": "http://security.ubuntu.com/ubuntu/\n",
                "etc/apt/sources.list.d/vendor.list": "deb https://packages.microsoft.com/ubuntu/24.04/prod noble main\n",
            }
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            receipt = apt.configure(root, "github-hosted", "amd64")
            self.assertEqual(len(receipt["changedSources"]), 3)
            self.assertEqual((root / "etc/apt/sources.list.d/ubuntu.sources").read_text(), files["etc/apt/sources.list.d/ubuntu.sources"])
            self.assertEqual((root / "etc/apt/sources.list.d/vendor.list").read_text(), files["etc/apt/sources.list.d/vendor.list"])
            self.assertEqual((root / "etc/apt/apt-mirrors.txt").read_text(), "https://archive.ubuntu.com/ubuntu/\nhttps://archive.ubuntu.com/ubuntu/\n")
            self.assertIn('Acquire::https::Timeout "30";', (root / receipt["networkConfig"]).read_text())
            self.assertEqual(apt.configure(root, "github-hosted", "amd64")["changedSources"], [])

    def test_arm64_azure_mirror_uses_official_ports_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "etc/apt/sources.list.d/ubuntu.sources"
            path.parent.mkdir(parents=True)
            path.write_text("URIs: http://azure.archive.ubuntu.com/ubuntu\nSuites: noble\nArchitectures: arm64\n")
            apt.configure(root, "github-hosted", "arm64")
            self.assertEqual(path.read_text(), "URIs: https://ports.ubuntu.com/ubuntu-ports\nSuites: noble\nArchitectures: arm64\n")

    def test_private_sources_and_configuration_remain_byte_identical(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "etc/apt/apt-mirrors.txt"
            path.parent.mkdir(parents=True)
            content = "http://azure.archive.ubuntu.com/ubuntu/\nhttps://private.invalid/ubuntu/\n"
            path.write_text(content)
            self.assertTrue(apt.configure(root, "self-hosted", "amd64")["privateSourcesPreserved"])
            self.assertEqual(path.read_text(), content)
            self.assertEqual([p for p in root.rglob("*") if p.is_file()], [path])


if __name__ == "__main__":
    unittest.main()
