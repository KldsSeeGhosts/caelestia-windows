"""Unsigned source transport is data, bound to the exact main run and attempt."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "windows/ci"))
import nexus_sources as sources


class PreparedSourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="prepared-sources-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shell = self.root / "shell"
        self.assets = self.root / "prepared"
        self.transfer = self.root / "transfer"
        self.output = self.root / "materialized"
        self.ctx = {"repository": sources.candidate.REPOSITORY, "event": "push", "ref": "refs/heads/main",
                    "workflow": ".github/workflows/windows-build.yml", "sha": "a" * 40,
                    "runId": "10", "runAttempt": "2", "runNumber": "5"}
        recipe = {"shellRepository": "https://github.com/KldsSeeGhosts/caelestia-windows.git"}
        self.put(self.shell / "windows/release/source-assets.json", recipe)
        self.put(self.shell / "windows/toolchain.json", {"id": "synthetic-pinned-toolchain"})
        self.lock = {"quickshell": {"repository": "https://github.com/KldsSeeGhosts/caelestia-quickshell-windows.git",
                                    "revision": "b" * 40},
                     "m3shapes": {"repository": "https://github.com/soramanew/m3shapes.git", "revision": "c" * 40},
                     "glazier": {"representation": "in-tree"}}
        self.put(self.shell / "windows/sources.lock.json", self.lock)
        notice = b"public corresponding-source notice"
        self.put(self.assets / "notices/LICENSE.txt", notice)
        self.inventory = {
            "schema": "caelestia-component-inventory", "version": 1, "sourceRevision": self.ctx["sha"],
            "recipeSha256": sources.digest(self.shell / "windows/release/source-assets.json"),
            "toolchain": {"id": "synthetic-pinned-toolchain"},
            "projects": [
                {"id": "shell", "repository": recipe["shellRepository"], "revision": self.ctx["sha"]},
                {"id": "backend", "repository": self.lock["quickshell"]["repository"], "revision": "b" * 40},
                {"id": "m3shapes", "repository": self.lock["m3shapes"]["repository"], "revision": "c" * 40}],
            "notices": [{"path": "LICENSE.txt", "sha256": hashlib.sha256(notice).hexdigest()}]}
        self.put(self.assets / "component-inventory.json", self.inventory)
        self.put(self.assets / "execution.json", {
            "schema": "caelestia-source-execution", "version": 1, "sourceRevision": self.ctx["sha"]})
        for name in ("project-source", "supplier-source"):
            self.put(self.assets / name / "component-inventory.json", self.inventory)
            self.put(self.assets / name / "SOURCE-MANIFEST.json", {
                "sourceRevision": self.ctx["sha"],
                "inventorySha256": sources.digest(self.assets / "component-inventory.json")})
            with zipfile.ZipFile(self.assets / (name + ".zip"), "w") as archive:
                for path in (self.assets / name).iterdir():
                    archive.write(path, path.name)
        self.stage = {"stage": "sources", "outcome": "success", "exitCode": 0,
                      "seconds": 2.5, "timeoutSeconds": 1800}

    def put(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else json.dumps(value).encode())

    def export(self):
        sources.export(self.shell, self.assets, self.transfer, self.stage, self.ctx)

    def test_round_trip_preserves_exact_source_bytes_and_excludes_private_work(self):
        self.put(self.assets / "work/private.log", b"never transferred")
        self.put(self.assets / "cache/private-archive", b"never transferred")
        self.export()
        sources.materialize(self.shell, self.transfer, self.output, self.ctx)
        self.assertEqual(self.inventory, sources.read(self.output / "component-inventory.json"))
        self.assertEqual(b"public corresponding-source notice", (self.output / "notices/LICENSE.txt").read_bytes())
        self.assertFalse((self.transfer / "work").exists())
        self.assertFalse((self.transfer / "cache").exists())
        self.assertEqual(sources.digest(self.output / "component-inventory.json"),
                         sources.digest(self.output / "supplier-source/component-inventory.json"))

    def test_foreign_run_attempt_source_recipe_or_toolchain_is_refused_before_output(self):
        self.export()
        for key in ("runId", "runAttempt", "sha"):
            context = {**self.ctx, key: "different"}
            with self.assertRaises(ValueError):
                sources.materialize(self.shell, self.transfer, self.output, context)
            self.assertFalse(self.output.exists())
        for name, value in (("sourceRevision", "d" * 40), ("recipeSha256", "d" * 64),
                            ("toolchain", {"id": "wrong"})):
            inventory = copy.deepcopy(self.inventory)
            inventory[name] = value
            self.put(self.transfer / "component-inventory.json", inventory)
            document = sources.read(self.transfer / sources.INDEX)
            document["files"] = sources.rows(self.transfer)
            self.put(self.transfer / sources.INDEX, document)
            with self.assertRaises(ValueError):
                sources.materialize(self.shell, self.transfer, self.output, self.ctx)
            self.assertFalse(self.output.exists())

    def test_bad_bytes_extra_files_and_edited_notice_inventory_never_pass(self):
        self.export()
        notice = self.transfer / "notices/LICENSE.txt"
        notice.write_bytes(b"changed bytes")
        with self.assertRaisesRegex(ValueError, "bytes-mismatch"):
            sources.materialize(self.shell, self.transfer, self.output, self.ctx)
        document = sources.read(self.transfer / sources.INDEX)
        document["files"] = sources.rows(self.transfer)
        self.put(self.transfer / sources.INDEX, document)
        with self.assertRaisesRegex(ValueError, "notice-mismatch"):
            sources.materialize(self.shell, self.transfer, self.output, self.ctx)
        self.put(self.transfer / "private.log", b"not a source input")
        with self.assertRaisesRegex(ValueError, "extra-file"):
            sources.verify_transfer(self.shell, self.transfer, self.ctx)
        self.assertFalse(self.output.exists())

    def test_binary_notices_and_changed_project_identity_are_refused(self):
        self.export()
        self.put(self.transfer / "notices/helper.exe", b"not a notice")
        with self.assertRaisesRegex(ValueError, "binary-notice"):
            sources.verify_transfer(self.shell, self.transfer, self.ctx)
        (self.transfer / "notices/helper.exe").unlink()
        inventory = copy.deepcopy(self.inventory)
        inventory["projects"][1]["revision"] = "f" * 40
        self.put(self.transfer / "component-inventory.json", inventory)
        document = sources.read(self.transfer / sources.INDEX)
        document["files"] = sources.rows(self.transfer)
        self.put(self.transfer / sources.INDEX, document)
        with self.assertRaisesRegex(ValueError, "project-mismatch"):
            sources.materialize(self.shell, self.transfer, self.output, self.ctx)
        self.assertFalse(self.output.exists())

    def test_extra_notice_is_refused_even_when_the_index_has_its_hash(self):
        self.export()
        self.put(self.transfer / "notices/unrecorded.txt", b"not recorded by the recipe")
        document = sources.read(self.transfer / sources.INDEX)
        document["files"] = sources.rows(self.transfer)
        self.put(self.transfer / sources.INDEX, document)
        with self.assertRaisesRegex(ValueError, "notice-set-mismatch"):
            sources.materialize(self.shell, self.transfer, self.output, self.ctx)
        self.assertFalse(self.output.exists())

    def test_failed_missing_or_incomplete_preparation_never_materializes(self):
        self.export()
        original = sources.read(self.transfer / sources.INDEX)
        for mutation in ({"outcome": "failure"}, {"exitCode": 7}, {"seconds": float("inf")},
                         {"timeoutSeconds": 0}, {"stage": "other"}):
            document = copy.deepcopy(original)
            document["preparation"].update(mutation)
            self.put(self.transfer / sources.INDEX, document)
            with self.assertRaises(ValueError):
                sources.materialize(self.shell, self.transfer, self.output, self.ctx)
            self.assertFalse(self.output.exists())

    def test_embedded_inventory_and_unsafe_zip_paths_are_refused(self):
        self.export()
        archive = self.transfer / "project-source.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("../escaped", b"not allowed")
        document = sources.read(self.transfer / sources.INDEX)
        document["files"] = sources.rows(self.transfer)
        self.put(self.transfer / sources.INDEX, document)
        with self.assertRaises(ValueError):
            sources.materialize(self.shell, self.transfer, self.output, self.ctx)
        self.assertFalse((self.root / "escaped").exists())
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("component-inventory.json", "{}")
        document["files"] = sources.rows(self.transfer)
        self.put(self.transfer / sources.INDEX, document)
        with self.assertRaisesRegex(ValueError, "embedded-inventory-mismatch"):
            sources.materialize(self.shell, self.transfer, self.root / "other-output", self.ctx)

    def test_failed_producer_never_creates_transfer(self):
        work = self.root / "work"
        with patch.object(sources.candidate.pair, "source"), \
             patch.object(sources.candidate.pair, "git", return_value="false"), \
             patch.object(sources.nexus_process, "run_stage", return_value=7):
            with self.assertRaisesRegex(ValueError, "preparation-nonpass"):
                sources.prepare(self.shell, work, self.ctx)
        self.assertFalse((work / "out").exists())

    def test_cli_refuses_non_main_context_before_creating_work(self):
        environment = {**os.environ, "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "pull_request"}
        result = subprocess.run([sys.executable, "-I", "-B", str(ROOT / "windows/ci/nexus_sources.py"),
                                 "prepare", "--shell", str(self.shell), "--output", str(self.output)],
                                env=environment, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(self.output.exists())

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell privacy boundary")
    def test_source_privacy_gate_rejects_sensitive_metadata_before_upload(self):
        self.export()
        command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                   str(ROOT / "windows/ci/Invoke-NexusSources.ps1"), "-Transfer", str(self.transfer)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.put(self.transfer / "notices/LICENSE.txt", ("ghp_" + "a" * 24).encode())
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("privacy refused", result.stderr)

    def test_workflow_keeps_validation_and_signing_separate_from_source_preparation(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual((ROOT / ".github/workflows/windows-build.yml").read_bytes(),
                         (ROOT / "windows/ci/windows-build.yml.template").read_bytes())
        source_job = workflow.split("\n  sources:\n")[1].split("\n  candidate:\n")[0]
        candidate = workflow.split("\n  candidate:\n")[1].split("\n  publish:\n")[0]
        self.assertIn("needs: [scope]", source_job)
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", source_job)
        self.assertNotIn("secrets.", source_job)
        self.assertNotIn("contents: write", source_job)
        self.assertIn("retention-days: 1", source_job)
        self.assertIn("path: C:/nexus-source-prep/out/", source_job)
        self.assertIn("needs: [scope, pair, validation, sources]", candidate)
        self.assertIn("needs.sources.result == 'success'", candidate)
        self.assertIn("name: ${{ needs.sources.outputs.sources }}", candidate)
        self.assertIn("-PreparedSources C:\\nexus-source-transfer", candidate)
        self.assertIn("needs: [scope, checks, packaging, reuse, fixtures, build, pair]", workflow)
        self.assertNotIn("validation, sources]", workflow.split("\n  validation:\n")[0])


if __name__ == "__main__":
    unittest.main()
