import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import nix_release_metadata as nix
from release_coverage import REQUIRED


class NixMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / nix.METADATA_PATH
        self.path.parent.mkdir(parents=True)
        self.current = {"repository": nix.REPOSITORY, "tag": "v3.0.7", "version": "3.0.7",
                        "sha256": {"x64": "c" * 64, "arm64": "d" * 64}}
        self.path.write_text(json.dumps(self.current))
        self.commit = "e" * 40
        self.raw = ("a" * 64 + "  pleazyng-linux-x64.tar.gz\n" +
                    "b" * 64 + "  pleazyng-linux-arm64.tar.gz\n").encode()
        self.digest = hashlib.sha256(self.raw).hexdigest()
        names = {p.replace("*", "org.snapetech.pleazyng") for ps in REQUIRED.values() for p in ps}
        names.add("SHA256SUMS.txt")
        self.metadata = {"id": 1, "tag_name": "v3.0.33", "draft": False, "prerelease": False,
                         "published_at": "2026-11-11T00:00:00Z", "assets": [
                             {"id": i, "name": name, "size": 100} for i, name in enumerate(sorted(names), 1)]}
        for asset in self.metadata["assets"]:
            if asset["name"] == "SHA256SUMS.txt":
                asset.update(size=len(self.raw), digest="sha256:" + self.digest)
            elif asset["name"] in nix.ASSETS.values():
                asset["digest"] = "sha256:" + ("a" if "x64" in asset["name"] else "b") * 64
        self.assembly = {"status": "completed", "conclusion": "success", "head_sha": self.commit,
                         "path": ".github/workflows/build.yml", "run_attempt": 1,
                         "repository": {"full_name": nix.REPOSITORY}}
        self.source = {"encoding": "base64", "size": len(b"version: 3.0.33+192\n"),
                       "content": base64.b64encode(b"version: 3.0.33+192\n").decode()}
        self.proof = [{"verificationResult": {"statement": {
            "subject": [{"name": "SHA256SUMS.txt", "digest": {"sha256": self.digest}}],
            "predicate": {"buildDefinition": {
                "externalParameters": {"workflow": {"repository": "https://github.com/" + nix.REPOSITORY,
                                                       "path": ".github/workflows/build.yml"}},
                "resolvedDependencies": [{"digest": {"gitCommit": self.commit},
                                           "uri": "git+https://github.com/" + nix.REPOSITORY + "@refs/heads/main"}]},
                "runDetails": {"metadata": {"invocationId":
                    "https://github.com/" + nix.REPOSITORY + "/actions/runs/123/attempts/1"}}}}}}]

    def github(self, path):
        if path.startswith("compare/"):
            return {"status": "ahead"}
        if path.startswith("contents/"):
            return self.source
        if path.startswith("actions/"):
            return self.assembly
        self.assertEqual(path, "releases/latest")
        return copy.deepcopy(self.metadata)

    def subprocess(self, args, **kwargs):
        if args[1:3] == ["release", "download"]:
            (Path(args[args.index("--dir") + 1]) / "SHA256SUMS.txt").write_bytes(self.raw)
            return SimpleNamespace(returncode=0)
        self.assertEqual(args[1:3], ["attestation", "verify"])
        self.assertEqual(args[args.index("--source-digest") + 1], self.commit)
        return SimpleNamespace(returncode=0, stdout=json.dumps(self.proof))

    def prepare(self, github=None):
        with patch.object(nix, "require_repository_identity"), patch.object(nix.subprocess, "run", side_effect=self.subprocess):
            return nix.prepare(self.root, self.metadata, self.commit, github or self.github)

    def test_exact_source_manifest_and_asset_digests_prepare_only_metadata(self):
        text, receipt = self.prepare()
        self.assertEqual(json.loads(text)["sha256"], {"x64": "a" * 64, "arm64": "b" * 64})
        self.assertEqual(receipt["assembly_run"], 123)
        self.assertEqual(receipt["application_build"], "192")
        self.assertEqual(json.loads(self.path.read_text()), self.current)

    def test_approved_frozen_repair_uses_workflow_attestation_and_product_source(self):
        workflow = "f" * 40
        packaging = "d" * 40
        receipt = {"product_source_sha": self.commit, "source_sha": self.commit,
                   "workflow_source_sha": workflow, "packaging_source_sha": packaging,
                   "actual_checkout_sha": packaging, "source_run_id": 99,
                   "assembly_run_id": 123, "packaging_approval": {"approved": True}}
        receipt_raw = json.dumps(receipt).encode()
        receipt_digest = hashlib.sha256(receipt_raw).hexdigest()
        self.raw += (receipt_digest + "  platform-reuse-provenance.json\n").encode()
        self.digest = hashlib.sha256(self.raw).hexdigest()
        next(a for a in self.metadata["assets"] if a["name"] == "SHA256SUMS.txt").update(
            size=len(self.raw), digest="sha256:" + self.digest)
        self.metadata["assets"].append({"id": 900, "name": "platform-reuse-provenance.json",
                                        "size": len(receipt_raw), "digest": "sha256:" + receipt_digest})
        self.proof[0]["verificationResult"]["statement"]["subject"][0]["digest"]["sha256"] = self.digest
        self.proof[0]["verificationResult"]["statement"]["predicate"]["buildDefinition"][
            "resolvedDependencies"][0]["digest"]["gitCommit"] = workflow
        self.assembly["head_sha"] = workflow

        def run(args, **kwargs):
            if args[1:3] == ["release", "download"]:
                pattern = args[args.index("--pattern") + 1]
                (Path(args[args.index("--dir") + 1]) / pattern).write_bytes(
                    receipt_raw if pattern == "platform-reuse-provenance.json" else self.raw)
                return SimpleNamespace(returncode=0)
            self.assertEqual(args[args.index("--source-digest") + 1], workflow)
            return SimpleNamespace(returncode=0, stdout=json.dumps(self.proof))

        with patch.object(nix, "require_repository_identity"), \
             patch.object(nix, "verify_receipt", return_value=receipt["packaging_approval"]) as verify, \
             patch.object(nix.subprocess, "run", side_effect=run):
            _, prepared = nix.prepare(self.root, self.metadata, self.commit, self.github)
        self.assertEqual(prepared["assembly_workflow_source"], workflow)
        verify.assert_called_once()


    def test_publication_and_coverage_fail_closed_before_network(self):
        for kind in ("draft", "prerelease", "incomplete"):
            with self.subTest(kind=kind):
                metadata = copy.deepcopy(self.metadata)
                if kind == "incomplete":
                    metadata["assets"] = [a for a in metadata["assets"] if "windows-arm64" not in a["name"]]
                else:
                    metadata[kind] = True
                with self.assertRaises(ValueError):
                    nix.validate_release(metadata)

    def test_old_release_floor_downgrade_same_version_mutation_and_noop(self):
        with self.assertRaisesRegex(ValueError, "floor"):
            nix.proposed_metadata(self.current, "v3.0.32", self.raw.decode())
        proposed = nix.proposed_metadata(self.current, "v3.0.33", self.raw.decode())
        self.assertEqual(nix.proposed_metadata(proposed, "v3.0.33", self.raw.decode()), proposed)
        with self.assertRaisesRegex(ValueError, "same version"):
            nix.proposed_metadata(proposed, "v3.0.33", self.raw.decode().replace("a" * 64, "f" * 64))
        newer = {**proposed, "tag": "v3.0.34", "version": "3.0.34"}
        with self.assertRaisesRegex(ValueError, "downgrade"):
            nix.proposed_metadata(newer, "v3.0.33", self.raw.decode())

    def test_immutable_version_mismatch_and_unmerged_source_rejected(self):
        self.source["content"] = base64.b64encode(b"version: 3.0.31+190\n").decode()
        with self.assertRaisesRegex(ValueError, "immutable application version"):
            self.prepare()
        with self.assertRaisesRegex(ValueError, "canonical main"):
            self.prepare(lambda path: {"status": "diverged"})

    def test_statement_source_subject_workflow_and_run_identity_are_bound(self):
        original = copy.deepcopy(self.proof)
        mutations = [lambda s: s["subject"][0]["digest"].update(sha256="f" * 64),
                     lambda s: s["predicate"]["buildDefinition"]["resolvedDependencies"][0]["digest"].update(gitCommit="f" * 40),
                     lambda s: s["predicate"]["buildDefinition"]["externalParameters"]["workflow"].update(path="other.yml"),
                     lambda s: s["predicate"]["runDetails"]["metadata"].update(invocationId="https://example.com/123")]
        for mutate in mutations:
            self.proof = copy.deepcopy(original)
            mutate(self.proof[0]["verificationResult"]["statement"])
            with self.assertRaisesRegex(ValueError, "attestation"):
                self.prepare()

    def test_failed_wrong_source_or_foreign_assembly_and_asset_replacement_rejected(self):
        original = copy.deepcopy(self.assembly)
        for changes in ({"conclusion": "failure"}, {"head_sha": "f" * 40}, {"run_attempt": 2},
                        {"repository": {"full_name": "other/repo"}}):
            self.assembly = {**original, **changes}
            with self.assertRaisesRegex(ValueError, "assembly"):
                self.prepare()
        self.assembly = original
        next(a for a in self.metadata["assets"] if a["name"] == nix.ASSETS["x64"])["digest"] = "sha256:" + "f" * 64
        with self.assertRaisesRegex(ValueError, "Linux release asset"):
            self.prepare()

    def test_download_counts_are_ignored_but_asset_changes_are_rejected(self):
        def changed(path):
            result = self.github(path)
            if path == "releases/latest":
                result["assets"][0]["download_count"] = 100
            return result
        self.prepare(changed)
        def replaced(path):
            result = changed(path)
            if path == "releases/latest":
                result["assets"][0]["id"] += 1
            return result
        with self.assertRaisesRegex(ValueError, "changed during"):
            self.prepare(replaced)

    def test_failed_signature_and_malformed_or_duplicate_hashes_never_prepare(self):
        def invalid_signature(args, **kwargs):
            if args[1:3] == ["attestation", "verify"]:
                raise subprocess.CalledProcessError(1, "gh")
            return self.subprocess(args, **kwargs)
        with patch.object(nix, "require_repository_identity"), patch.object(nix.subprocess, "run", side_effect=invalid_signature):
            with self.assertRaises(subprocess.CalledProcessError):
                nix.prepare(self.root, self.metadata, self.commit, self.github)
        for manifest in (self.raw.decode() + self.raw.decode(), self.raw.decode().splitlines()[0],
                         self.raw.decode().replace("a" * 64, "0" * 64)):
            with self.assertRaises(ValueError):
                nix.proposed_metadata(self.current, "v3.0.33", manifest)


if __name__ == "__main__":
    unittest.main()
