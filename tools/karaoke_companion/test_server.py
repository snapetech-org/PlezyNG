"""Protocol and durable queue checks; no media tools or model downloads."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from server import Jobs


class JobsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.jobs = Jobs(Path(self.tmp.name), None, None, None, 30)
        self.asset = hashlib.sha256(b"backing").hexdigest()
        (self.jobs.assets / self.asset).write_bytes(b"backing")

    def tearDown(self):
        self.jobs.pool.shutdown(wait=True, cancel_futures=True)
        self.tmp.cleanup()

    def request(self, **changes):
        return {"id": "request_0001", "kind": "waveform", "assets": [self.asset], **changes}

    def test_separation_requires_the_patched_runtime(self):
        models = Path(self.tmp.name) / "models"
        models.mkdir()
        self.jobs.models, self.jobs.model_revision = models, "fixture"
        versions = {"torch": "2.15.0+cpu", "torchaudio": "2.11.1+cpu", "torchcodec": "0.17.0+cpu", "setuptools": "84.2.1"}
        with patch("server.shutil.which", return_value="/fixture/tool"), \
                patch("server.importlib.util.find_spec", return_value=object()), \
                patch("server.importlib.metadata.version", side_effect=versions.__getitem__):
            self.assertTrue(self.jobs.capabilities()["capabilities"]["separate"])
            versions["torch"] = "2.8.0"
            self.assertFalse(self.jobs.capabilities()["capabilities"]["separate"])
            versions["torch"] = "2.15.0+cpu"
            versions["setuptools"] = "81.0.0"
            self.assertFalse(self.jobs.capabilities()["capabilities"]["separate"])
            versions["setuptools"] = "84.2.1"
            versions["torch"] = "2.15.0rc1"
            self.assertFalse(self.jobs.capabilities()["capabilities"]["separate"])

    def test_retries_return_same_job_and_reject_changed_inputs(self):
        with patch.object(self.jobs, "capabilities", return_value={"capabilities": {"waveform": True}}), \
                patch.object(self.jobs.pool, "submit") as submit:
            first = self.jobs.submit(self.request())
            again = self.jobs.submit(self.request())
            self.assertEqual(first["fingerprint"], again["fingerprint"])
            self.assertEqual(1, submit.call_count)
            with self.assertRaisesRegex(ValueError, "reused"):
                self.jobs.submit(self.request(params={"changed": True}))
            self.assertEqual(b"backing", (self.jobs.jobs / first["id"] / "input-0").read_bytes())

    def test_restart_interrupts_incomplete_jobs(self):
        with patch.object(self.jobs, "capabilities", return_value={"capabilities": {"waveform": True}}), \
                patch.object(self.jobs.pool, "submit"):
            self.jobs.submit(self.request())
        restored = Jobs(Path(self.tmp.name), None, None, None, 30)
        try:
            self.assertEqual("interrupted", restored.states["request_0001"]["status"])
            state = json.loads((restored.jobs / "request_0001" / "state.json").read_text())
            self.assertEqual("interrupted", state["status"])
        finally:
            restored.pool.shutdown(wait=True, cancel_futures=True)

    def test_rejects_missing_assets_and_path_injection(self):
        for changes in [{"id": "../outside"}, {"assets": ["../outside"]}, {"assets": ["a" * 64]}, {"params": []}]:
            with self.assertRaises(ValueError):
                self.jobs.submit(self.request(**changes))

    def test_cancel_before_worker_execution_is_durable_and_removable(self):
        with patch.object(self.jobs, "capabilities", return_value={"capabilities": {"waveform": True}}), \
                patch.object(self.jobs.pool, "submit"):
            self.jobs.submit(self.request())
        self.jobs.cancel("request_0001")
        self.jobs.execute("request_0001")
        self.assertEqual("canceled", self.jobs.states["request_0001"]["status"])
        self.jobs.remove("request_0001")
        self.assertFalse((self.jobs.assets / self.asset).exists())


if __name__ == "__main__":
    unittest.main()
