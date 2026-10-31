import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.motion.export_android_litert_models import preserve_google_tensor_aot_records


class PreserveGoogleTensorAotRecordsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.output_dir = Path(self.temporary_directory.name)
        self.model_path = self.output_dir / "anvil-s-720p-google-tensor-g5.tflite"
        self.model_bytes = b"verified Tensor G5 AOT model"
        self.model_path.write_bytes(self.model_bytes)
        self.record = {
            "backend": "google-tensor",
            "bytes": len(self.model_bytes),
            "execution": "aot",
            "file": self.model_path.name,
            "input_layout": "NHWC",
            "input_shape": [1, 720, 1280, 6],
            "output_layout": "NHWC",
            "output_shape": [1, 720, 1280, 3],
            "precision": "float16-truncated",
            "sha256": hashlib.sha256(self.model_bytes).hexdigest(),
            "soc_model": "Tensor_G5",
        }
        self.existing_manifest = {
            "source": {"revision": "anvil-source"},
            "weights": {"revision": "anvil-weights"},
            "google_tensor_aot": {
                "converter": "litert-torch==0.10.0",
                "litert": "ai-edge-litert==2.3.0",
                "sdk": "ai-edge-litert-sdk-google-tensor-nightly==2.3.0.dev20261001",
                "torch": "2.14.1+cpu",
                "validated_resolutions": ["720p"],
            },
            "models": {
                "anvil-s": {"variants": {"720p": {"google-tensor-g5": self.record}}},
            },
        }
        self.output_manifest = {
            "source": {"revision": "anvil-source"},
            "weights": {"revision": "anvil-weights"},
            "models": {"anvil-s": {"variants": {"720p": {"gpu": {"file": "anvil-s-720p.tflite"}}}}},
        }

    def test_preserves_integrity_checked_tensor_models_and_provenance(self) -> None:
        preserved = preserve_google_tensor_aot_records(
            self.output_dir,
            self.existing_manifest,
            self.output_manifest,
        )

        self.assertTrue(preserved)
        self.assertEqual(
            self.output_manifest["models"]["anvil-s"]["variants"]["720p"]["google-tensor-g5"],
            self.record,
        )
        self.assertEqual(
            self.output_manifest["google_tensor_aot"]["compiled_resolutions"],
            ["720p"],
        )
        self.assertNotIn("validated_resolutions", self.output_manifest["google_tensor_aot"])

    def test_rejects_aot_models_for_different_source_or_weights(self) -> None:
        self.output_manifest["weights"] = {"revision": "different-weights"}

        with self.assertRaisesRegex(ValueError, "different ANVIL source or weights"):
            preserve_google_tensor_aot_records(
                self.output_dir,
                self.existing_manifest,
                self.output_manifest,
            )

    def test_preserves_tensor_shape_when_ordinary_export_omits_that_resolution(self) -> None:
        self.output_manifest["models"]["anvil-s"]["variants"] = {}

        preserved = preserve_google_tensor_aot_records(
            self.output_dir,
            self.existing_manifest,
            self.output_manifest,
        )

        self.assertTrue(preserved)
        self.assertEqual(
            self.output_manifest["models"]["anvil-s"]["variants"]["720p"]["google-tensor-g5"],
            self.record,
        )

    def test_rejects_corrupt_existing_aot_model(self) -> None:
        self.model_path.write_bytes(b"corrupt")

        with self.assertRaisesRegex(ValueError, "failed integrity checks"):
            preserve_google_tensor_aot_records(
                self.output_dir,
                self.existing_manifest,
                self.output_manifest,
            )


if __name__ == "__main__":
    unittest.main()
