"""Verify Linux runtime inputs and the real pinned-loader bundle copy steps."""

from pathlib import Path
import os
import re
import subprocess
import tempfile
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
    def test_real_copy_steps_preserve_the_pinned_loader_chain(self) -> None:
        self._exercise_loader_copy(include_loader=True)

    def test_real_copy_steps_reject_native_archives_without_the_loader(self) -> None:
        self._exercise_loader_copy(include_loader=False)

    def _exercise_loader_copy(self, *, include_loader: bool) -> None:
        for workflow, step, arch in (
            ("build.yml", "Copy libmpv into bundle", "x64"),
            ("build.yml", "Copy libmpv into bundle", "arm64"),
            ("ci.yml", "Copy libmpv into the bundle", "x64"),
        ):
            with self.subTest(workflow=workflow, arch=arch), tempfile.TemporaryDirectory(prefix="pleazyng loader ") as temporary:
                root = Path(temporary)
                prefix = root / "libmpv-prefix/lib"
                prefix.mkdir(parents=True)
                (prefix / "libmpv.so.2").write_bytes(b"native mpv")
                (prefix / "libmpv.so").symlink_to("libmpv.so.2")
                (prefix / "libshaderc_shared.so").write_bytes(b"native shaderc")
                if include_loader:
                    (prefix / "libvulkan.so.1.4.309").write_bytes(b"pinned native loader")
                    (prefix / "libvulkan.so.1").symlink_to("libvulkan.so.1.4.309")
                    (prefix / "libvulkan.so").symlink_to("libvulkan.so.1")
                bundle = root / f"build/linux/{arch}/release/bundle"
                (bundle / "lib").mkdir(parents=True)
                text = (ROOT / ".github/workflows" / workflow).read_text()
                block = text.split(f"      - name: {step}\n", 1)[1].split("\n      - name:", 1)[0]
                run = block.split("        run: |\n", 1)[1]
                lines = []
                for line in run.splitlines():
                    if not line.startswith("          "):
                        break
                    lines.append(line[10:])
                self.assertTrue(lines, "the workflow copy step must be executable")
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", "\n".join(lines)],
                    cwd=root, env={**os.environ, "BUNDLE_DIR": str(bundle)},
                    capture_output=True, text=True,
                )
                if include_loader:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((bundle / "lib/libvulkan.so").is_symlink())
                    self.assertTrue((bundle / "lib/libvulkan.so.1").is_symlink())
                    self.assertEqual((bundle / "lib/libvulkan.so.1").read_bytes(), b"pinned native loader")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("libvulkan.so", result.stderr)

    def test_release_and_smoke_hosts_install_the_vulkan_loader(self) -> None:
        self.assertIn("libvulkan1", _release_packages())
        self.assertIn("libvulkan1", _ci_smoke_packages())

    def test_versioned_linux_build_installs_required_gstreamer_plugins(self) -> None:
        missing = REQUIRED_GSTREAMER_PACKAGES - _release_packages()
        self.assertEqual(set(), missing, f"build.yml is missing GStreamer packages: {sorted(missing)}")

    def test_linux_package_smoke_installs_required_gstreamer_plugins(self) -> None:
        missing = REQUIRED_GSTREAMER_PACKAGES - _ci_smoke_packages()
        self.assertEqual(set(), missing, f"ci.yml is missing GStreamer packages: {sorted(missing)}")


if __name__ == "__main__":
    unittest.main()
