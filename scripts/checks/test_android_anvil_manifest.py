"""Regression coverage for interrupted QAIRT context packaging without the SDK."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("anvil_context_builder", ROOT / "scripts/motion/build_android_anvil_contexts.py")
assert SPEC and SPEC.loader
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class AnvilManifestTest(unittest.TestCase):
    def test_existing_manifest_prevents_reusing_published_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            manifest = output / "manifest.json"
            manifest.write_text('{"prior": true}')
            with self.assertRaisesRegex(ValueError, "already contains manifest.json"):
                BUILDER.reject_stale_contexts(output, ["sm7325"], ["anvil-s"])
            self.assertEqual(manifest.read_text(), '{"prior": true}')

    def test_dangling_manifest_symlink_is_not_a_fresh_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "manifest.json").symlink_to(output / "absent.json")
            with self.assertRaisesRegex(ValueError, "already contains manifest.json"):
                BUILDER.reject_stale_contexts(output, ["sm7325"], ["anvil-s"])

    def test_complete_manifest_is_visible_only_at_atomic_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            payload = {"contexts": [{"target": "sm7325", "model": "anvil-s"}]}
            replace = os.replace

            def inspect(source, destination):
                self.assertFalse(Path(destination).exists())
                self.assertEqual(json.loads(Path(source).read_text()), payload)
                replace(source, destination)

            with patch.object(BUILDER.os, "replace", side_effect=inspect) as replacement:
                manifest = BUILDER.publish_manifest(output, payload)
            replacement.assert_called_once()
            self.assertEqual(json.loads(manifest.read_text()), payload)
            self.assertEqual(list(output.glob(".manifest.*.partial")), [])

    def test_interrupted_publication_leaves_no_false_manifest_or_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with patch.object(BUILDER.os, "replace", side_effect=OSError("publication interrupted")):
                with self.assertRaisesRegex(OSError, "publication interrupted"):
                    BUILDER.publish_manifest(output, {"contexts": []})
            self.assertFalse((output / "manifest.json").exists())
            self.assertEqual(list(output.iterdir()), [])
            BUILDER.reject_stale_contexts(output, ["sm7325"], ["anvil-s"])
            self.assertTrue(BUILDER.publish_manifest(output, {"contexts": []}).is_file())

    def test_existing_context_selection_guard_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            context = output / "other/anvil-s-720p/context.serialized.bin"
            context.parent.mkdir(parents=True)
            context.write_bytes(b"context")
            with self.assertRaisesRegex(ValueError, "outside this target/model selection"):
                BUILDER.reject_stale_contexts(output, ["sm7325"], ["anvil-s"])


if __name__ == "__main__":
    unittest.main()
