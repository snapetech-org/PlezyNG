"""Keep Linux bundle construction's GStreamer plugin packages installed."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
REQUIRED_GSTREAMER_PACKAGES = {
    "gstreamer1.0-plugins-base",
    "gstreamer1.0-plugins-good",
    "gstreamer1.0-plugins-bad",
    "gstreamer1.0-libav",
}


def _release_packages() -> set[str]:
    lines = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("  LINUX_APT_PACKAGES: >"))
    packages: set[str] = set()
    for line in lines[start + 1 :]:
        if not line.startswith("    "):
            break
        packages.update(re.findall(r"[a-z0-9][a-z0-9.+-]*", line))
    return packages


def _ci_smoke_packages() -> set[str]:
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    marker = "      - name: Install packaging dependencies\n"
    if marker not in workflow:
        raise AssertionError("Linux package smoke dependency step is missing")
    step = workflow.split(marker, 1)[1].split("\n      - name:", 1)[0]
    install = re.search(
        r"sudo apt-get install -y --no-install-recommends \\\n(?P<packages>.*?)\n\s*proxy=",
        step,
        re.DOTALL,
    )
    if install is None:
        raise AssertionError("Linux package smoke apt install list could not be read")
    return set(re.findall(r"[a-z0-9][a-z0-9.+-]*", install.group("packages")))


class LinuxBundleWorkflowPackagesTest(unittest.TestCase):
    def test_versioned_linux_build_installs_required_gstreamer_plugins(self) -> None:
        missing = REQUIRED_GSTREAMER_PACKAGES - _release_packages()
        self.assertEqual(set(), missing, f"build.yml is missing GStreamer packages: {sorted(missing)}")

    def test_linux_package_smoke_installs_required_gstreamer_plugins(self) -> None:
        missing = REQUIRED_GSTREAMER_PACKAGES - _ci_smoke_packages()
        self.assertEqual(set(), missing, f"ci.yml is missing GStreamer packages: {sorted(missing)}")


if __name__ == "__main__":
    unittest.main()
