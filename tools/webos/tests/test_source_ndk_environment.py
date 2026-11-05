import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / "tools/webos/source_ndk_environment.sh"
BUILDER = ROOT / "tools/webos/build_engine.sh"


class SourceNdkEnvironmentTests(unittest.TestCase):
    def test_ipk_builder_also_isolates_the_setup_python_loader_path(self):
        builder = (ROOT / "tools/webos/build_ipk.sh").read_text(encoding="utf-8")
        self.assertIn('source "$ROOT/tools/webos/source_ndk_environment.sh"', builder)
        self.assertIn('pleazyng_source_ndk_environment "$NDK_ENVIRONMENT"', builder)
        self.assertIn('trap \'rm -f -- "$NDK_ENVIRONMENT"\' EXIT', builder)
        self.assertNotIn('source <(', builder)

    def test_builder_uses_the_python_path_safe_ndk_source_helper(self):
        builder = BUILDER.read_text(encoding="utf-8")
        self.assertIn('source "$ROOT/tools/webos/source_ndk_environment.sh"', builder)
        self.assertIn(
            'pleazyng_source_ndk_environment "$LOG_ROOT/ndk-environment.sh"', builder
        )

    def test_unsets_setup_python_path_while_sourcing_then_restores_both_paths(self):
        with tempfile.TemporaryDirectory(prefix="plezy-webos-ldpath-") as temporary:
            environment_script = Path(temporary) / "environment-setup.sh"
            environment_script.write_text(
                'if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then\n'
                '  echo "vendor rejected inherited LD_LIBRARY_PATH" >&2\n'
                "  return 23\n"
                "fi\n"
                'export LD_LIBRARY_PATH="/ndk/lib:/ndk/usr/lib"\n',
                encoding="utf-8",
            )
            command = "\n".join(
                (
                    f"source {shlex.quote(str(HELPER))}",
                    f"pleazyng_source_ndk_environment {shlex.quote(str(environment_script))}",
                    'printf "%s\\n" "$LD_LIBRARY_PATH"',
                )
            )
            environment = os.environ.copy()
            environment["LD_LIBRARY_PATH"] = "/setup-python/lib"
            result = subprocess.run(
                ["bash", "-c", command],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(
                result.stdout.strip(), "/ndk/lib:/ndk/usr/lib:/setup-python/lib"
            )

    def test_restores_python_path_if_the_ndk_environment_source_fails(self):
        with tempfile.TemporaryDirectory(prefix="plezy-webos-ldpath-") as temporary:
            environment_script = Path(temporary) / "environment-setup.sh"
            environment_script.write_text("return 23\n", encoding="utf-8")
            command = "\n".join(
                (
                    f"source {shlex.quote(str(HELPER))}",
                    f"if pleazyng_source_ndk_environment {shlex.quote(str(environment_script))}; then",
                    "  exit 0",
                    "else",
                    "  status=$?",
                    '  printf "%s\\n" "$LD_LIBRARY_PATH"',
                    '  exit "$status"',
                    "fi",
                )
            )
            environment = os.environ.copy()
            environment["LD_LIBRARY_PATH"] = "/setup-python/lib"
            result = subprocess.run(
                ["bash", "-c", command],
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(result.returncode, 23)
            self.assertEqual(result.stdout.strip(), "/setup-python/lib")


if __name__ == "__main__":
    unittest.main()
