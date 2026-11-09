"""Synthetic identities and command reports. No network or native acceptance."""

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("pair_result", ROOT / "windows/ci/pair_result.py")
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)
sys.path.insert(0, str(ROOT / "windows/ci"))
import native_reuse as reuse


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
                (".github/candidate-contract/test_candidate_contract.py",
                 "import json, unittest\nfrom pathlib import Path\n"
                 "class ExtractedContractTest(unittest.TestCase):\n"
                 "    def test_schema_is_available(self):\n"
                 "        self.assertTrue(json.loads(Path(__file__).with_name('v1.schema.json')"
                 ".read_text())['synthetic'])\n"),
                (".github/candidate-contract/v1.schema.json", '{"synthetic": true}\n')):
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
        # The hosted consumer executes these tests from the extracted trust
        # directory, not from the backend source tree.
        extracted = subprocess.run([sys.executable, "-B", "-m", "unittest", "discover",
                                    "-s", str(self.root / "trusted/.github/candidate-contract"),
                                    "-p", "test_*.py"], capture_output=True)
        self.assertEqual(0, extracted.returncode, extracted.stderr.decode(errors="replace"))
        contract["validatorSha256"] = "0" * 64
        self.put("windows/ci/pair-contract.json", contract)
        with patch.object(p, "git", side_effect=self.git_without_network):
            with self.assertRaisesRegex(ValueError, "trusted-validator-digest"):
                p.bootstrap(self.shell, self.backend, self.root / "refused")
        self.assertFalse((self.root / "refused").exists())

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_failed_integration_diagnostics_are_explicit_opt_in(self):
        self.put("windows/toolchain.json", {
            "qtDirectory": "fixture-qt", "llvmDirectory": "fixture-llvm",
            "cli11Directory": "fixture-cli"})
        scripts = self.shell / "windows/scripts"
        scripts.mkdir()
        marker = "SYNTHETIC_ISOLATED_FAILURE_DETAIL"
        (scripts / "Test-Validation.ps1").write_text(
            "param($Suite, $BuildRoot, $QtPrefix, $OutputRoot)\n"
            "Write-Output 'EARLIER_PRIVATE_DETAIL'\n"
            "1..100 | ForEach-Object { Write-Output ('x' * 300) }\n"
            f"Write-Output '{marker}'\nexit 7\n")
        for enabled in (False, True):
            with self.subTest(echo=enabled):
                results = self.root / ("echo" if enabled else "quiet")
                command = [
                    "powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                    str(ROOT / "windows/ci/Invoke-PairIntegration.ps1"),
                    "-ShellRoot", str(self.shell), "-BackendRoot", str(self.backend),
                    "-Mode", "pinned", "-BackendSha", self.backend_sha,
                    "-ToolRoot", str(self.root / "tools"),
                    "-BuildRoot", str(self.root / "unused-build"),
                    "-Results", str(results), "-JUnit", str(results / "integration.xml"),
                    "-Python", sys.executable]
                if enabled:
                    command.append("-EchoDiagnostics")
                result = subprocess.run(command, capture_output=True, timeout=30)
                output = result.stdout.decode(errors="replace")
                self.assertEqual(1, result.returncode, result.stderr.decode(errors="replace"))
                self.assertEqual(enabled, marker in output)
                self.assertIn("stage=services exit=7", output)
                self.assertRegex(output, r"Integration timing: services outcome=failure exit=7 seconds=[0-9]+\.[0-9]{6}")
                self.assertIn("services.private.log", output)
                self.assertNotIn("EARLIER_PRIVATE_DETAIL", output)
                self.assertLess(len(output), 18000)
                self.assertIn(marker, (results / "services.private.log").read_text(encoding="utf-8-sig"))
                journal = p.read(results / "integration-stages.json")
                self.assertEqual("failure", journal[0]["outcome"])
                self.assertEqual(7, journal[0]["exitCode"])
                self.assertTrue(all(row["outcome"] == "not_run" for row in journal[1:]))
                self.assertNotIn(marker, (results / "integration.xml").read_text())

    def test_production_timing_artifact_excludes_private_output(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        timing_step = workflow.split("      - name: Production and offscreen fixture timings\n", 1)[1].split(
            "      - name:", 1)[0]
        self.assertIn("if: always()", timing_step)
        paths = timing_step.split("          path: |\n", 1)[1].split("          retention-days:", 1)[0]
        self.assertEqual([
            "C:/b-public/logs/*-timing.json",
            "C:/ci-pair/integration-stages.json",
            "C:/ci-pair/Services/summary.json",
            "C:/ci-pair/Shell/summary.json",
        ], [line.strip() for line in paths.splitlines()])
        self.assertIn("retention-days: 7", timing_step)

    def integration_command(self, results, *extra, build=None):
        return ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                str(ROOT / "windows/ci/Invoke-PairIntegration.ps1"),
                "-ShellRoot", str(self.shell), "-BackendRoot", str(self.backend),
                "-Mode", "pinned", "-BackendSha", self.backend_sha,
                "-ToolRoot", str(self.root / "tools"),
                "-BuildRoot", str(build or self.root / "unused-build"),
                "-Results", str(results), "-JUnit", str(results / "integration.xml"),
                "-Python", sys.executable, *extra]

    def synthetic_scripts(self, validation):
        self.put("windows/toolchain.json", {
            "qtDirectory": "fixture-qt", "llvmDirectory": "fixture-llvm",
            "cli11Directory": "fixture-cli"})
        scripts = self.shell / "windows/scripts"
        scripts.mkdir(exist_ok=True)
        (scripts / "Test-Validation.ps1").write_text(validation)
        return scripts

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_services_preflight_is_isolated_unrecorded_and_fail_closed(self):
        self.synthetic_scripts(
            "param($Suite, $BuildRoot, $QtPrefix, $OutputRoot)\n"
            "New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null\n"
            "'{\"passed\": true, \"results\": [{\"name\": \"synthetic\", \"exitCode\": 0}]}' |"
            " Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json')\n"
            "if (Test-Path -LiteralPath $BuildRoot) { exit 3 }\n"
            "if ($env:PREFLIGHT_FIXTURE_FAIL) {\n"
            " Write-Output 'EARLIER_PREFLIGHT_PRIVATE_DETAIL'\n"
            " 1..100 | ForEach-Object { Write-Output ('x' * 300) }\n"
            " Write-Output 'PREFLIGHT_FAILURE_DETAIL'; exit 5 }\n")
        results = self.root / "results"
        preflight = self.root / "preflight"

        def run(root, env=None, results=results):
            return subprocess.run(self.integration_command(
                results, "-ServicesPreflightRoot", str(root), "-EchoDiagnostics"),
                capture_output=True, timeout=60, env=env)

        passed = run(preflight)
        self.assertEqual(0, passed.returncode, passed.stdout.decode(errors="replace"))
        self.assertTrue((preflight / "Services/summary.json").exists())
        # Never pair evidence: no results, journal, JUnit or build root, and the
        # envelope still sees an unrun Services suite.
        self.assertFalse(results.exists())
        self.assertFalse((self.root / "unused-build").exists())
        self.assertFalse(p.suite_counts(results)["services"]["reportedPassed"])
        self.assertNotEqual(0, run(preflight).returncode)  # Reuse refused.
        failing = run(self.root / "preflight-failure", dict(os.environ, PREFLIGHT_FIXTURE_FAIL="1"))
        output = failing.stdout.decode(errors="replace")
        self.assertEqual(1, failing.returncode, output)
        self.assertIn("PREFLIGHT_FAILURE_DETAIL", output)
        self.assertIn("Services preflight failed: exit=5", output)
        self.assertNotIn("EARLIER_PREFLIGHT_PRIVATE_DETAIL", output)
        self.assertLess(len(output), 17000)
        self.assertFalse(results.exists())
        quiet = subprocess.run(self.integration_command(
            results, "-ServicesPreflightRoot", str(self.root / "preflight-quiet")),
            capture_output=True, timeout=60, env=dict(os.environ, PREFLIGHT_FIXTURE_FAIL="1"))
        self.assertEqual(1, quiet.returncode)
        self.assertNotIn("PREFLIGHT_FAILURE_DETAIL", quiet.stdout.decode(errors="replace"))
        self.assertIn("exit=5", quiet.stdout.decode(errors="replace"))
        outer = self.root / "outer"
        for root, nested_results in ((results / "preflight", results), (outer, outer / "results")):
            with self.subTest(root=root.name):
                refused = run(root, results=nested_results)
                self.assertNotEqual(0, refused.returncode)
                self.assertIn("separate from pair results", refused.stdout.decode(errors="replace")
                              + refused.stderr.decode(errors="replace"))
                self.assertFalse(root.exists() and any(root.iterdir()))

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_preflight_refuses_build_tool_and_source_overlap_before_launch(self):
        self.synthetic_scripts(
            "New-Item -ItemType File -Force -Path $env:PREFLIGHT_LAUNCH_MARKER | Out-Null\n")
        # Both directions, equality, normalized dot segments, trailing
        # separators and case differences must refuse before creating output.
        for index, kind in enumerate((
                "build-equal", "build-child", "build-parent", "build-case", "build-dots",
                "results-equal", "results-case", "tools-child", "source-parent", "source-child")):
            base = self.root / f"case-{index}"
            base.mkdir()
            results, build, marker = base / "results", base / "build", base / "launched"
            preflight, build, message = {
                "build-equal": (build, build, "separate from the production build"),
                "build-child": (build / "early", build, "separate from the production build"),
                "build-parent": (base / "outer", base / "outer/build", "separate from the production build"),
                "build-case": (str(build).upper() + "\\", build, "separate from the production build"),
                "build-dots": (build / "child/..", build, "separate from the production build"),
                "results-equal": (results, build, "separate from pair results"),
                "results-case": (str(results).upper() + "\\", build, "separate from pair results"),
                "tools-child": (self.root / "tools/early", build, "separate from read-only tools"),
                "source-parent": (self.root, build, "outside both source roots"),
                "source-child": (self.shell / "early", build, "outside both source roots"),
            }[kind]
            with self.subTest(case=kind):
                result = subprocess.run(self.integration_command(
                    results, "-ServicesPreflightRoot", str(preflight), build=build),
                    capture_output=True, timeout=30,
                    env=dict(os.environ, PREFLIGHT_LAUNCH_MARKER=str(marker)))
                self.assertNotEqual(0, result.returncode)
                self.assertIn(message, (result.stdout + result.stderr).decode(errors="replace"))
                self.assertFalse(marker.exists())
                self.assertFalse(results.exists())
                self.assertFalse(build.exists())

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_preflight_refuses_junction_ancestor(self):
        self.synthetic_scripts("exit 0\n")
        junction = self.root / "source-alias"
        linked = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
             f"New-Item -ItemType Junction -Path '{junction}' -Target '{self.shell}' | Out-Null"],
            capture_output=True, timeout=30)
        self.assertEqual(0, linked.returncode, linked.stderr.decode(errors="replace"))
        result = subprocess.run(self.integration_command(
            self.root / "results", "-ServicesPreflightRoot", str(junction / "early")),
            capture_output=True, timeout=30)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("reparse", (result.stdout + result.stderr).decode(errors="replace"))
        self.assertFalse((self.shell / "early").exists())

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_log_write_failure_is_not_success(self):
        # A stage that exits zero must not mask failure of its log sink.
        self.synthetic_scripts("Write-Output 'SYNTHETIC_STAGE_OUTPUT'\nexit 0\n")
        results = self.root / "results"
        (results / "services.private.log").mkdir(parents=True)
        result = subprocess.run(self.integration_command(results),
                                capture_output=True, timeout=30)
        self.assertNotEqual(0, result.returncode)
        journal = p.read(results / "integration-stages.json")
        self.assertEqual("failure", journal[0]["outcome"])
        self.assertNotEqual(0, journal[0]["exitCode"])
        self.assertTrue(all(row["outcome"] == "not_run" for row in journal[1:]))
        report = ET.parse(results / "integration.xml").getroot()
        self.assertIsNotNone(report.find("testcase/failure"))

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_workflow_propagates_jobs_to_each_compile_entry_point(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        results = self.root / "workflow-results"
        p.write(results / "pair-local.json", {"backendRoot": str(self.backend)})
        p.write(results / "pair-request.json", {"mode": "pinned", "backend": self.backend_sha})
        calls = self.root / "workflow-calls.jsonl"
        # Run the actual workflow blocks with native entry points replaced by
        # argument recorders. No compiler, fixture binary or validator is run.
        harness = self.root / "workflow.ps1"
        blocks = []
        for name in ("First-party capture Rust regressions",
                     "Backend component build and portable tier",
                     "Exact-pair production integration"):
            found = re.search(
                r"(?m)^      - name: " + re.escape(name) +
                r"\r?\n(?:        env:\r?\n(?:          [^\r\n]*\r?\n)+)?"
                r"        run: \|\r?\n((?:          [^\r\n]*\r?\n|\r?\n)+)", workflow)
            self.assertIsNotNone(found, name)
            blocks.append(found[1])
        harness.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "function Save-Call([string]$Executable, [object[]]$Arguments) {\n"
            " [ordered]@{ executable = $Executable; arguments = $Arguments } |"
            " ConvertTo-Json -Compress | Add-Content -LiteralPath $env:WORKFLOW_CALLS\n"
            " $global:LASTEXITCODE = 0\n"
            "}\n"
            "function powershell.exe { Save-Call 'powershell' $args }\n"
            "function python { Save-Call 'python' $args }\n" + "\n".join(blocks))
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive",
                                 "-File", str(harness)], capture_output=True, timeout=30,
                                env=dict(os.environ, BUILD_JOBS="5", PAIR_RESULTS=str(results),
                                         GITHUB_WORKSPACE=str(ROOT), TRUSTED_ROOT=str(self.root / "trusted"),
                                         TOOL_ROOT=str(self.root / "tools"), BUILD_ROOT=str(self.root / "build"),
                                         WORKFLOW_CALLS=str(calls)))
        self.assertEqual(0, result.returncode, (result.stdout + result.stderr).decode(errors="replace"))
        rows = [json.loads(line) for line in calls.read_text(encoding="utf-8-sig").splitlines()]
        commands = [row["arguments"] for row in rows]
        compile_calls = [args for args in commands if "-Jobs" in args]
        self.assertEqual(5, len(compile_calls))  # Capture, 3 fixture phases, integration.
        for args in compile_calls:
            self.assertEqual("5", args[args.index("-Jobs") + 1])
        self.assertEqual(["configure", "build", "portable", "integration"],
                         [args[args.index("--stage") + 1] for args in commands if "--stage" in args])
        self.assertTrue(any("-JUnit" in args for args in compile_calls))

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_integration_launcher_arguments_follow_launcher_variable(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        results = self.root / "launcher-results"
        p.write(results / "pair-local.json", {"backendRoot": str(self.backend)})
        p.write(results / "pair-request.json", {"mode": "pinned", "backend": self.backend_sha})
        found = re.search(
            r"(?m)^      - name: Exact-pair production integration\r?\n"
            r"        run: \|\r?\n((?:          [^\r\n]*\r?\n|\r?\n)+)", workflow)
        self.assertIsNotNone(found)
        harness = self.root / "launcher.ps1"
        harness.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "function Save-Call([string]$Executable, [object[]]$Arguments) {\n"
            " [ordered]@{ executable = $Executable; arguments = $Arguments } |"
            " ConvertTo-Json -Compress | Add-Content -LiteralPath $env:WORKFLOW_CALLS\n"
            " $global:LASTEXITCODE = 0\n"
            "}\n"
            "function python { Save-Call 'python' $args }\n" + found[1])
        launcher = str(self.root / "sccache.exe")
        rust_cache = str(self.root / "rust-cache")
        for case, launcher_value in (("set", launcher), ("unset", None), ("empty", "")):
            calls = self.root / f"launcher-{case}.jsonl"
            env = dict(os.environ, BUILD_JOBS="5", PAIR_RESULTS=str(results),
                       GITHUB_WORKSPACE=str(ROOT), TRUSTED_ROOT=str(self.root / "trusted"),
                       TOOL_ROOT=str(self.root / "tools"), BUILD_ROOT=str(self.root / "build"),
                       RUST_CACHE_DIR=rust_cache, WORKFLOW_CALLS=str(calls))
            env.pop("CI_COMPILER_LAUNCHER", None)
            if launcher_value is not None:
                env["CI_COMPILER_LAUNCHER"] = launcher_value
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive",
                                     "-File", str(harness)], capture_output=True, timeout=30, env=env)
            self.assertEqual(0, result.returncode, (result.stdout + result.stderr).decode(errors="replace"))
            rows = [json.loads(line) for line in calls.read_text(encoding="utf-8-sig").splitlines()]
            self.assertEqual(1, len(rows), case)
            arguments = rows[0]["arguments"]
            jobs = arguments.index("-Jobs")
            if launcher_value:
                # Exactly the command line the integration script received before this change.
                self.assertEqual(["-Jobs", "5", "-CompilerLauncher", launcher,
                                  "-RustCacheDirectory", rust_cache, "-BuildRoot"],
                                 arguments[jobs:jobs + 7], case)
                self.assertEqual(1, arguments.count("-CompilerLauncher"))
            else:
                self.assertNotIn("-CompilerLauncher", arguments, case)
                self.assertNotIn("-RustCacheDirectory", arguments, case)
                self.assertEqual(["-Jobs", "5", "-BuildRoot"], arguments[jobs:jobs + 3], case)

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_production_receives_selected_jobs_and_rejects_out_of_range(self):
        scripts = self.synthetic_scripts("exit 0\n")
        arguments = self.root / "production-arguments.txt"
        (scripts / "Build-Prototype.ps1").write_text(
            f"$args -join ' ' | Set-Content -LiteralPath '{arguments}'\nexit 9\n")
        results = self.root / "jobs"
        rust_cache = str(self.root / "rust-cache")
        result = subprocess.run(self.integration_command(results, "-Jobs", "5",
                                                        "-RustCacheDirectory", rust_cache),
                                capture_output=True, timeout=60)
        self.assertEqual(1, result.returncode, result.stderr.decode(errors="replace"))
        self.assertIn("-Jobs 5 ", arguments.read_text(encoding="utf-8-sig"))
        self.assertIn("-RustCacheDirectory " + rust_cache, arguments.read_text(encoding="utf-8-sig"))
        journal = p.read(results / "integration-stages.json")
        self.assertEqual(["success", "failure"], [row["outcome"] for row in journal[:2]])
        self.assertEqual(9, journal[1]["exitCode"])
        for jobs in ("0", "17"):
            refused = self.root / ("jobs-" + jobs)
            result = subprocess.run(self.integration_command(refused, "-Jobs", jobs),
                                    capture_output=True, timeout=60)
            self.assertNotEqual(0, result.returncode)
            self.assertFalse(refused.exists())

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

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_validation_fails_closed_without_delivery_dependency(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        validation = workflow.split("\n  validation:\n")[1].split("\n  candidate:\n")[0]
        block = re.search(r"        run: \|\n((?:          [^\n]*\n|\n)+)", validation)[1]
        harness = self.root / "validation.ps1"
        harness.write_text("$ErrorActionPreference = 'Stop'\n" + block)
        base = {**os.environ, "SCOPE": "success", "CHECKS": "success", "PACKAGING": "success",
                "BUILD": "success", "FIXTURES": "success", "PAIR": "success",
                "REUSE": "skipped", "REUSE_MODE": "", "NATIVE_REQUIRED": "full"}
        skipped = {"NATIVE_REQUIRED": "none", "BUILD": "skipped", "FIXTURES": "skipped", "PAIR": "skipped"}
        reused = {**skipped, "NATIVE_REQUIRED": "reuse", "REUSE": "success", "REUSE_MODE": "reuse"}
        cases = [({}, True), (skipped, True)]
        cases += [(reused, True),
                  ({"NATIVE_REQUIRED": "reuse", "REUSE": "success", "REUSE_MODE": "full"}, True)]
        cases += [({**reused, "REUSE": value}, False) for value in ("failure", "cancelled", "skipped")]
        cases += [({**reused, "REUSE_MODE": value}, False) for value in ("", "invalid")]
        cases += [({"REUSE": value}, False) for value in ("success", "failure", "cancelled")]
        cases += [({**skipped, "REUSE": value}, False) for value in ("success", "failure", "cancelled")]
        cases += [({**reused, gate: value}, False) for gate in ("FIXTURES", "BUILD", "PAIR")
                  for value in ("success", "failure", "cancelled")]
        cases += [({"NATIVE_REQUIRED": value}, False) for value in ("", "invalid")]
        cases += [({gate: outcome}, False) for gate in ("SCOPE", "CHECKS", "PACKAGING", "FIXTURES", "BUILD", "PAIR")
                  for outcome in ("failure", "cancelled", "skipped")]
        cases += [({**skipped, gate: outcome}, False) for gate in ("FIXTURES", "BUILD", "PAIR")
                  for outcome in ("success", "failure", "cancelled")]
        for changes, passed in cases:
            with self.subTest(changes=changes):
                result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive",
                                         "-File", str(harness)], env={**base, **changes},
                                        capture_output=True)
                self.assertEqual(passed, result.returncode == 0, result.stderr.decode(errors="replace"))

    def test_reuse_discovers_newest_validated_trusted_ancestor_and_live_artifact(self):
        newest, older = "a" * 40, "c" * 40
        run = dict(id=7, path=reuse.WORKFLOW, event="push", head_branch="main", head_sha=older)
        passed = [{"name": name, "conclusion": "success"} for name in reuse.REQUIRED_JOBS]
        for field, value in (("path", ".github/workflows/other.yml"), ("event", "pull_request"),
                             ("head_branch", "other"), ("head_sha", "not-a-sha")):
            with self.subTest(field=field):
                self.assertFalse(reuse.trusted_shape({**run, field: value}))
        self.assertTrue(reuse.trusted_shape(run))
        self.assertTrue(reuse.validated(passed + [{"name": "Assemble exact-tested release candidate",
                                                   "conclusion": "failure"}]))
        for name in reuse.REQUIRED_JOBS:
            with self.subTest(job=name):
                self.assertFalse(reuse.validated([j for j in passed if j["name"] != name]))
                self.assertFalse(reuse.validated(
                    [j if j["name"] != name else {**j, "conclusion": None} for j in passed]))
        artifact = dict(name=f"native-reuse-{older}", expired=False)
        for rows in ([], [{**artifact, "expired": True}], [{**artifact, "name": "other"}],
                     [artifact, artifact]):
            with self.subTest(rows=rows), self.assertRaisesRegex(ValueError, "artifact-unavailable"):
                reuse.select_artifact(rows, older)
        # Newest main run is still building; the previous validated ancestor is chosen.
        runs = [dict(run, id=9, head_sha=newest), dict(run, id=8, head_sha="d" * 40), run]
        jobs = {9: [{"name": reuse.REQUIRED_JOBS[0], "conclusion": None}], 7: passed}
        def api(path):
            if "/workflows/" in path:
                return {"workflow_runs": runs}
            run_id = int(path.split("/")[2])
            return {"jobs": jobs[run_id]} if "/jobs" in path else {"artifacts": [artifact]}
        not_ancestor = {"d" * 40}
        self.assertEqual((7, artifact["name"], older),
                         reuse.discover(lambda sha: sha not in not_ancestor, api))
        with self.assertRaisesRegex(ValueError, "trusted-main-run-unavailable"):
            reuse.discover(lambda sha: False, api)
        with self.assertRaisesRegex(ValueError, "trusted-main-run-unavailable"):
            reuse.discover(lambda sha: True, lambda _: {"workflow_runs": []})
        with self.assertRaises(OSError):
            reuse.discover(lambda sha: True, lambda _: (_ for _ in ()).throw(OSError("offline")))

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_reuse_verification_refusals(self):
        for name in ("ci/Get-NativeBuildRequired.ps1", "capture/Source.ps1", "shell/sources.json"):
            path = self.shell / "windows" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "windows" / name, path)
        self.commit(self.shell)
        base = run_git(self.shell, "rev-parse", "HEAD")
        path = self.shell / "windows/shell/shell.qml"
        path.write_text("// synthetic QML change\n")
        self.commit(self.shell)
        build = self.root / "build"
        rows = []
        for name in ("quickshell/qs.exe", "install/caelestia-capture.exe",
                     "install/DesktopTakeover.dll", "install/qml/Fixture/plugin.dll"):
            file = build / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"inert")
            rows.append(dict(path=name, sha256=reuse.digest(file)))
        record = dict(sourceRevision=base, sourceDirty=False, backendMode="pinned",
                      backendRevision=self.backend_sha, nativeInputs=rows)
        for name in ("caelestia/CTestTestfile.cmake", "caelestia/test.exe"):
            file = build / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"inert")
        inventory = self.root / "inventory.json"
        def save(value):
            p.write(build / "logs/build.json", value)
            p.write(inventory, [dict(path=f.relative_to(build).as_posix(), sha256=reuse.digest(f))
                                for f in build.rglob("*") if f.is_file()])
        def verify():
            return reuse.verify(self.shell, build, inventory, base, "HEAD")
        save(record)
        self.assertGreater(len(verify()), len(rows))
        for key, value, reason in (("sourceRevision", "f" * 40, "build-source-mismatch"),
                                   ("sourceDirty", True, "dirty-native-build"),
                                   ("sourceDirty", None, "dirty-native-build"),
                                   ("backendMode", "candidate", "unpinned-native-build"),
                                   ("backendRevision", "f" * 40, "backend-lock-mismatch"),
                                   ("nativeInputs", [], "missing-native-inventory")):
            with self.subTest(key=key, value=value):
                save({**record, key: value})
                with self.assertRaisesRegex(ValueError, reason): verify()
        save(record)
        (build / "quickshell/qs.exe").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "tested-native-bytes-changed"): verify()
        (build / "quickshell/qs.exe").write_bytes(b"inert")
        (build / "caelestia/test.exe").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "reuse-file-hash-mismatch"): verify()
        (build / "caelestia/test.exe").write_bytes(b"inert")
        original = p.read(inventory)
        for changed, reason in ((original[:-1], "incomplete-reuse-inventory"),
                                ([], "missing-reuse-inventory"),
                                ([{**original[0], "path": "../escape"}] + original[1:], "unsafe-reuse-inventory"),
                                ([{**original[0], "sha256": "invalid"}] + original[1:], "reuse-file-hash-mismatch"),
                                (original + [original[0]], "unsafe-reuse-inventory")):
            p.write(inventory, changed)
            with self.assertRaisesRegex(ValueError, reason): verify()
        p.write(inventory, original)
        plugin_file = build / "caelestia/CTestTestfile.cmake"
        plugin_file.unlink()
        save(record)
        with self.assertRaisesRegex(ValueError, "missing-plugin-tests"): verify()
        plugin_file.write_bytes(b"inert")
        save(record)
        with self.assertRaisesRegex(ValueError, "invalid-base"):
            reuse.verify(self.shell, build, inventory, "not-a-sha", "HEAD")
        actual_git = reuse.git
        def diverged_git(shell, *args):
            if args[0] == "merge-base": return "f" * 40
            return actual_git(shell, *args)
        with patch.object(reuse, "git", side_effect=diverged_git):
            with self.assertRaisesRegex(ValueError, "base-not-ancestor"): verify()
        for path, reason in (("windows/deps/quickshell", "backend-gitlink-changed"),
                             ("windows/sources.lock.json", "source-lock-changed"),
                             ("windows/toolchain.json", "toolchain-spec-changed")):
            def changed_git(shell, *args):
                if args[:2] == ("ls-tree", "HEAD") and args[-1] == path: return "changed"
                return actual_git(shell, *args)
            with patch.object(reuse, "git", side_effect=changed_git):
                with self.assertRaisesRegex(ValueError, reason): verify()
        native = self.shell / "unknown-native.cpp"
        native.write_text("// native input\n")
        self.commit(self.shell)
        with self.assertRaisesRegex(ValueError, "native-diff-refused"): verify()

    def test_workflow_and_release_boundaries(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual(workflow, (ROOT / "windows/ci/windows-build.yml.template").read_text())
        self.assertIn("github.event_name == 'push'", workflow)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)
        self.assertIn("|| github.run_id", workflow)
        self.assertIn("--stage producer --unittest --echo", workflow)
        self.assertIn("run --stage prepare --echo", workflow)
        self.assertIn("--stage $phase --echo", workflow)
        self.assertIn("run --stage integration --echo", workflow)
        self.assertIn('-JUnit "$env:PAIR_RESULTS\\integration.raw.xml" -EchoDiagnostics', workflow)
        readonly, publication = workflow.split("\n  publish:\n")
        self.assertNotIn("secrets.", readonly)
        self.assertNotIn("contents: write", readonly)
        self.assertEqual(1, publication.count("contents: write"))
        self.assertIn("needs: [candidate, validation]", publication)
        self.assertIn("vars.NEXUS_DEVELOPMENT_PUBLISH == 'enabled'", publication)
        self.assertNotIn("pull_request_target", workflow)
        reused = workflow.split("\n  reuse:\n")[1].split("\n  fixtures:\n")[0]
        self.assertIn("actions: read", reused)
        self.assertIn("run-id: ${{ steps.producer.outputs.run-id }}", reused)
        self.assertIn("github-token: ${{ github.token }}", reused)
        self.assertNotIn("actions/cache/save@", reused)
        self.assertNotIn("pair_result.py", reused)
        self.assertIn("-TestOnly", reused)
        integration = (ROOT / "windows/ci/Invoke-PairIntegration.ps1").read_text()
        test_only = integration.split("if ($TestOnly) {")[1].split("if ($ServicesPreflightRoot) {")[0]
        self.assertNotIn("pair_result.py", test_only)
        self.assertNotIn("Save-Journal", test_only)
        self.assertNotIn("Build-Prototype", test_only)
        # Three compile entry points remain: fixture loop (moved, not copied),
        # capture Rust and production integration. The join never compiles.
        self.assertNotIn("-Jobs 2", workflow)
        fixtures = workflow.split("\n  fixtures:\n")[1].split("\n  build:\n")[0]
        build = workflow.split("\n  build:\n")[1].split("\n  pair:\n")[0]
        pair = workflow.split("\n  pair:\n")[1].split("\n  validation:\n")[0]
        self.assertEqual(2, fixtures.count("-Jobs $env:BUILD_JOBS"))
        self.assertEqual(1, build.count("-Jobs $env:BUILD_JOBS"))
        self.assertEqual(1, workflow.count("Test-CaptureRust.ps1"))
        self.assertIn("Test-CaptureRust.ps1", fixtures)
        self.assertIn("name: capture-rust-${{ github.run_id }}-${{ github.run_attempt }}", fixtures)
        self.assertIn("path: C:/ci-capture/capture-rust.json", fixtures)
        for job in (build, pair):
            self.assertNotIn("ci-capture", job)
            self.assertNotIn("capture-rust", job)
        self.assertNotIn("-Jobs $env:BUILD_JOBS", pair)
        for job in (fixtures, build):
            self.assertIn("Get-BuildJobs.ps1", job)
            self.assertIn("--stage producer --unittest --echo", job)
            self.assertIn("run --stage prepare --echo", job)
        for action in re.findall(r"uses: ([^\s]+)", workflow):
            self.assertRegex(action, r"^[\w/-]+@[a-f0-9]{40}$")
        # Recorded Services still fails before compilation; no duplicate CI run.
        self.assertNotIn("-ServicesPreflightRoot C:\\ci-preflight", workflow)
        self.assertLess(integration.index('Invoke-Gate 0 $ps (Get-ServicesArguments'),
                        integration.index('Invoke-Gate 1 $ps $buildArguments'))
        self.assertNotIn("--stage services", workflow)
        # Every cache writer, not just tooling, requires a trusted main push.
        saves = re.findall(r"        if: ([^\n]+)\n        uses: actions/cache/save@", workflow)
        self.assertEqual(4, workflow.count("uses: actions/cache/save@"))
        self.assertEqual(4, len(saves))
        for condition in saves:
            self.assertIn("github.ref == 'refs/heads/main' && github.event_name == 'push'", condition)
            self.assertNotIn("||", condition)
        for job, kind in ((fixtures, "fixtures"), (build, "production")):
            self.assertIn(f"SCCACHE_DIR: C:\\sccache-{kind}", job)
            self.assertIn("Prepare-Sccache.ps1", job)
            self.assertIn("Complete-Sccache.ps1", job)
            self.assertIn(f"windows-{kind}-objects-v1-sccache-0.15.0-", job)
            self.assertIn("-main-${{ github.run_id }}-${{ github.run_attempt }}", job)
            prefix = job.split("restore-keys: |\n")[1].splitlines()[0]
            self.assertNotIn("CMake", prefix)
            self.assertNotIn("sources.lock", prefix)
            self.assertLess(job.index("Complete-Sccache.ps1"), job.index("name: Save " + kind))
        self.assertIn("QS_FIXTURE_COMPILER_LAUNCHER:", fixtures)
        # The launcher and the Rust cache directory reach the integration step
        # together, and only when CI_COMPILER_LAUNCHER is set. The behavior is
        # exercised in test_integration_launcher_arguments_follow_launcher_variable.
        self.assertRegex(build, re.compile(
            r"\$launcherArguments = @\(\)\n"
            r"\s+if \(\$env:CI_COMPILER_LAUNCHER\) \{\n"
            r"\s+\$launcherArguments = @\('-CompilerLauncher', \$env:CI_COMPILER_LAUNCHER,\n"
            r"\s+'-RustCacheDirectory', \$env:RUST_CACHE_DIR\)\n"
            r"\s+\}\n"))
        self.assertEqual(1, build.count("@launcherArguments `"))
        self.assertRegex(build, r"-Jobs \$env:BUILD_JOBS `\n\s+@launcherArguments `\n\s+-BuildRoot ")
        self.assertNotIn("-CompilerLauncher $env:CI_COMPILER_LAUNCHER `", build)
        prototype = (ROOT / "windows/scripts/Build-Prototype.ps1").read_text()
        for language in ("C", "CXX"):
            self.assertIn(f'"-DCMAKE_{language}_COMPILER_LAUNCHER:FILEPATH=$CompilerLauncher"', prototype)
        self.assertIn("RUST_CACHE_DIR: C:\\sccache-rust-production", build)
        self.assertIn("path: C:\\sccache-rust-production", build)
        self.assertIn("windows-production-rust-v1-sccache-0.15.0-", build)
        self.assertIn("SCCACHE_SERVER_PORT: '4227'", build)
        self.assertIn("$env:RUSTC_WRAPPER = $CompilerLauncher", prototype)
        self.assertIn("$env:CARGO_INCREMENTAL = '0'", prototype)
        self.assertIn("$env:SCCACHE_DIR = $RustCacheDirectory", prototype)
        self.assertIn("[Environment]::SetEnvironmentVariable($name, $rustCacheEnvironment[$name], 'Process')", prototype)
        prepare = (ROOT / "windows/ci/Prepare-Sccache.ps1").read_text()
        self.assertIn("b0b257a164bf438b2dea134ca7ded41c100f59a64b3bf275a202f1e8102ab217", prepare)
        self.assertLess(prepare.index("Get-FileHash"), prepare.index("tar.exe"))
        complete = (ROOT / "windows/ci/Complete-Sccache.ps1").read_text()
        self.assertIn("--show-stats --stats-format json", complete)
        self.assertIn("--stop-server", complete)
        release = (ROOT / "windows/scripts/New-CaelestiaRelease.ps1").read_text()
        self.assertIn("$build.backendMode -cne 'pinned'", release)


if __name__ == "__main__":
    unittest.main()
