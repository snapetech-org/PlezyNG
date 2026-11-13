import hashlib
import tempfile
import unittest
import types
from unittest.mock import patch
from pathlib import Path

from scripts.motion import export_android_litert_models as exporter
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
                "torch": "2.12.1+cpu",
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



class GoogleTensorExportNamingTest(unittest.TestCase):
    def test_sdk_names_produce_runtime_provider_keys(self):
        self.assertEqual(exporter.google_tensor_provider_key("Tensor_G5"), "google-tensor-g5")
        self.assertEqual(exporter.google_tensor_provider_key("Tensor_G6"), "google-tensor-g6")

    def test_native_and_suffixed_compiler_outputs_use_the_same_pack_identity(self):
        target = types.SimpleNamespace(
            SocModel=types.SimpleNamespace(TENSOR_G5="G5"), Target=lambda value: value,
        )
        for suffix in ["", "_compiled"]:
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                model = root / "float.tflite"
                model.write_bytes(b"input model")

                def compile_model(source, *, target, output_dir, **flags):
                    Path(output_dir, f"anvil-s-720p_Google_Tensor_G5{suffix}.tflite").write_bytes(b"compiled model")
                    # Other model/SoC outputs must not be mistaken for this target.
                    Path(output_dir, "other_Google_Tensor_G5.tflite").write_bytes(b"other")
                    Path(output_dir, "anvil-s-720p_Google_Tensor_G50.tflite").write_bytes(b"other")
                    return types.SimpleNamespace()

                with patch.object(exporter, "verify_model_interface") as verify:
                    result = exporter.export_google_tensor_aot(model, compile_model, target, "anvil-s", "720p", "Tensor_G5", root, root)
                self.assertEqual(result["file"], "anvil-s-720p-google-tensor-g5.tflite")
                self.assertEqual((root / result["file"]).read_bytes(), b"compiled model")
                verify.assert_called_once()

if __name__ == "__main__":
    unittest.main()
