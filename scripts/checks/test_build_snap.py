#!/usr/bin/env python3
"""Check the trusted-hosted Snap admission path without running Podman."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildSnapAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="plezy-build-snap-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.project = self.root / "linux/packaging/snap"
        self.project.mkdir(parents=True)
        self.script = self.root / "scripts/build_snap.sh"
        self.script.parent.mkdir()
        shutil.copyfile(ROOT / "scripts/build_snap.sh", self.script)
        shutil.copyfile(
            ROOT / "linux/packaging/snap/toolchain.lock.json",
            self.project / "toolchain.lock.json",
        )

        self.bin = self.root / "bin"
        self.bin.mkdir()
        uname = self.bin / "uname"
        uname.write_text(
            '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n',
            encoding="utf-8",
        )
        uname.chmod(0o755)
        self.commands = self.root / "commands.jsonl"
        sudo = self.bin / "sudo"
        sudo.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['FAKE_COMMANDS'], 'a', encoding='utf-8') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "raise SystemExit(int(os.environ.get('FAKE_SUDO_STATUS', '42')))\n",
            encoding="utf-8",
        )
        sudo.chmod(0o755)
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.output = self.root / "github-output"
        self.output.touch()
        self.env = os.environ | {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "GITHUB_ACTIONS": "true",
            "GITHUB_RUN_ID": "123456",
            "GITHUB_REPOSITORY": "snapetech-org/PlezyNG",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_OUTPUT": str(self.output),
            "PLEZYNG_ALLOW_PUBLIC_SNAP": "true",
            "HTTPS_PROXY": "",
            "https_proxy": "",
            "FAKE_COMMANDS": str(self.commands),
        }

    def run_builder(self, **overrides):
        return subprocess.run(
            ["bash", str(self.script), "amd64"],
            env=self.env | overrides,
            capture_output=True,
            text=True,
            check=False,
        )

    def recorded_commands(self):
        if not self.commands.exists():
            return []
        return [json.loads(line) for line in self.commands.read_text().splitlines()]

    def test_trusted_main_hybrid_can_use_direct_network_without_private_proxy(self):
        result = self.run_builder()

        # The mock sudo stops at the first apt command. Reaching it proves the
        # hosted trust checks and the no-proxy hybrid route both passed.
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertEqual(self.recorded_commands()[0][:3], ["-n", "apt-get", "update"])

    def test_untrusted_hosted_contexts_are_rejected_before_privileged_tools(self):
        for override in (
            {"PLEZYNG_ALLOW_PUBLIC_SNAP": "false"},
            {"GITHUB_REPOSITORY": "example/Pleazyng"},
            {"GITHUB_REF": "refs/pull/123/merge"},
            {"GITHUB_EVENT_NAME": "pull_request"},
        ):
            with self.subTest(override=override):
                self.commands.unlink(missing_ok=True)
                result = self.run_builder(**override)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.recorded_commands(), [])

    def test_private_runner_without_its_proxy_is_rejected_before_tools(self):
        result = self.run_builder(
            RUNNER_ENVIRONMENT="self-hosted",
            PLEZYNG_ALLOW_PUBLIC_SNAP="false",
        )

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.recorded_commands(), [])


if __name__ == "__main__":
    unittest.main()
