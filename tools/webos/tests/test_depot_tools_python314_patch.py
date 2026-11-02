import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
LOCK_PATH = ROOT / "tools" / "webos" / "compatibility.json"
PATCH_PATH = ROOT / "tools" / "webos" / "depot-tools-python314.patch"
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

    def test_release_builder_applies_patch_before_gclient_sync(self):
        builder = BUILDER_PATH.read_text(encoding="utf-8")
        verify = builder.index(
            'git -C "$BOOTSTRAP_DEPOT_TOOLS" apply --unidiff-zero --check'
        )
        apply = builder.index(
            'git -C "$BOOTSTRAP_DEPOT_TOOLS" apply --unidiff-zero "$DEPOT_TOOLS_PATCH"'
        )
        sync = builder.index("gclient sync --no-history --shallow -j 8")
        self.assertLess(verify, apply)
        self.assertLess(apply, sync)
        self.assertIn('export DEPOT_TOOLS_UPDATE=0', builder)


if __name__ == "__main__":
    unittest.main()
