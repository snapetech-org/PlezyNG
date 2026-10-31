#!/usr/bin/env python3
"""Regression tests for the Linux RX 7900 XT motion launcher."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "scripts/motion/with_rx7900_motion_gpu.sh"


@unittest.skipUnless(os.name == "posix", "the Linux motion launcher requires POSIX tools")
class MotionGpuLauncherTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="plezy-motion-launcher-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin_directory = self.root / "bin"
        self.runtime_directory = self.root / "runtime bundle"
        self.bin_directory.mkdir()
        self.runtime_directory.mkdir()
        self.vulkan_log = self.root / "vulkaninfo.log"
        self.app_log = self.root / "app-environment.log"

        for command in ("awk", "dirname", "readlink"):
            source = shutil.which(command)
            if source is None:
                self.fail(f"required system command is unavailable: {command}")
            os.symlink(source, self.bin_directory / command)

        self._write_executable(
            self.bin_directory / "rocminfo",
            """#!/bin/sh
printf '%s\\n' \\
  'Agent 1' \\
  '  Name: gfx1100' \\
  '  Uuid: GPU-test-7900' \\
  '  Vendor Name: AMD' \\
  '  Marketing Name: AMD Radeon RX 7900 XT'
""",
        )
        self._write_executable(
            self.root / "app",
            """#!/bin/bash
printf '%s\\n' \\
  "${PLEZY_PME_WEBGPU_VENDOR_ID:-unset}" \\
  "${PLEZY_PME_WEBGPU_DEVICE_ID:-unset}" \\
  "${PLEZY_PME_VULKAN_DEVICE:-unset}" > "$MOTION_APP_ENV_LOG"
""",
        )

        self.environment = os.environ.copy()
        self.environment["PATH"] = str(self.bin_directory)
        self.environment["PLEZY_PME_RUNTIME_DIR"] = f"  {self.runtime_directory}  "
        self.environment["MOTION_VULKANINFO_LOG"] = str(self.vulkan_log)
        self.environment["MOTION_APP_ENV_LOG"] = str(self.app_log)
        for name in (
            "PLEZY_PME_USE_WEBGPU",
            "PLEZY_PME_WEBGPU_VENDOR_ID",
            "PLEZY_PME_WEBGPU_DEVICE_ID",
            "PLEZY_PME_LIBRARY_PATH",
        ):
            self.environment.pop(name, None)

        (self.runtime_directory / "libplezy_motion_engine.so").touch()
        (self.runtime_directory / "libonnxruntime.so").touch()

    def _write_executable(self, path: Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def _write_manifest(self, provider: str) -> None:
        (self.runtime_directory / "providers.linux.tsv").write_text(
            "# Provider name<TAB>device kind<TAB>plugin path\n" + provider,
            encoding="utf-8",
        )

    def _install_vulkaninfo(self) -> None:
        self._write_executable(
            self.bin_directory / "vulkaninfo",
            """#!/bin/sh
printf 'called\\n' >> "$MOTION_VULKANINFO_LOG"
printf '%s\\n' \\
  'GPU0:' \\
  'deviceName = AMD Radeon RX 7900 XT' \\
  'vendorID = 0x1002' \\
  'deviceID = 0x744c'
""",
        )

    def _run_launcher(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(LAUNCHER), str(self.root / "app")],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
            env=self.environment,
        )

    def test_migraphx_runtime_does_not_require_vulkaninfo(self) -> None:
        self._write_manifest("MIGraphXExecutionProvider\tGPU\tbuiltin-migraphx\n")

        result = self._run_launcher()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.vulkan_log.exists())
        self.assertEqual(
            self.app_log.read_text(encoding="utf-8").splitlines(),
            ["unset", "unset", "AMD Radeon RX 7900 XT"],
        )

    def test_webgpu_manifest_is_trimmed_and_pins_the_adapter(self) -> None:
        self._write_manifest("  WebGpuExecutionProvider  \tGPU\tlibonnxruntime_providers_webgpu.so\n")
        self._install_vulkaninfo()

        result = self._run_launcher()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.vulkan_log.read_text(encoding="utf-8"), "called\n")
        self.assertEqual(
            self.app_log.read_text(encoding="utf-8").splitlines(),
            ["0x1002", "0x744c", "AMD Radeon RX 7900 XT"],
        )

    def test_webgpu_fails_closed_without_vulkaninfo(self) -> None:
        self._write_manifest("WebGpuExecutionProvider\tGPU\tlibonnxruntime_providers_webgpu.so\n")

        result = self._run_launcher()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vulkaninfo is required", result.stderr)
        self.assertFalse(self.app_log.exists())


if __name__ == "__main__":
    unittest.main()
