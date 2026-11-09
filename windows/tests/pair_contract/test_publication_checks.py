"""Publisher scheduling controls. No network, signing or artifact code runs."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "windows/ci"))
import nexus_publish as n


class PublicationCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="publication-checks-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shell, self.directory, self.work = [self.root / name for name in ("shell", "candidate", "work")]
        for path in (self.shell / "windows/release", self.directory, self.work):
            path.mkdir(parents=True)
        n.write(self.shell / "windows/release/version.json", {"version": "0.2.0", "developmentEpoch": 1})
        self.doc = {"release": {"buildVersion": "0.2.0-dev.1.5.1"}}
        n.write(self.directory / "candidate.json", self.doc)
        self.inventory = {"projects": [{"revision": "a" * 40, "sha256": "b" * 64}],
                          "notices": [{"path": "notice.txt", "sha256": "c" * 64}]}
        n.write(self.directory / "source-assets-inventory.json", self.inventory)
        self.ctx = {"sha": "a" * 40, "runNumber": "5", "runAttempt": "1"}

    def run_checks(self, fail=None, mismatch=False):
        barrier = threading.Barrier(2, timeout=5)
        self.calls, self.finished = {}, set()
        output = io.StringIO()

        def command(args, **kwargs):
            script = Path(args[4]).name
            phase = {"Prepare-CaelestiaSourceAssets.ps1": "sources",
                     "Test-NexusCandidatePayload.ps1": "payload"}[script]
            self.calls[phase] = (args, kwargs)
            # A serial implementation cannot pass this rendezvous.
            barrier.wait()
            try:
                if fail == phase:
                    raise ValueError("fixture-" + phase + "-failed")
                if phase == "sources":
                    inventory = copy.deepcopy(self.inventory)
                    inventory["projects"][0]["sha256"] = "d" * 64  # Legal Git bundle repack.
                    if mismatch:
                        inventory["notices"][0]["sha256"] = "e" * 64
                    fresh = self.work / "independent-source-assets"
                    fresh.mkdir()
                    n.write(fresh / "component-inventory.json", inventory)
            finally:
                self.finished.add(phase)

        with patch.object(n.candidate, "verify_receipt", return_value=({}, {})), \
                patch.object(n.pair, "git", return_value="false"), \
                patch.object(n, "extract_source", side_effect=lambda archive, target: target.mkdir()), \
                patch.object(n, "checked_run", side_effect=command), contextlib.redirect_stdout(output):
            try:
                return n.verify_payload(self.shell, self.directory, self.work, self.ctx, "validator")
            finally:
                self.output = output.getvalue()

    def assert_timings(self, failed=None):
        rows = json.loads((self.work / "publication-checks-timing.json").read_text())["phases"]
        self.assertEqual(["payload", "sources"], [row["phase"] for row in rows])
        for row in rows:
            self.assertEqual({"phase", "outcome", "seconds"}, set(row))
            self.assertEqual("failure" if row["phase"] == failed else "success", row["outcome"])
            self.assertGreaterEqual(row["seconds"], 0)
        self.assertNotIn(str(self.root), self.output)
        self.assertEqual(2, self.output.count("NEXUS_PUBLICATION_TIMING "))

    def test_both_checks_overlap_and_keep_separate_paths_and_deadlines(self):
        self.assertEqual(self.doc, self.run_checks())
        self.assertEqual({"sources", "payload"}, self.finished)
        source_args, source_options = self.calls["sources"]
        payload_args, payload_options = self.calls["payload"]
        self.assertEqual(3600, source_options["timeout"])
        self.assertEqual(600, payload_options["timeout"])
        self.assertNotEqual(source_options["diagnostic_log"], payload_options["diagnostic_log"])
        self.assertEqual(self.work / "independent-source-assets",
                         source_args[source_args.index("-OutputDirectory") + 1])
        self.assertEqual(self.work / "payload-check",
                         payload_args[payload_args.index("-OutputDirectory") + 1])
        self.assertEqual(self.work / "source-assets", payload_args[payload_args.index("-AssetsRoot") + 1])
        self.assert_timings()

    def test_source_failure_still_waits_for_payload_and_refuses_success(self):
        with self.assertRaisesRegex(ValueError, "fixture-sources-failed"):
            self.run_checks(fail="sources")
        self.assertEqual({"sources", "payload"}, self.finished)
        self.assert_timings(failed="sources")

    def test_payload_failure_still_waits_for_sources_and_refuses_success(self):
        with self.assertRaisesRegex(ValueError, "fixture-payload-failed"):
            self.run_checks(fail="payload")
        self.assertEqual({"sources", "payload"}, self.finished)
        self.assert_timings(failed="payload")

    def test_reproduced_inventory_mismatch_is_not_hidden_by_payload_success(self):
        with self.assertRaisesRegex(ValueError, "independent-source-notice-reproduction-mismatch"):
            self.run_checks(mismatch=True)
        self.assertEqual({"sources", "payload"}, self.finished)
        self.assert_timings(failed="sources")

    def test_receipt_failure_starts_neither_check(self):
        with patch.object(n.candidate, "verify_receipt", side_effect=ValueError("receipt-refused")), \
                patch.object(n, "checked_run") as command, patch.object(n, "extract_source") as extract:
            with self.assertRaisesRegex(ValueError, "receipt-refused"):
                n.verify_payload(self.shell, self.directory, self.work, self.ctx, "validator")
        command.assert_not_called()
        extract.assert_not_called()
        self.assertEqual([], list(self.work.iterdir()))

    def test_timing_upload_is_separate_from_release_assets(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_bytes()
        self.assertEqual(workflow, (ROOT / "windows/ci/windows-build.yml.template").read_bytes())
        block = workflow.decode().split("name: nexus-publication-timings-", 1)[1].split("\n\n", 1)[0]
        self.assertIn("C:/nexus-publish/payload-check/verification-timing.json", block)
        self.assertIn("C:/nexus-publish/publication-checks-timing.json", block)
        self.assertNotIn(".log", block)
        paths = [line.strip() for line in block.splitlines() if line.strip().startswith("C:/")]
        self.assertEqual(["C:/nexus-publish/payload-check/verification-timing.json",
                          "C:/nexus-publish/publication-checks-timing.json"], paths)
        self.assertNotIn("publication-checks-timing.json", n.EVIDENCE)


if __name__ == "__main__":
    unittest.main()
