"""Offline regression fixtures. No native process or installed shell access."""
import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("dependencies", ROOT / "windows/release/dependencies.py")
deps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deps)


class Dependencies(unittest.TestCase):
    def setUp(self):
        self.inventory = deps.read(ROOT / deps.INVENTORY)
        self.exceptions = deps.read(ROOT / deps.EXCEPTIONS)
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, extra=None, unknown=False):
        payload = {"payload/qs.exe": b"offline fixture, never executed"}
        if unknown:
            payload["payload/unknown.dll"] = b"unreviewed"
        files = [{"path": p, "sha256": deps.sha(b), "size": len(b)} for p, b in payload.items()]
        known = {c["id"]: c for c in self.inventory["components"]}
        receipt = {
            "releaseId": "fixture", "sourceRevision": "a" * 40, "qtVersion": known["qt"]["version"],
            "dependencies": {"quickshell": {"revision": known["backend"]["version"]},
                             "m3shapes": {"revision": known["m3shapes"]["version"]}},
            "files": files,
        }
        receipt_bytes = json.dumps(receipt).encode()
        coverage = {
            "schema": "caelestia-component-inventory", "version": 1, "sourceRevision": "a" * 40,
            "components": [{"id": "backend", "source": known["backend"]["source"],
                            "version": known["backend"]["version"]},
                           {"id": "pillow", "source": known["pillow"]["source"], "version": known["pillow"]["version"]}],
            "application": {"manifestSha256": deps.sha(receipt_bytes),
                            "files": [dict(files[0], component="backend")]},
        }
        package = self.root / "package.zip"
        with zipfile.ZipFile(package, "w") as archive:
            archive.writestr("fixture/release.json", receipt_bytes)
            for path, value in payload.items():
                archive.writestr("fixture/" + path, value)
            if extra:
                archive.writestr("fixture/" + extra, b"extra")
        path = self.root / "coverage.json"
        deps.write(path, coverage)
        return package, path

    def test_inventory_matches_all_owned_inputs(self):
        self.assertEqual(self.inventory, deps.generate_inventory(previous=self.inventory))

    def test_lock_graph_versions_checksums_and_edges_are_exact(self):
        lock = deps.tomllib.loads((ROOT / "windows/capture/Cargo.lock").read_text())
        expected = {deps.crate_id(p): p for p in lock["package"] if "source" in p}
        actual = {c["id"]: c for c in self.inventory["components"] if c["id"].startswith("crate-")}
        self.assertEqual(set(expected), set(actual))
        for key, package in expected.items():
            self.assertEqual(package["version"], actual[key]["version"])
            self.assertEqual(package["checksum"], actual[key]["sourceSha256"])
            self.assertEqual(package.get("dependencies", []), actual[key]["dependencies"])
            self.assertTrue(actual[key]["license"])

    def test_toolchain_drift_requires_inventory_refresh(self):
        changed = copy.deepcopy(self.inventory)
        next(c for c in changed["components"] if c["id"] == "qt")["version"] = "0.0.0"
        self.assertNotEqual(changed, deps.generate_inventory(previous=changed))
        changed["inputs"]["windows/toolchain.json"] = "0" * 64
        self.assertNotEqual(changed, deps.generate_inventory(previous=changed))

    def test_sbom_hashes_every_file_and_omits_absent_optional_packages(self):
        package, coverage = self.fixture()
        bom = deps.release_sbom(package, coverage, self.inventory)
        self.assertEqual(("CycloneDX", "1.6"), (bom["bomFormat"], bom["specVersion"]))
        components = {c["bom-ref"]: c for c in bom["components"]}
        self.assertNotIn("pillow", components)
        self.assertIn("release.json", components)
        self.assertEqual(deps.sha(b"offline fixture, never executed"),
                         components["file:payload/qs.exe"]["hashes"][0]["content"])
        self.assertIn({"ref": "file:payload/qs.exe", "dependsOn": ["backend"]}, bom["dependencies"])

    def test_unknown_receipted_file_fails(self):
        package, coverage = self.fixture(unknown=True)
        with self.assertRaisesRegex(ValueError, "Unknown packaged file"):
            deps.release_sbom(package, coverage, self.inventory)

    def test_unreceipted_zip_file_fails(self):
        # Enabling crash handling uses inbox dbghelp.dll, not a new payload.
        for name in ("unknown.dll", "dbghelp.dll"):
            with self.subTest(name=name):
                package, coverage = self.fixture(extra="payload/" + name)
                with self.assertRaisesRegex(ValueError, "Unknown packaged file"):
                    deps.release_sbom(package, coverage, self.inventory)

    def test_tampered_payload_and_receipt_fail(self):
        package, coverage = self.fixture()
        with zipfile.ZipFile(package) as archive:
            members = {i: archive.read(i) for i in archive.namelist()}
        for member in members:
            with self.subTest(member=member):
                with zipfile.ZipFile(package, "w") as archive:
                    for name, value in members.items():
                        archive.writestr(name, value + b"tamper" if member == name else value)
                with self.assertRaisesRegex(ValueError, "hash mismatch"):
                    deps.release_sbom(package, coverage, self.inventory)

    def test_current_pin_check_cannot_silently_describe_historical_qt(self):
        package, coverage = self.fixture()
        changed = copy.deepcopy(self.inventory)
        next(c for c in changed["components"] if c["id"] == "qt")["version"] = "0.0.0"
        with self.assertRaisesRegex(ValueError, "Package Qt differs"):
            deps.release_sbom(package, coverage, changed)
        self.assertEqual("1.6", deps.release_sbom(package, coverage, changed, historical=True)["specVersion"])

    def test_reviewed_exceptions_are_current_and_expiry_is_required(self):
        deps.validate_exceptions(self.exceptions, self.inventory, today=dt.date(2026, 11, 12))
        for index in range(len(self.exceptions["exceptions"])):
            changed = copy.deepcopy(self.exceptions)
            changed["exceptions"][index]["revisitDate"] = "2000-01-01"
            with self.assertRaisesRegex(ValueError, "Expired exception"):
                deps.validate_exceptions(changed, self.inventory, today=dt.date(2026, 11, 12))
        mitigated = next(e for e in self.exceptions["exceptions"] if e["applicability"] == "accepted-mitigated")
        # Validation fails once the revisit date has passed.
        with self.assertRaisesRegex(ValueError, "Expired exception"):
            deps.validate_exceptions(self.exceptions, self.inventory,
                                     today=dt.date.fromisoformat(mitigated["revisitDate"]) + dt.timedelta(days=1))
        for field in ("owner", "reason", "source"):
            changed = copy.deepcopy(self.exceptions)
            changed["exceptions"][0][field] = ""
            with self.assertRaisesRegex(ValueError, "Missing exception"):
                deps.validate_exceptions(changed, self.inventory, today=dt.date(2026, 11, 12))

    def test_accepted_mitigated_requires_reason_mitigation_and_must_not_claim_patched(self):
        mitigated = next(e for e in self.exceptions["exceptions"] if e["id"] == "CVE-2026-116337")
        self.assertEqual("accepted-mitigated", mitigated["applicability"])
        self.assertEqual("2026-12-10", mitigated["revisitDate"])
        changed = copy.deepcopy(self.exceptions)
        target = next(e for e in changed["exceptions"] if e["id"] == "CVE-2026-116337")
        target["mitigation"] = ""
        with self.assertRaisesRegex(ValueError, "Missing exception mitigation"):
            deps.validate_exceptions(changed, self.inventory, today=dt.date(2026, 11, 12))
        changed = copy.deepcopy(self.exceptions)
        target = next(e for e in changed["exceptions"] if e["id"] == "CVE-2026-116337")
        target["reason"] = ""
        with self.assertRaisesRegex(ValueError, "Missing exception review information"):
            deps.validate_exceptions(changed, self.inventory, today=dt.date(2026, 11, 12))
        changed = copy.deepcopy(self.exceptions)
        target = next(e for e in changed["exceptions"] if e["id"] == "CVE-2026-116337")
        target["patchedVersions"] = ["6.11.3"]
        with self.assertRaisesRegex(ValueError, "must not claim patched"):
            deps.validate_exceptions(changed, self.inventory, today=dt.date(2026, 11, 12))

    def audit_fixture(self, vulnerable=False):
        # Known vulnerable windows 0.31 fixture, not an assertion about the
        # current resolved windows 0.62.2 or an execution of a RustSec scan.
        package = deps.tomllib.loads((ROOT / "windows/tests/fixtures/dependencies/vulnerable.Cargo.lock").read_text())["package"][0]
        self.assertEqual(("windows", "0.31.0"), (package["name"], package["version"]))
        self.vulnerable_inventory = copy.deepcopy(self.inventory)
        self.vulnerable_inventory["components"].append({
            "id": deps.crate_id(package), "version": package["version"], "classification": "runtime payload"})
        findings = [{"advisory": {"id": "RUSTSEC-2022-0008"},
                     "package": package}] if vulnerable else []
        return {
            "database": {"last-commit": "a" * 40, "last-updated": dt.date.today().isoformat() + "T00:00:00Z"},
            "vulnerabilities": {"count": len(findings), "list": findings}, "warnings": {},
        }

    def test_controlled_vulnerable_version_fails_policy(self):
        report = self.audit_fixture(True)
        with self.assertRaisesRegex(ValueError, "RUSTSEC-2022-0008"):
            deps.check_audit(report, self.exceptions, self.vulnerable_inventory, 1)
        # Scanner exit status must not hide a finding.
        with self.assertRaisesRegex(ValueError, "RUSTSEC-2022-0008"):
            deps.check_audit(report, self.exceptions, self.vulnerable_inventory, 0)

    def test_audit_accepts_only_exact_unexpired_review(self):
        report = self.audit_fixture(True)
        self.exceptions["exceptions"].append({
            "id": "RUSTSEC-2022-0008", "component": "crate-windows-0.31.0", "reviewedVersion": "0.31.0",
            "applicability": "accepted-temporary", "owner": "Fixture", "reason": "Controlled offline fixture",
            "source": "https://rustsec.org/advisories/RUSTSEC-2022-0008.html",
            "revisitDate": (dt.date.today() + dt.timedelta(days=1)).isoformat(),
        })
        deps.check_audit(report, self.exceptions, self.vulnerable_inventory, 1)
        self.exceptions["exceptions"][-1]["reviewedVersion"] = "0.37.0"
        with self.assertRaisesRegex(ValueError, "requires version review"):
            deps.check_audit(report, self.exceptions, self.vulnerable_inventory, 1)

    def test_scanner_fixture_entrypoint_checks_the_real_command_and_unsound_warning(self):
        report = self.audit_fixture(True)
        report["warnings"]["unsound"] = report["vulnerabilities"]["list"]
        report["vulnerabilities"] = {"count": 0, "list": []}
        arguments = ["dependencies.py", "scanner-fixture", "--cargo-audit", "fixture-scanner",
                     "--output", str(self.root / "audit.json")]
        with mock.patch.object(deps.sys, "argv", arguments):
            with mock.patch.object(deps.subprocess, "run", return_value=SimpleNamespace(
                    returncode=0, stdout=json.dumps(report), stderr="")) as scanner:
                deps.main()
                command = scanner.call_args.args[0]
                self.assertEqual(["fixture-scanner", "audit", "--json", "--file"], command[:4])
                self.assertTrue(command[4].endswith("vulnerable.Cargo.lock"))
            with mock.patch.object(deps.subprocess, "run", return_value=SimpleNamespace(
                    returncode=0, stdout=json.dumps(self.audit_fixture()), stderr="")):
                with self.assertRaisesRegex(ValueError, "did not trigger"):
                    deps.main()

    def test_unavailable_stale_filtered_or_failed_audit_never_passes(self):
        clean = self.audit_fixture()
        deps.check_audit(clean, self.exceptions, self.inventory)
        for report in ({}, dict(clean, error="network failure"),
                       dict(clean, database={}),
                       dict(clean, database={"last-commit": "a", "last-updated": "2000-01-01"}),
                       dict(clean, settings={"ignore": ["RUSTSEC-2022-0008"]})):
            with self.subTest(report=report), self.assertRaises(ValueError):
                deps.check_audit(report, self.exceptions, self.inventory)
        with self.assertRaisesRegex(ValueError, "unavailable"):
            deps.check_audit(clean, self.exceptions, self.inventory, 2)

    def test_workflow_keeps_scanning_outside_required_windows_gate(self):
        workflow = (ROOT / ".github/workflows/dependency-advisories.yml").read_text()
        self.assertIn("cron:", workflow)
        self.assertIn("pull_request:", workflow)
        self.assertIn("sha256sum --check --strict", workflow)
        self.assertIn("dependencies.py scanner-fixture", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn(": write", workflow)
        self.assertNotIn("actions/cache/save", workflow)
        build = (ROOT / ".github/workflows/windows-build.yml").read_bytes()
        self.assertEqual(build, (ROOT / "windows/ci/windows-build.yml.template").read_bytes())
        text = build.decode().replace("\r\n", "\n")
        self.assertGreater(text.index("Retain release SBOM and receipt"), text.index("id: candidate\n"))
        self.assertIn("name: release-sbom-${{ github.run_id }}-${{ github.run_attempt }}", text)
        self.assertIn("--receipt-output", workflow)
        self.assertIn("advisory-result.json", workflow)

    def test_advisory_receipt_verification_and_freshness_policy(self):
        report = self.audit_fixture()
        cargo_lock_sha = deps.sha((ROOT / "windows/capture/Cargo.lock").read_bytes())
        now = dt.datetime(2026, 11, 12, 12, 0, 0, tzinfo=dt.timezone.utc)
        receipt = deps.advisory_receipt(report, self.exceptions, self.inventory, cargo_lock_sha, checked_at=now)
        deps.verify_advisory_result(receipt, self.inventory, self.exceptions, cargo_lock_sha, now=now + dt.timedelta(days=7))
        # Stale (> 7 days) fails.
        with self.assertRaisesRegex(ValueError, "stale"):
            deps.verify_advisory_result(
                receipt, self.inventory, self.exceptions, cargo_lock_sha,
                now=now + dt.timedelta(days=7, seconds=1))
        # Missing or non-pass fails.
        with self.assertRaisesRegex(ValueError, "missing"):
            deps.verify_advisory_result(None, self.inventory, self.exceptions, cargo_lock_sha, now=now)
        bad = dict(receipt, result="fail")
        with self.assertRaisesRegex(ValueError, "did not pass"):
            deps.verify_advisory_result(bad, self.inventory, self.exceptions, cargo_lock_sha, now=now)
        # Inventory, Cargo.lock, or exceptions drift fails.
        for field in ("inventorySha256", "cargoLockSha256", "exceptionsSha256"):
            drifted = dict(receipt)
            drifted[field] = "0" * 64
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "hash does not match"):
                deps.verify_advisory_result(drifted, self.inventory, self.exceptions, cargo_lock_sha, now=now)

    def test_lock_digest_is_the_same_for_lf_and_crlf_checkouts(self):
        # The advisory job runs on Linux (LF) and the publisher on Windows
        # (CRLF under autocrlf). Both must produce one lockfile identity.
        with tempfile.TemporaryDirectory() as directory:
            lf, crlf = Path(directory) / "lf.lock", Path(directory) / "crlf.lock"
            lf.write_bytes(b"version = 4\n\n[[package]]\nname = \"a\"\n")
            crlf.write_bytes(b"version = 4\r\n\r\n[[package]]\r\nname = \"a\"\r\n")
            self.assertEqual(deps.lock_digest(lf), deps.lock_digest(crlf))
            self.assertEqual(deps.lock_digest(lf), deps.sha(lf.read_bytes()))


if __name__ == "__main__":
    unittest.main()
