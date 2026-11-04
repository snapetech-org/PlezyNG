import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
LOCK_PATH = ROOT / "tools" / "webos" / "compatibility.json"
PATCH_PATH = ROOT / "tools" / "webos" / "depot-tools-python314.patch"
REQUIREMENTS_PATH = ROOT / "tools" / "webos" / "depot-tools-python-requirements.txt"
BUILDER_PATH = ROOT / "tools" / "webos" / "build_release_candidate.sh"


class DepotToolsPython314PatchTests(unittest.TestCase):
    def test_compatibility_lock_pins_patch_hash(self):
        lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
        record = lock["engineBuild"]["depotToolsPython314Patch"]
        self.assertEqual(record["path"], "tools/webos/depot-tools-python314.patch")
        self.assertEqual(
            hashlib.sha256(PATCH_PATH.read_bytes()).hexdigest(),
            record["sha256"],
        )

    def test_patch_replaces_removed_pipes_api_with_shlex(self):
        patch = PATCH_PATH.read_text(encoding="utf-8")
        self.assertIn("-import pipes\n+import shlex\n", patch)
        self.assertIn(
            "-    return ' '.join(pipes.quote(arg) for arg in args)\n"
            "+    return ' '.join(shlex.quote(arg) for arg in args)\n",
            patch,
        )
        self.assertIn("diff --git a/fetch.py b/fetch.py", patch)

    def test_patch_updates_removed_ast_literal_aliases(self):
        patch = PATCH_PATH.read_text(encoding="utf-8")
        self.assertIn("diff --git a/gclient_eval.py b/gclient_eval.py", patch)
        self.assertIn("+        if isinstance(node, ast.Constant):", patch)
        self.assertIn("+                        and isinstance(node.args[0].value, str)):", patch)
        self.assertIn("+        if isinstance(node, ast.Constant) and (", patch)

    def test_compatibility_lock_pins_python_dependencies_for_bypassed_vpython(self):
        lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
        record = lock["engineBuild"]["depotToolsPythonRequirements"]
        self.assertEqual(
            record["path"],
            "tools/webos/depot-tools-python-requirements.txt",
        )
        self.assertEqual(
            hashlib.sha256(REQUIREMENTS_PATH.read_bytes()).hexdigest(),
            record["sha256"],
        )
        requirements = REQUIREMENTS_PATH.read_text(encoding="utf-8")
        self.assertIn("httplib2==0.13.1", requirements)
        self.assertIn("six==1.10.0", requirements)

    def test_release_builder_applies_patch_before_gclient_sync(self):
        builder = BUILDER_PATH.read_text(encoding="utf-8")
        verify = builder.index(
            'git -C "$BOOTSTRAP_DEPOT_TOOLS" apply --unidiff-zero --check'
        )
        apply = builder.index(
            'git -C "$BOOTSTRAP_DEPOT_TOOLS" apply --unidiff-zero "$DEPOT_TOOLS_PATCH"'
        )
        requirements_verify = builder.index(
            'if [[ ! -f "$DEPOT_TOOLS_PYTHON_REQUIREMENTS" || -L "$DEPOT_TOOLS_PYTHON_REQUIREMENTS" ]]'
        )
        install_dependencies = builder.index('"$PYTHON_BIN" -m pip install \\')
        export_pythonpath = builder.index('export PYTHONPATH="$DEPOT_TOOLS_PYTHON_SITE')
        sync = builder.index("gclient sync --no-history --shallow -j 8")
        self.assertLess(verify, apply)
        self.assertLess(apply, requirements_verify)
        self.assertLess(requirements_verify, install_dependencies)
        self.assertLess(install_dependencies, export_pythonpath)
        self.assertLess(export_pythonpath, sync)
        self.assertIn('export DEPOT_TOOLS_UPDATE=0', builder)
        self.assertIn("--require-hashes", builder)

    def test_release_builder_runs_verified_ndk_installer_with_system_path(self):
        builder = BUILDER_PATH.read_text(encoding="utf-8")
        self.assertIn(
            "env -u LD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin", builder
        )
        self.assertIn('bash "$NDK_INSTALLER" -y -d "$NDK_ROOT"', builder)


if __name__ == "__main__":
    unittest.main()
