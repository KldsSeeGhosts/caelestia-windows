"""Synthetic identities and command reports. No network or native acceptance."""

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("pair_result", ROOT / "windows/ci/pair_result.py")
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)


def run_git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL).decode().strip()


class PairTests(unittest.TestCase):
    def setUp(self):
        parent = os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT")
        self.temp = tempfile.TemporaryDirectory(prefix="pair-contract-", dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shell = self.root / "shell"
        self.backend = self.shell / "windows/deps/quickshell"
        self.backend.mkdir(parents=True)
        for root, key in ((self.backend, "backend"), (self.shell, "shell")):
            run_git(root, "init", "--quiet")
            run_git(root, "remote", "add", "origin", "https://github.com/" + p.REPOS[key])
        (self.backend / "source.txt").write_text("fixture")
        self.commit(self.backend)
        self.backend_sha = run_git(self.backend, "rev-parse", "HEAD")
        run_git(self.backend, "update-ref", "refs/remotes/origin/main", self.backend_sha)
        self.put("windows/sources.lock.json", {"quickshell": {
            "revision": self.backend_sha, "repository": "https://github.com/" + p.REPOS["backend"]},
            "m3shapes": {"revision": "d" * 40}, "glazier": {
                "revision": "e" * 40, "originRevision": "e" * 40,
                "representation": "in-tree", "sourceRevision": "shell",
                "path": "windows/capture", "cargoLockPath": "windows/capture/Cargo.lock",
                "cargoLockSha256": hashlib.sha256(b"synthetic capture lock\n").hexdigest(),
                "executable": "caelestia-capture.exe"}})
        (self.shell / "windows/capture").mkdir()
        (self.shell / "windows/capture/Cargo.lock").write_bytes(b"synthetic capture lock\n")
        self.put("windows/toolchain.json", {"id": "synthetic"})
        self.put("windows/ci/pair-contract.json", {})
        self.put("windows/ci/Invoke-PairIntegration.ps1", {})
        self.put("windows/toolchain/python-bootstrap.lock.txt", {})
        self.put("windows/toolchain/python-tools.lock.txt", {})
        run_git(self.shell, "add", "windows")
        run_git(self.shell, "update-index", "--add", "--cacheinfo",
                "160000," + self.backend_sha + ",windows/deps/quickshell")
        self.commit(self.shell)
        self.sha = run_git(self.shell, "rev-parse", "HEAD")
        self.args = argparse.Namespace(mode="pinned", backend_sha="", shell_sha=self.sha,
            shell=str(self.shell), candidate_root=str(self.root / "candidate"),
            results=str(self.root / "results"), github_output="")
        self.real_git = p.git

    def put(self, name, value):
        p.write(self.shell / name, value)

    def commit(self, root):
        run_git(root, "add", "--all")
        run_git(root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "commit", "--quiet", "-m", "synthetic")

    def git_without_network(self, root, *args):
        if args[0] == "fetch":
            return ""
        return self.real_git(root, *args)

    def resolve(self):
        with patch.object(p, "git", side_effect=self.git_without_network):
            p.resolve(self.args)
        return p.read(Path(self.args.results) / "pair-request.json")

    def rejected(self, reason):
        with self.assertRaisesRegex(ValueError, reason):
            self.resolve()
        request = p.read(Path(self.args.results) / "pair-request.json")
        self.assertEqual("refused", request["status"])

    def test_pinned_exact_clean_pair(self):
        request = self.resolve()
        self.assertEqual(request["backend"], self.backend_sha)
        self.assertTrue(request["onBackendMain"])
        self.assertEqual("resolved", request["status"])
        self.assertNotIn(str(self.root), json.dumps(request))

    def test_short_shell(self):
        self.args.shell_sha = "abcdef"
        self.rejected("immutable-shell")

    def test_branch_shell(self):
        self.args.shell_sha = "main"
        self.rejected("immutable-shell")

    def test_uppercase_shell(self):
        self.args.shell_sha = "A" * 40
        self.rejected("immutable-shell")

    def test_resolved_shell_mismatch(self):
        self.args.shell_sha = "a" * 40
        self.rejected("resolved-sha")

    def test_missing_candidate(self):
        self.args.mode = "candidate"
        self.rejected("candidate-sha-required")

    def test_silent_override(self):
        self.args.backend_sha = self.backend_sha
        self.rejected("requires-candidate-mode")

    def test_dirty_shell(self):
        self.put("untracked.json", {})
        self.rejected("dirty-source")

    def test_incompatible_shell(self):
        (self.shell / "windows/ci/pair-contract.json").unlink()
        self.rejected("incompatible-shell")

    def test_pin_disagreement(self):
        self.put("windows/sources.lock.json", {"quickshell": {
            "revision": "f" * 40, "repository": "https://github.com/" + p.REPOS["backend"]}})
        self.commit(self.shell)
        self.args.shell_sha = run_git(self.shell, "rev-parse", "HEAD")
        self.rejected("gitlink-lock")

    def test_backend_not_on_main(self):
        run_git(self.backend, "update-ref", "-d", "refs/remotes/origin/main")
        self.rejected("ancestry-unverified")

    def test_candidate_must_be_outside(self):
        self.args.mode = "candidate"
        self.args.backend_sha = self.backend_sha
        self.args.candidate_root = str(self.shell / "candidate")
        self.rejected("candidate-root-must-be-separate")

    def test_missing_candidate_commit(self):
        self.args.mode, self.args.backend_sha = "candidate", "a" * 40
        def fake(root, *args):
            if args[0] == "fetch":
                raise ValueError("git-operation-failed")
            return self.real_git(root, *args)
        with patch.object(p, "git", side_effect=fake):
            with self.assertRaisesRegex(ValueError, "backend-commit-not-found"):
                p.resolve(self.args)

    def test_candidate_same_sha_still_explicit(self):
        self.args.mode, self.args.backend_sha = "candidate", self.backend_sha
        def fake(root, *args):
            root = Path(root)
            if args[0] == "fetch":
                # Local fixture object transfer, no URL request.
                run_git(root, "fetch", "--quiet", str(self.backend), self.backend_sha)
                run_git(root, "update-ref", "refs/remotes/origin/main", self.backend_sha)
                return ""
            return self.real_git(root, *args)
        with patch.object(p, "git", side_effect=fake):
            p.resolve(self.args)
        self.assertEqual("candidate", p.read(Path(self.args.results) / "pair-request.json")["mode"])
        self.assertFalse(run_git(self.shell, "status", "--porcelain"))

    def test_wrong_repository(self):
        run_git(self.shell, "remote", "set-url", "origin", "https://example.invalid/wrong")
        self.rejected("noncanonical-repository")

    def test_empty_and_failed_integration_report(self):
        results = self.root / "reports"
        journal = [{"name": name, "outcome": "not_run", "exitCode": None, "durationSeconds": None}
                   for name in p.GATES]
        journal[0].update(outcome="failure", exitCode=1, durationSeconds=0.1)
        p.write(results / "integration-stages.json", journal)
        p.integration_report(results, results / "raw.xml")
        tree = ET.parse(results / "raw.xml")
        self.assertEqual(1, len(list(tree.iter("failure"))))
        self.assertEqual(5, len(list(tree.iter("skipped"))))

    def test_validator_digest_before_import(self):
        script = self.root / "malicious.py"
        script.write_text("raise AssertionError('must not import')")
        with self.assertRaisesRegex(ValueError, "trusted-validator-digest"):
            p.validator(script, {"validatorSha256": "0" * 64})

    def ps(self, name, *args):
        return subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                               str(ROOT / "windows/scripts" / name), *map(str, args)],
                              capture_output=True, text=True)

    def test_executable_release_candidate_and_legacy_refusal(self):
        build = self.root / "build"
        scripts = self.shell / "windows/scripts"
        scripts.mkdir(parents=True)
        for name in ("New-CaelestiaRelease.ps1", "Caelestia-InstallCommon.ps1",
                     "Caelestia-Versions.ps1", "Caelestia-Toolchain.ps1"):
            shutil.copyfile(ROOT / "windows/scripts" / name, scripts / name)
        self.commit(self.shell)
        notices = self.root / "notices"
        notices.mkdir()
        (notices / "NOTICE.txt").write_text("synthetic supplier notice")
        for receipt in ({"backendMode": "candidate"}, {}):
            p.write(build / "logs/build.json", receipt)
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                                     str(scripts / "New-CaelestiaRelease.ps1"), "-BuildRoot", str(build),
                                     "-ReleaseId", "fixture", "-OutputDirectory", str(self.root / "never-created"),
                                     "-SupplementalNoticesRoot", str(notices)], capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("Release assembly requires a pinned build", result.stderr)
            self.assertFalse((self.root / "never-created").exists())

    def test_executable_candidate_build_requires_both_inputs(self):
        result = self.ps("Build-Prototype.ps1", "-QtPrefix", self.root, "-LlvmBin", self.root,
                         "-Cli11Include", self.root, "-BackendRoot", self.backend)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("must be supplied together", result.stderr)

    def test_powershell_wrapper_omits_empty_native_argument(self):
        results = self.root / "wrapper-results"
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
            str(ROOT / "windows/ci/Resolve-PairRequest.ps1"), "-Mode", "pinned",
            "-ShellSha", "f" * 40, "-ShellRoot", str(self.shell), "-CandidateRoot",
            str(self.root / "candidate"), "-Results", str(results)], capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("resolved-sha-mismatch", p.read(results / "pair-request.json")["reason"])
        self.assertIn("resolved-sha-mismatch", result.stderr)

    def test_executable_smoke_explicit_candidate_guard(self):
        build, qt = self.root / "build", self.root / "qt"
        files = ("quickshell/qs.exe", "install/qml/Caelestia/Config/qmldir",
                 "install/qml/Caelestia/Windows/qmldir", "install/qml/M3Shapes/qmldir",
                 "install/qml/Caelestia/caelestia-coreplugin.dll",
                 "install/qml/Caelestia/Config/caelestia-configplugin.dll",
                 "install/qml/Caelestia/Windows/caelestia-windowsplugin.dll",
                 "install/qml/M3Shapes/m3shapesplugin.dll")
        for name in files:
            path = build / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        for name in ("bin/qtpaths.exe", "bin/Qt6Core.dll"):
            path = qt / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        pin = p.read(ROOT / "windows/sources.lock.json")["quickshell"]["revision"]
        receipt = {"backendMode": "candidate", "backendRevision": "a" * 40,
                   "pinnedBackendRevision": pin, "lockBackendRevision": pin}
        p.write(build / "logs/build.json", receipt)
        for extra in ((), ("-CandidateBackendRevision", "b" * 40)):
            result = self.ps("Test-Smoke.ps1", "-BuildRoot", build, "-QtPrefix", qt,
                             "-RunRoot", self.root / "runs", *extra)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("Candidate smoke requires the explicit exact candidate SHA", result.stdout)
        receipt["backendMode"] = "pinned"
        p.write(build / "logs/build.json", receipt)
        result = self.ps("Test-Smoke.ps1", "-BuildRoot", build, "-QtPrefix", qt,
                         "-RunRoot", self.root / "runs", "-CandidateBackendRevision", "a" * 40)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("requires a candidate build receipt", result.stdout)

    def test_missing_plugin_report_and_invalid_journal_refused(self):
        results = self.root / "journal"
        journal = [{"name": name, "outcome": "success", "exitCode": 0, "durationSeconds": 0.1}
                   for name in p.GATES]
        p.write(results / "integration-stages.json", journal)
        with self.assertRaisesRegex(ValueError, "plugin-report-missing"):
            p.integration_report(results, results / "raw.xml")
        journal[0]["name"] = "C:/Users/private"
        p.write(results / "integration-stages.json", journal)
        with self.assertRaisesRegex(ValueError, "stage-set-mismatch"):
            p.safe_journal(results)

    def test_trusted_blob_extracted_and_wrong_digest_refused(self):
        helper = ".github/scripts/candidate_contract.py"
        for name, content in (
                (helper, "def validate(receipt): pass\n"),
                (".github/scripts/Invoke-WindowsFixtureGate.ps1", "# synthetic\n"),
                (".github/candidate-contract/test_candidate_contract.py", "# synthetic\n")):
            path = self.backend / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.commit(self.backend)
        revision = run_git(self.backend, "rev-parse", "HEAD")
        blob = subprocess.check_output(["git", "-C", str(self.backend), "show", revision + ":" + helper])
        contract = {"schemaVersion": 1, "contractSchemaVersion": 1,
                    "producerRepository": p.REPOS["backend"], "producerRevision": revision,
                    "validatorPath": helper, "validatorSha256": hashlib.sha256(blob).hexdigest()}
        self.put("windows/ci/pair-contract.json", contract)
        with patch.object(p, "git", side_effect=self.git_without_network):
            p.bootstrap(self.shell, self.backend, self.root / "trusted")
        self.assertEqual(blob, (self.root / "trusted" / helper).read_bytes())
        contract["validatorSha256"] = "0" * 64
        self.put("windows/ci/pair-contract.json", contract)
        with patch.object(p, "git", side_effect=self.git_without_network):
            with self.assertRaisesRegex(ValueError, "trusted-validator-digest"):
                p.bootstrap(self.shell, self.backend, self.root / "refused")
        self.assertFalse((self.root / "refused").exists())

    def envelope_fixture(self):
        request = self.resolve()
        results = Path(self.args.results)
        contract = {"producerRevision": "a" * 40, "validatorSha256": "b" * 64}
        self.put("windows/ci/pair-contract.json", contract)
        receipt = {"kind": "downstream", "result": "pass",
                   "sources": {key: {"requested": request[key], "resolved": request[key]}
                               for key in p.REPOS},
                   "toolchain": {"specSha256": request["specSha256"],
                                 "contractSha256": request["contractSha256"],
                                 "actual": {"contractSha256": request["contractSha256"], "qtVersion": "6.11.2"}},
                   "tests": {"integration": {"total": 7, "executed": 7, "failed": 0,
                                             "skipped": 0, "skips": []}},
                   "stages": {name: {"outcome": "success", "exitCode": 0, "durationSeconds": 0.01}
                              for name in ("sources", "producer", "prepare", "configure",
                                           "build", "portable", "integration")}}
        p.write(results / "candidate-result.json", receipt)
        p.write(results / "integration-stages.json", [
            {"name": name, "outcome": "success", "exitCode": 0, "durationSeconds": 0.02}
            for name in p.GATES])
        (results / "plugins.raw.xml").write_text('<testsuite><testcase name="synthetic"/></testsuite>')
        for suite in ("Services", "Shell"):
            p.write(results / suite / "summary.json",
                    {"passed": True, "results": [{"name": "synthetic", "exitCode": 0}]})
            (results / suite / "synthetic.log").write_text('{"assertions": 12}')
        args = argparse.Namespace(results=str(results), shell=str(self.shell), validator="unused",
            build_root=str(self.root / "build"),
            workflow_outcome="success", event="push", ref="refs/heads/main", run_id="123",
            attempt="1", workflow_sha=self.sha)
        p.write(Path(args.build_root) / "logs/build.json", {
            "backendMode": "pinned", "backendRevision": request["backend"],
            "sourceRevision": request["shell"], "pinnedBackendRevision": request["gitlinkBackend"],
            "lockBackendRevision": request["lockBackend"], "sourceDirty": False,
            "publicRelease": True, "pluginTests": True, "glazierBundled": True,
            "captureBundled": True, "captureSourceRevision": request["shell"],
            "captureSourcePath": "windows/capture", "captureOriginRevision": "e" * 40,
            "captureCargoLockSha256": hashlib.sha256(b"synthetic capture lock\n").hexdigest(),
            "captureExecutable": "caelestia-capture.exe",
            "captureSha256": hashlib.sha256(b"synthetic capture binary").hexdigest(),
            "m3shapesRevision": "d" * 40, "glazierRevision": "e" * 40, "glazierSha256": "f" * 64,
            "toolchain": {"contractSha256": request["contractSha256"]}})
        capture_exe = Path(args.build_root) / "install/caelestia-capture.exe"
        capture_exe.parent.mkdir(parents=True)
        capture_exe.write_bytes(b"synthetic capture binary")
        def validate(value, **expectations):
            p.require(value["result"] == "pass", "synthetic-validator-nonpass")
        counts = {"total": 1, "executed": 1, "failed": 0, "skipped": 0, "skips": []}
        module = argparse.Namespace(validate=validate, junit=lambda path: (counts, ""))
        return args, module, request, receipt

    def test_final_main_receipt_eligibility_and_preflight_limits(self):
        args, module, request, _ = self.envelope_fixture()
        with patch.object(p, "validator", return_value=module):
            self.assertEqual(0, p.envelope(args))
        path = Path(args.results) / "pair-result.json"
        self.assertTrue(p.read(path)["releaseEligible"])
        for field, value in (("event", "pull_request"), ("workflow_sha", "f" * 40)):
            changed = copy.copy(args)
            setattr(changed, field, value)
            with patch.object(p, "validator", return_value=module):
                self.assertEqual(0, p.envelope(changed))
            self.assertFalse(p.read(path)["releaseEligible"])
        request["mode"] = "candidate"  # Even candidate == pin is ineligible.
        p.write(Path(args.results) / "pair-request.json", request)
        build = p.read(Path(args.build_root) / "logs/build.json")
        build["backendMode"] = "candidate"
        p.write(Path(args.build_root) / "logs/build.json", build)
        with patch.object(p, "validator", return_value=module):
            self.assertEqual(0, p.envelope(args))
        self.assertFalse(p.read(path)["releaseEligible"])
        self.assertIn("candidate-mode", p.read(path)["reasons"])

    def test_cancel_failure_nonpass_and_zero_cannot_be_eligible(self):
        args, module, _, receipt = self.envelope_fixture()
        for outcome in ("failure", "cancelled", "skipped"):
            args.workflow_outcome = outcome
            with patch.object(p, "validator", return_value=module):
                self.assertEqual(1, p.envelope(args))
            result = p.read(Path(args.results) / "pair-result.json")
            self.assertEqual("non-pass", result["result"])
            self.assertFalse(result["releaseEligible"])
        args.workflow_outcome = "success"
        for key, value in (("result", "incomplete"), ("kind", "standalone")):
            changed = copy.deepcopy(receipt)
            changed[key] = value
            p.write(Path(args.results) / "candidate-result.json", changed)
            with patch.object(p, "validator", return_value=module):
                self.assertEqual(1, p.envelope(args))
        receipt["tests"]["integration"]["executed"] = 0
        p.write(Path(args.results) / "candidate-result.json", receipt)
        with patch.object(p, "validator", return_value=module):
            self.assertEqual(1, p.envelope(args))

    def test_actual_built_pair_and_toolchain_checked(self):
        args, _, request, _ = self.envelope_fixture()
        path = Path(args.build_root) / "logs/build.json"
        build = p.read(path)
        p.verify_build(args.build_root, request, self.shell)
        for key, value in (("backendRevision", "f" * 40), ("sourceRevision", "f" * 40),
                           ("backendMode", "candidate"), ("sourceDirty", True),
                           ("captureBundled", False), ("pluginTests", False),
                           ("captureSourceRevision", "f" * 40),
                           ("captureSourcePath", "elsewhere"),
                           ("captureOriginRevision", "f" * 40),
                           ("captureExecutable", "glazier.exe"),
                           ("captureCargoLockSha256", "f" * 64),
                           ("captureSha256", "f" * 64)):
            changed = copy.deepcopy(build)
            changed[key] = value
            p.write(path, changed)
            with self.subTest(key=key), self.assertRaises(ValueError):
                p.verify_build(args.build_root, request, self.shell)
        p.write(path, build)
        capture_exe = Path(args.build_root) / "install/caelestia-capture.exe"
        capture_exe.write_bytes(b"changed binary")
        with self.assertRaisesRegex(ValueError, "built-capture-binary-mismatch"):
            p.verify_build(args.build_root, request, self.shell)
        capture_exe.write_bytes(b"synthetic capture binary")
        (self.shell / "windows/capture/Cargo.lock").write_bytes(b"changed lock")
        with self.assertRaisesRegex(ValueError, "built-capture-source-mismatch"):
            p.verify_build(args.build_root, request, self.shell)
        (self.shell / "windows/capture/Cargo.lock").write_bytes(b"synthetic capture lock\n")
        build["toolchain"]["contractSha256"] = "f" * 64
        p.write(path, build)
        with self.assertRaisesRegex(ValueError, "production-toolchain-digest"):
            p.verify_build(args.build_root, request, self.shell)

    def test_midrun_failure_counts_and_sanitized_envelope(self):
        args, module, _, _ = self.envelope_fixture()
        journal = p.read(Path(args.results) / "integration-stages.json")
        journal[1].update(outcome="failure", exitCode=42)
        p.write(Path(args.results) / "integration-stages.json", journal)
        with patch.object(p, "validator", return_value=module):
            self.assertEqual(1, p.envelope(args))
        text = (Path(args.results) / "pair-result.json").read_text()
        self.assertNotIn(str(self.root), text)
        self.assertIn('"exitCode": 42', text)
        result = json.loads(text)
        self.assertEqual(12, result["suiteCounts"]["services"]["reportedAssertions"])
        self.assertFalse(result["releaseEligible"])

    def test_malformed_plugin_xml_retains_nonpass_envelope(self):
        args, module, _, _ = self.envelope_fixture()
        # Use the real XML parser used by the producer, not the successful
        # fixture's JUnit stub, to exercise truncated CTest output.
        module.junit = lambda path: (p.ET.parse(path), "")
        for xml in ('<testsuite><testcase', '<private-content>'):
            with self.subTest(xml=xml):
                (Path(args.results) / "plugins.raw.xml").write_text(xml)
                with patch.object(p, "validator", return_value=module):
                    self.assertEqual(1, p.envelope(args))
                result = p.read(Path(args.results) / "pair-result.json")
                self.assertEqual("non-pass", result["result"])
                self.assertFalse(result["releaseEligible"])
                self.assertIn("pair-validation-nonpass", result["reasons"])
                self.assertNotIn("private-content", json.dumps(result))

    def test_failed_test_counts_and_skip_sanitization(self):
        counts = p.public_counts({"total": 3, "executed": 2, "failed": 1, "skipped": 1,
                                  "skips": [{"test": "C:/Users/private",
                                             "reason": "private provider content"}]})
        self.assertEqual(1, counts["failed"])
        self.assertEqual(1, counts["skipped"])
        self.assertNotIn("private", json.dumps(counts))
        self.assertEqual("redacted", counts["skips"][0]["test"])

    def test_independent_pair_expectations(self):
        request = self.resolve()
        spec, digest = p.digests(self.shell)
        receipt = {"kind": "downstream", "sources": {
            key: {"requested": request[key], "resolved": request[key]} for key in p.REPOS},
            "toolchain": {"specSha256": spec, "contractSha256": digest},
            "tests": {"integration": {"executed": 1}}}
        calls = []
        module = argparse.Namespace(validate=lambda value, **kwargs: calls.append(kwargs))
        p.verify(receipt, request, self.shell, module)
        self.assertEqual({"kind": "downstream", "backend_sha": request["backend"],
                          "shell_sha": request["shell"], "contract_sha256": digest,
                          "spec_sha256": spec}, calls[0])
        for mutation in ("kind", "pair", "digest", "zero"):
            changed = copy.deepcopy(receipt)
            if mutation == "kind":
                changed["kind"] = "standalone"
            elif mutation == "pair":
                changed["sources"]["shell"]["resolved"] = "e" * 40
            elif mutation == "digest":
                changed["toolchain"]["contractSha256"] = "e" * 64
            else:
                changed["tests"]["integration"]["executed"] = 0
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                p.verify(changed, request, self.shell, module)

    def test_workflow_and_release_boundaries(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual(workflow, (ROOT / "windows/ci/windows-build.yml.template").read_text())
        self.assertIn("github.event_name == 'push'", workflow)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)
        self.assertIn("|| github.run_id", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("pull_request_target", workflow)
        release = (ROOT / "windows/scripts/New-CaelestiaRelease.ps1").read_text()
        self.assertIn("$build.backendMode -cne 'pinned'", release)


if __name__ == "__main__":
    unittest.main()
