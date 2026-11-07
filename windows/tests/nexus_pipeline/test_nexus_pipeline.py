"""Ephemeral CNG + fake GitHub + local bare Git controls. Never live publication."""
import argparse
import base64
import copy
import contextlib
import hashlib
import importlib.util
import json
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "windows/ci"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import nexus_candidate as c
import nexus_publish as n
import pair_result as p
import nexus_process
import evidence_fixture

MATERIAL = json.loads(os.environ.pop("NEXUS_TEST_KEY_MATERIAL"))


def fixture_script(template, **values):
    # Substitute delimited tokens once. Inserted paths are opaque, even when
    # a username/8.3 path contains another token's name (e.g. RUNNER~1).
    return re.sub(r"@@([A-Z_]+)@@", lambda match: values[match[1]], template)


class Diagnostics(unittest.TestCase):
    def test_fixture_template_never_reprocesses_inserted_paths(self):
        value = "'C:\\Users\\RUNNER~1\\SOURCE ROOT PYTHON ECHO CHILD LOGS SHALLOW\\user''s\\@@B@@'"
        self.assertEqual(value + " literal", fixture_script("@@A@@ @@B@@", A=value, B="literal"))

    def test_publisher_child_failure_retains_private_log_not_secret_output(self):
        with tempfile.TemporaryDirectory(prefix="nexus-command-diagnostics-") as temp:
            log = Path(temp) / "fixture.private.log"
            result = subprocess.CompletedProcess([], 7, b"UNDERLYING_FIXTURE_FAILURE", b"private fixture detail")
            with patch.object(n.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(c.GateRejection, "^external-command-refused-exit-7$"):
                    n.checked_run(["inert-fixture", "private-argument"], diagnostic_log=log)
            self.assertIn(b"UNDERLYING_FIXTURE_FAILURE", log.read_bytes())
            self.assertIn(b"private fixture detail", log.read_bytes())

    def test_safe_reason_codes_never_echo_arbitrary_exception_values(self):
        self.assertEqual("trusted-main-push-required", c.failure_reason(c.GateRejection("trusted-main-push-required")))
        for error in (ValueError("private signing material"), KeyError("private signing material"),
                      OSError("C:\\private\\path"), c.GateRejection("unexpected\nprivate output")):
            self.assertEqual(type(error).__name__, c.failure_reason(error))

    def test_actual_candidate_gate_exit_tail_and_log_failure(self):
        with tempfile.TemporaryDirectory(prefix="nexus-diagnostics-") as temp:
            root = Path(temp) / "RUNNER~1 SOURCE ROOT PYTHON ECHO CHILD LOGS SHALLOW user's"
            root.mkdir()
            child = root / "child.ps1"
            child.write_text("1..100 | ForEach-Object { 'line-' + $_ + ('x' * 400) }\n"
                             "'UNDERLYING_FIXTURE_FAILURE'\nexit 7\n", encoding="utf-8")
            quote = lambda value: "'" + str(value).replace("'", "''") + "'"
            # Load only the real gate functions, never the assembly entrypoint.
            bootstrap = """
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(@@SOURCE@@, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'candidate source does not parse' }
foreach ($name in @('Invoke-CandidateCommand', 'Invoke-CandidateGate')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq $name }, $true)
    if (-not $node) { throw 'candidate gate missing' }
    . ([scriptblock]::Create($node.Extent.Text))
}
$ps = Join-Path $PSHOME 'powershell.exe'
$Python = @@PYTHON@@
$candidateRunner = @@RUNNER@@
$privateLogs = @@LOGS@@
$EchoDiagnostics = @@ECHO@@
try { Invoke-CandidateGate 'fixture' @@CHILD@@ @() @@TIMEOUT@@; throw 'unexpected success' }
catch {
    $message = $_.Exception.Message
    Write-Output ('CAUGHT:' + $message)
    if ($message -notlike '*exit=@@EXPECTED_EXIT@@*' -or $message -notlike '*fixture.log*') { exit 8 }
}
"""
            values = {"SOURCE": quote(ROOT / "windows/ci/New-NexusCandidate.ps1"),
                      "CHILD": quote(child), "PYTHON": quote(sys.executable),
                      "RUNNER": quote(ROOT / "windows/ci/nexus_process.py"),
                      "TIMEOUT": "", "EXPECTED_EXIT": "7"}
            for echo in (False, True):
                logs = root / str(echo)
                logs.mkdir()
                script = root / ("check-" + str(echo) + ".ps1")
                script.write_text(fixture_script(bootstrap, **values, LOGS=quote(logs),
                                                 ECHO="$true" if echo else "$false"), encoding="utf-8")
                result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(script)],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual(echo, "UNDERLYING_FIXTURE_FAILURE" in result.stdout)
                self.assertIn("exit=7", result.stdout)
                if echo:
                    self.assertIn("[earlier output truncated]", result.stdout)
                    self.assertLess(len(result.stdout), 17000)
            self.assertIn("UNDERLYING_FIXTURE_FAILURE", (logs / "fixture.log").read_text(encoding="utf-8-sig"))
            # A failed log write must terminate even when the child succeeds.
            child.write_text("'success'\nexit 0\n", encoding="utf-8")
            blocked = root / "missing-parent" / "logs"
            script.write_text(fixture_script(bootstrap, **values, LOGS=quote(blocked), ECHO="$false"),
                              encoding="utf-8")
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(script)],
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(0, result.returncode)
            self.assertNotIn("unexpected success", result.stdout)
            timeout_logs = root / "timeout"
            timeout_logs.mkdir()
            child.write_text("'before hang'\nStart-Sleep -Seconds 30\n", encoding="utf-8")
            script.write_text(fixture_script(bootstrap,
                **{**values, "TIMEOUT": "1", "EXPECTED_EXIT": "124"}, LOGS=quote(timeout_logs), ECHO="$true"),
                encoding="utf-8")
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(script)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn("exit=124", result.stdout)
            state = json.loads((timeout_logs / "fixture.state.json").read_text())
            self.assertEqual(("timeout", 1), (state["outcome"], state["timeoutSeconds"]))

class StageRunner(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nexus-stage-RUNNER~1-SHALLOW-LOGS-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def execute(self, source, timeout=10, log=None, echo=False):
        output, error = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            code = nexus_process.run_stage([sys.executable, "-I", "-B", "-c", source],
                log or self.root / "stage.log", "fixture", timeout, heartbeat=0.2, echo=echo)
        return code, output.getvalue(), error.getvalue()

    def test_success_failure_and_private_tail_have_real_exit_and_state(self):
        code, output, error = self.execute("print('success')", log=self.root / "success.log")
        self.assertEqual(0, code)
        self.assertIn("NEXUS_STAGE_START fixture", output)
        self.assertIn("outcome=success", output)
        self.assertEqual("", error)
        code, output, error = self.execute(
            "import sys; print('x'*200000); print('UNDERLYING_FAILURE'); sys.exit(7)", echo=True)
        self.assertEqual(7, code)
        self.assertIn("UNDERLYING_FAILURE", error)
        self.assertLess(len(error), 17000)
        self.assertGreater((self.root / "stage.log").stat().st_size, 200000)
        state = json.loads((self.root / "stage.state.json").read_text())
        self.assertEqual(("failure", 7), (state["outcome"], state["exitCode"]))

    def test_hang_deadline_kills_owned_descendant_and_reports_progress(self):
        marker = self.root / "descendant.pid"
        source = ("import subprocess,sys,time,pathlib; "
                  "child=subprocess.Popen([sys.executable,'-I','-c','import time; time.sleep(60)']); "
                  f"pathlib.Path({str(marker)!r}).write_text(str(child.pid)); "
                  "print('BEFORE_HANG',flush=True); time.sleep(60)")
        code, output, error = self.execute(source, timeout=3, echo=True)
        self.assertEqual(124, code)
        self.assertIn("NEXUS_STAGE_PROGRESS fixture", output)
        self.assertIn("BEFORE_HANG", error)
        state = json.loads((self.root / "stage.state.json").read_text())
        self.assertEqual(("timeout", 124), (state["outcome"], state["exitCode"]))
        self.assertLess(state["seconds"], 15)
        self.assertTrue(marker.exists(), "child must actually start for cleanup proof")
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            kernel.OpenProcess.restype = wintypes.HANDLE
            kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = kernel.OpenProcess(0x100000, False, int(marker.read_text()))
            if handle:
                try:
                    self.assertEqual(0, kernel.WaitForSingleObject(handle, 0), "owned descendant survived timeout")
                finally:
                    kernel.CloseHandle(handle)

    def test_log_failure_never_launches_and_signing_key_is_not_inherited(self):
        marker = self.root / "must-not-run"
        with self.assertRaises(OSError):
            self.execute(f"from pathlib import Path; Path({str(marker)!r}).touch()",
                         log=self.root / "absent" / "stage.log")
        self.assertFalse(marker.exists())
        with patch.dict(os.environ, {"NEXUS_SIGNING_KEY": "PRIVATE_SENTINEL"}):
            code, _, _ = self.execute("import os; assert 'NEXUS_SIGNING_KEY' not in os.environ; print('no key')")
        self.assertEqual(0, code)
        self.assertNotIn("PRIVATE_SENTINEL", (self.root / "stage.log").read_text())

    def test_invalid_budgets_are_rejected_before_launch(self):
        for budget in (0, -1, float("nan"), float("inf"), 3601):
            with self.subTest(budget=budget), self.assertRaises(ValueError):
                self.execute("raise AssertionError('must not run')", timeout=budget)

    def test_real_history_helper_unshallows_exact_head_without_other_refs(self):
        source, shallow = self.root / "origin", self.root / "shallow"
        source.mkdir()
        git(source, "init", "--quiet")
        for value in ("first", "second"):
            (source / "source.txt").write_text(value)
            commit(source)
        revision = git(source, "rev-parse", "HEAD")
        git(source, "tag", "unrelated-tag")
        git(source, "branch", "unrelated-branch")
        subprocess.run(["git", "clone", "--quiet", "--depth=1", "--no-tags",
                        "--single-branch", source.as_uri(), str(shallow)], check=True, capture_output=True)
        self.assertEqual("true", git(shallow, "rev-parse", "--is-shallow-repository"))
        quote = lambda value: "'" + str(value).replace("'", "''") + "'"
        body = """
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(@@SOURCE@@, [ref]$tokens, [ref]$errors)
foreach ($name in @('Invoke-CandidateCommand', 'Complete-CandidateHistory')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $node) { throw 'history helper missing' }
    . ([scriptblock]::Create($node.Extent.Text))
}
$Python = @@PYTHON@@
$candidateRunner = @@RUNNER@@
$privateLogs = @@LOGS@@
$EchoDiagnostics = $true
Complete-CandidateHistory @@SHALLOW@@ 'fixture'
"""
        body = fixture_script(body, SOURCE=quote(ROOT / "windows/ci/New-NexusCandidate.ps1"),
                              PYTHON=quote(sys.executable), RUNNER=quote(ROOT / "windows/ci/nexus_process.py"),
                              LOGS=quote(self.root), SHALLOW=quote(shallow))
        script = self.root / "history.ps1"
        script.write_text(body, encoding="utf-8")
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(script)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("false", git(shallow, "rev-parse", "--is-shallow-repository"))
        self.assertEqual(revision, git(shallow, "rev-parse", "HEAD"))
        self.assertEqual("2", git(shallow, "rev-list", "--count", "HEAD"))
        self.assertEqual("", git(shallow, "tag", "--list"))
        self.assertNotIn("unrelated-branch", git(shallow, "branch", "-r"))

class Evidence(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nexus-evidence-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shell, self.build, self.results, self.validator, self.ctx = evidence_fixture.create(self.root, ROOT)

    def verify(self):
        return c.verify_live_evidence(self.shell, self.build, self.results, self.validator, self.ctx)

    def test_real_pinned_validator_and_same_build_evidence_pass(self):
        self.assertEqual("0.2.0-dev.1.8.2", self.verify())
        output = self.root / "public"; output.mkdir()
        c.export_evidence(self.shell, self.build, self.results, self.validator, self.ctx, output)
        c.verify_receipt(self.shell, output, self.validator, self.ctx)
        self.assertNotIn(str(self.root), "".join(path.read_text() for path in output.iterdir()))
        self.assertFalse((output / "build.json").exists())

    def test_integration_transfer_has_only_join_inputs(self):
        p.write(self.results / "pair-local.json", {"backendRoot": "synthetic-local-root"})
        transfer = self.root / "integration-transfer"
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
            str(ROOT / "windows/ci/Export-NexusCandidateInputs.ps1"), "-BuildRoot", str(self.build),
            "-PairResults", str(self.results), "-OutputDirectory", str(transfer), "-Integration"],
            capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        pair = transfer / "ci-pair"
        self.assertEqual(c.read(self.build / "logs/build.json")["toolchain"],
                         c.read(pair / "actual-toolchain.json"))
        self.assertEqual({"pair-request.json", "candidate-result.json", "pair-local.json",
                          "actual-toolchain.json", "integration-stages.json", "integration.xml",
                          "plugins.raw.xml", "Services/summary.json", "Services/fixture.log",
                          "Shell/summary.json", "Shell/fixture.log"},
                         {file.relative_to(pair).as_posix() for file in pair.rglob("*") if file.is_file()})

    def test_native_reuse_transfer_has_only_native_and_plugin_test_inputs(self):
        tests = self.build / "caelestia/src"
        tests.mkdir(parents=True)
        for name in ("fixture.exe", "fixture.dll", "CTestTestfile.cmake", "private.pdb", "object.obj"):
            (tests / name).write_bytes(b"inert")
        (self.build / "caelestia/CTestTestfile.cmake").write_bytes(b"inert")
        transfer = self.root / "reuse-transfer"
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
            str(ROOT / "windows/ci/Export-NexusCandidateInputs.ps1"), "-BuildRoot", str(self.build),
            "-OutputDirectory", str(transfer), "-Reuse"], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual({"b-public", "reuse-files.json"}, {p.name for p in transfer.iterdir()})
        restored = transfer / "b-public"
        c.check_native_outputs(restored, c.read(restored / "logs/build.json"))
        inventory = c.read(transfer / "reuse-files.json")
        self.assertEqual({p.relative_to(restored).as_posix() for p in restored.rglob("*") if p.is_file()},
                         {row["path"] for row in inventory})
        for row in inventory:
            self.assertEqual(c.digest(restored / row["path"]), row["sha256"])
            self.assertNotIn(Path(row["path"]).suffix, (".pdb", ".obj"))
            self.assertNotIn("ci-pair", row["path"])
        self.assertEqual(4, sum(row["path"].startswith("caelestia/") for row in inventory))

    def test_parallel_merge_finalize_and_envelope(self):
        module = p.validator(self.validator, c.read(self.shell / "windows/ci/pair-contract.json"))
        complete = c.read(self.results / "candidate-result.json")
        fixture = self.root / "fixtures"; fixture.mkdir()
        partials = []
        for owned, suites in (({"sources", "producer", "prepare", "configure", "build", "portable"},
                               {"producer", "portable"}),
                              ({"sources", "producer", "prepare", "integration"},
                               {"producer", "integration"})):
            receipt = copy.deepcopy(complete)
            receipt.update(finishedAt=None, workflowOutcome=None, result="incomplete")
            receipt["producer"] = {}
            receipt["toolchain"]["actual"] = {}
            empty = module.new_receipt("downstream", self.ctx["sha"], self.ctx["sha"])
            for stage in receipt["stages"]:
                if stage not in owned:
                    receipt["stages"][stage] = empty["stages"][stage]
            receipt["tests"] = {key: value for key, value in receipt["tests"].items() if key in suites}
            partials.append(receipt)
        p.write(fixture / "candidate-result.json", partials[0])
        p.write(self.results / "candidate-result.json", partials[1])
        shutil.copyfile(self.results / "portable.xml", fixture / "portable.xml")
        actual = complete["toolchain"]["actual"]
        p.write(fixture / "actual-toolchain.json", actual)
        p.write(self.results / "actual-toolchain.json", {**actual, "qtVersion": "wrong"})
        args = argparse.Namespace(fixture=str(fixture), results=str(self.results),
                                  shell=str(self.shell), validator=str(self.validator))
        with self.assertRaisesRegex(ValueError, "actual-toolchain-mismatch"):
            p.join(args)
        self.assertFalse((self.results / "integration-result.json").exists())
        p.write(self.results / "actual-toolchain.json", actual)
        p.join(args)
        finalized = subprocess.run([sys.executable, "-I", "-B", str(self.validator),
            "--receipt", str(self.results / "candidate-result.json"), "finalize",
            "--workflow-outcome", "success", "--toolchain", str(self.results / "actual-toolchain.json"),
            "--backend", str(self.shell / "windows/deps/quickshell"), "--shell", str(self.shell)],
            capture_output=True, text=True)
        self.assertEqual(0, finalized.returncode, finalized.stdout + finalized.stderr)
        args = argparse.Namespace(results=str(self.results), shell=str(self.shell), validator=str(self.validator),
            build_root=str(self.build), workflow_outcome="success", event="push", ref="refs/heads/main",
            run_id=self.ctx["runId"], attempt=self.ctx["runAttempt"], workflow_sha=self.ctx["sha"])
        self.assertEqual(0, p.envelope(args))
        self.assertTrue(c.read(self.results / "pair-result.json")["releaseEligible"])

    def test_transferred_allowlist_recomputes_evidence_and_excludes_unrelated_files(self):
        (self.build / "object.obj").write_bytes(b"not an assembly input")
        (self.results / "environment.json").write_text('{"private": true}')
        transfer = self.root / "transfer"
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                                 str(ROOT / "windows/ci/Export-NexusCandidateInputs.ps1"),
                                 "-BuildRoot", str(self.build), "-PairResults", str(self.results),
                                 "-OutputDirectory", str(transfer)], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        expected_build = {"logs/build.json", "quickshell/qs.exe", "install/caelestia-capture.exe",
                          "install/DesktopTakeover.dll"}
        expected_build.update(path.relative_to(self.build).as_posix()
                              for path in (self.build / "install/qml").rglob("*") if path.is_file())
        expected_pair = {"pair-request.json", "candidate-result.json", "pair-result.json",
                         "integration-stages.json", "portable.xml", "integration.xml", "plugins.raw.xml"}
        for suite in ("Services", "Shell"):
            expected_pair.add(f"{suite}/summary.json")
            expected_pair.update(f"{suite}/{row['name']}.log"
                                 for row in c.read(self.results / suite / "summary.json")["results"])
        self.assertEqual({f"b-public/{name}" for name in expected_build}
                         | {f"ci-pair/{name}" for name in expected_pair},
                         {path.relative_to(transfer).as_posix() for path in transfer.rglob("*") if path.is_file()})
        build, results = transfer / "b-public", transfer / "ci-pair"
        self.assertEqual("0.2.0-dev.1.8.2",
                         c.verify_live_evidence(self.shell, build, results, self.validator, self.ctx))
        output = self.root / "transferred-public"; output.mkdir()
        c.export_evidence(self.shell, build, results, self.validator, self.ctx, output)
        rerun = c.context(env({**self.ctx, "runAttempt": "3"}))
        with self.assertRaisesRegex(ValueError, "pair-run-mismatch"):
            c.verify_live_evidence(self.shell, build, results, self.validator, rerun)

    def test_forged_pass_boolean_cannot_hide_failed_receipt_or_outputs(self):
        receipt = c.read(self.results / "candidate-result.json")
        receipt["tests"]["portable"]["failed"] = 1
        n.write(self.results / "candidate-result.json", receipt)
        self.assertTrue(c.read(self.results / "pair-result.json")["releaseEligible"])
        with self.assertRaises(ValueError): self.verify()

    def test_actual_capture_bytes_not_an_edited_build_boolean(self):
        (self.build / "install/caelestia-capture.exe").write_bytes(b"changed")
        with self.assertRaises(ValueError): self.verify()

    def test_native_outputs_bound_before_validation_not_only_at_packaging(self):
        for name in ("quickshell/qs.exe", "install/DesktopTakeover.dll", "install/qml/Fixture/plugin.dll"):
            path = self.build / name
            original = path.read_bytes()
            path.write_bytes(b"not the tested output")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "native-bytes-changed"): self.verify()
            path.write_bytes(original)
        (self.build / "install/qml/unrecorded.dll").write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "incomplete-native-inventory"): self.verify()
    def test_wrong_validator_digest_prevents_execution(self):
        sentinel = self.root / "must-not-execute"
        self.validator.write_text(f"open({str(sentinel)!r}, 'w').write('unsafe')\n")
        with self.assertRaises(ValueError): self.verify()
        self.assertFalse(sentinel.exists())

    def test_equal_fake_tool_versions_with_real_spec_hash_are_rejected(self):
        receipt = c.read(self.results / "candidate-result.json")
        receipt["toolchain"]["expected"]["qtVersion"] = "1.0.0"
        receipt["toolchain"]["actual"]["qtVersion"] = "1.0.0"
        n.write(self.results / "candidate-result.json", receipt)
        args = argparse.Namespace(results=str(self.results), shell=str(self.shell), validator=str(self.validator),
                                  build_root=str(self.build), workflow_outcome="success", event="push",
                                  ref="refs/heads/main", run_id="12", attempt="2", workflow_sha=self.ctx["sha"])
        forged = p.compute_envelope(args)
        self.assertTrue(forged["releaseEligible"])  # Old generic envelope alone is insufficient.
        p.write(self.results / "pair-result.json", forged)
        with self.assertRaisesRegex(ValueError, "toolchain-version"): self.verify()

    def test_zero_plugin_inventory_refuses(self):
        (self.results / "plugins.raw.xml").write_text("<testsuite/>")
        with self.assertRaises(ValueError): self.verify()

    def test_suite_source_identity_and_version_digest_refuse(self):
        path = self.results / "Services/summary.json"
        summary = c.read(path); summary["sourceRevision"] = "e" * 40
        n.write(path, summary)
        with self.assertRaises(ValueError): self.verify()
        summary["sourceRevision"] = self.ctx["sha"]; n.write(path, summary)
        native = c.read(self.build / "logs/build.json"); native["versionFileSha256"] = "0" * 64
        n.write(self.build / "logs/build.json", native)
        with self.assertRaises(ValueError): self.verify()

    def test_candidate_run_attempt_and_mode_header_refuse(self):
        original = c.read(self.results / "pair-result.json")
        for field, value in (("pairMode", "candidate"), ("reasons", ["candidate-mode"]), ("releaseEligible", False)):
            changed = copy.deepcopy(original); changed[field] = value
            n.write(self.results / "pair-result.json", changed)
            with self.subTest(field=field), self.assertRaises(ValueError): self.verify()
        n.write(self.results / "pair-result.json", original)
        self.ctx["runAttempt"] = "3"
        with self.assertRaises(ValueError): self.verify()

    def test_source_dirty_refuses_before_assembly(self):
        (self.shell / "untracked.txt").write_text("not tested")
        with self.assertRaises(ValueError): self.verify()


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL).decode().strip()


def commit(root):
    git(root, "add", "--all")
    git(root, "-c", "user.name=Nexus Fixture", "-c", "user.email=fixture@example.invalid",
        "commit", "--quiet", "-m", "fixture")
    return git(root, "rev-parse", "HEAD")


def env(ctx):
    return {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": n.REPO, "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": ctx["sha"], "GITHUB_WORKFLOW_SHA": ctx["sha"],
            "GITHUB_WORKFLOW_REF": n.REPO + "/.github/workflows/windows-build.yml@refs/heads/main",
            "GITHUB_RUN_ID": ctx["runId"], "GITHUB_RUN_ATTEMPT": ctx["runAttempt"], "GITHUB_RUN_NUMBER": ctx["runNumber"]}


class FakeBranch:
    def __init__(self):
        self.keys = base64.b64decode(MATERIAL["keys"])
        self.documents, self.writes, self.conflicts, self.reads = {}, [], 0, 0
        self.on_conflict = None

    def read(self, channel):
        self.reads += 1
        return self.keys, self.documents.get(channel)

    def push(self, channel, raw):
        if self.conflicts:
            self.conflicts -= 1
            if self.on_conflict:
                self.on_conflict()
            return False
        self.documents[channel] = raw
        self.writes.append(channel)
        return True


class FakeGitHub:
    def __init__(self, ctx):
        self.ctx = ctx
        self.releases, self.bytes, self.writes = {}, {}, []
        self.next_id = 1
        self.fail_upload = None
        self.fail_download_once = False
        self.bad_run = None
        self.bad_job = None
        self.bad_artifact = False
        self.hide_drafts_by_tag = False
        self.tag_override = None

    def api(self, path, method="GET", body=None, missing=False):
        ctx = self.ctx
        if "/actions/runs/" in path:
            return {"id": int(ctx["runId"]), "run_attempt": int(ctx["runAttempt"]), "run_number": int(ctx["runNumber"]),
                    "event": self.bad_run or "push", "head_branch": "main", "head_sha": ctx["sha"],
                    "path": ".github/workflows/windows-build.yml", "repository": {"id": 7, "full_name": n.REPO},
                    "head_repository": {"full_name": n.REPO}, "status": "in_progress", "conclusion": None}
        if "/git/ref/tags/" in path:
            tag = path.split("/git/ref/tags/")[1]
            release = self.releases.get(tag)
            return ({"object": {"type": "commit", "sha": self.tag_override or release["target_commitish"]}}
                    if release and not release["draft"] else None)
        if "/releases/tags/" in path:
            release = self.releases.get(path.split("/releases/tags/")[1])
            return None if release and release["draft"] and self.hide_drafts_by_tag else copy.deepcopy(release)
        if "/releases?per_page=" in path:
            return copy.deepcopy(list(self.releases.values()))
        if method == "POST":
            self.writes.append(("create", body["tag_name"]))
            release = dict(body, id=self.next_id, assets=[])
            self.next_id += 1
            self.releases[body["tag_name"]] = release
            return copy.deepcopy(release)
        if method == "PATCH":
            release = next(row for row in self.releases.values() if row["id"] == int(path.split("/")[-1]))
            release["draft"] = False
            self.writes.append(("publish", release["tag_name"]))
            return copy.deepcopy(release)
        raise AssertionError("Unexpected GitHub API call")

    def pages(self, path, field):
        if field == "jobs":
            return [{"name": name, "head_sha": self.ctx["sha"],
                     "conclusion": "failure" if name == self.bad_job else "success"} for name in n.REQUIRED_JOBS]
        if field == "artifacts":
            return [{"name": f"nexus-candidate-{self.ctx['runId']}-{self.ctx['runAttempt']}",
                     "expired": self.bad_artifact, "workflow_run": {
                         "id": int(self.ctx["runId"]), "head_sha": self.ctx["sha"], "repository_id": 7}}]
        raise AssertionError("Unexpected GitHub page")

    def upload(self, tag, path):
        if self.fail_upload == len([row for row in self.writes if row[0] == "upload"]) + 1:
            raise ValueError("injected-upload-interruption")
        body = Path(path).read_bytes()
        asset = {"name": Path(path).name, "id": self.next_id, "size": len(body),
                 "digest": "sha256:" + hashlib.sha256(body).hexdigest()}
        self.next_id += 1
        self.bytes[asset["id"]] = body
        self.releases[tag]["assets"].append(asset)
        self.writes.append(("upload", asset["name"]))

    def download(self, asset, destination, expected):
        if self.fail_download_once:
            self.fail_download_once = False
            raise ValueError("injected-download-interruption")
        body = self.bytes[asset["id"]]
        n.require(len(body) == expected["size"] and hashlib.sha256(body).hexdigest() == expected["sha256"],
                  "remote-asset-hash-mismatch")
        with Path(destination).open("xb") as output:
            output.write(body)


class Pipeline(unittest.TestCase):
    def setUp(self):
        parent = os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT")
        self.temp = tempfile.TemporaryDirectory(prefix="nexus-pipeline-", dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"; self.work.mkdir()
        self.trust = self.root / "trust.json"
        n.write(self.trust, MATERIAL["trust"])
        self.crypto = n.Crypto(ROOT, self.work, self.trust, MATERIAL["dev"])
        self.branch = FakeBranch()
        self.ctx = {"repository": n.REPO, "event": "push", "ref": "refs/heads/main",
                    "workflow": ".github/workflows/windows-build.yml", "sha": "a" * 40,
                    "runId": "10", "runAttempt": "1", "runNumber": "5"}
        self.github = FakeGitHub(self.ctx)
        self.number = 0

    def candidate(self, core="0.2.0"):
        self.number += 1
        directory = self.root / f"candidate-{self.number}"; directory.mkdir()
        build = core + "-dev.1.5.1"
        root = f"caelestia-windows-{build}-windows-x64"
        for name in n.EVIDENCE | {root + ".zip"}:
            (directory / name).write_bytes(b"synthetic data, not native qualification")
        release = {"displayVersion": build, "buildVersion": build, "releaseId": build, "tag": "v" + build,
                   "sourceRevision": self.ctx["sha"], "backendRevision": "b" * 40, "manifestSha256": "c" * 64,
                   "profileSchema": 1, "minimumUpdaterSchema": 1,
                   "notesUrl": f"https://github.com/{n.REPO}/releases/tag/v{build}",
                   "bundle": {"name": root + ".zip", "root": root, "size": (directory / (root + ".zip")).stat().st_size,
                              "sha256": n.digest(directory / (root + ".zip")), "entries": 1, "unpackedSize": 20,
                              "url": f"https://github.com/{n.REPO}/releases/download/v{build}/{root}.zip"},
                   "provenance": {"runId": self.ctx["runId"], "runAttempt": self.ctx["runAttempt"],
                                  "pairResultSha256": n.digest(directory / "pair-result.json"),
                                  "candidateReceiptSha256": n.digest(directory / "candidate-result.json")}}
        doc = {"schema": "caelestia-nexus-candidate", "version": 1, "repository": n.REPO, "event": "push",
               "ref": "refs/heads/main", "workflow": ".github/workflows/windows-build.yml", "sourceRevision": self.ctx["sha"],
               **{key: self.ctx[key] for key in ("runId", "runAttempt", "runNumber")},
               "release": release, "assets": n.asset_rows(directory, n.EVIDENCE | {root + ".zip"}),
               "gates": n.GATES, "qualification": "component-offscreen-and-data-only-not-windows11-acceptance"}
        n.write(directory / "candidate.json", doc)
        return directory, doc

    def develop(self, directory):
        # Payload assembly/qualification is a recording external boundary here.
        # Its independent receipt validator has separate real-fixture controls.
        return n.development(directory, self.ctx, self.github, self.branch, self.crypto, ROOT, lambda _: None)

    def pointer(self, release, channel="development", sequence=1):
        payload = n.make_pointer(channel, release, None, 1)
        payload["sequence"] = sequence
        crypto = self.crypto if channel == "development" else n.Crypto(ROOT, self.work, self.trust, MATERIAL["promotion"])
        return crypto.invoke("SignChannel", channel, self.branch.keys, payload=payload)

    def test_context_refuses_pr_repo_workflow_sha_and_attempt(self):
        self.assertEqual(self.ctx, c.context(env(self.ctx)))
        for key, value in (("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_REPOSITORY", "fork/repo"),
                           ("GITHUB_REF", "refs/heads/feature"), ("GITHUB_WORKFLOW_SHA", "b" * 40),
                           ("GITHUB_RUN_ATTEMPT", "0"), ("GITHUB_RUN_NUMBER", "01"),
                           ("GITHUB_WORKFLOW_REF", "other")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                c.context(dict(env(self.ctx), **{key: value}))

    def test_default_entry_is_inert_without_context_or_keys(self):
        for mode in ("development", "promote", "refresh-development", "refresh-promotion"):
            result = subprocess.run([sys.executable, "-I", "-B", str(ROOT / "windows/ci/nexus_publish.py"),
                                     mode, "--shell", str(ROOT), "--work", str(self.root / "never")],
                                    capture_output=True, timeout=20, env={**os.environ, "NEXUS_SIGNING_KEY": ""})
            self.assertNotEqual(0, result.returncode)
            self.assertFalse((self.root / "never").exists())
        # Correct trusted context still refuses unconfigured shipped trust.
        environment = dict(os.environ, **env(self.ctx), NEXUS_DEVELOPMENT_PUBLISH="enabled",
                           NEXUS_SIGNING_KEY="test-only-not-a-key", GH_TOKEN="test-only-not-a-token")
        result = subprocess.run([sys.executable, "-I", "-B", str(ROOT / "windows/ci/nexus_publish.py"),
                                 "development", "--shell", str(ROOT), "--work", str(self.root / "never")],
                                capture_output=True, env=environment, timeout=20)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "never").exists())

    def test_candidate_binding_and_asset_negatives_before_writes(self):
        for mutation in ("run", "attempt", "sha", "event", "gate", "hash", "extra"):
            directory, doc = self.candidate()
            if mutation == "run": doc["runId"] = "11"
            elif mutation == "attempt": doc["runAttempt"] = "2"
            elif mutation == "sha": doc["sourceRevision"] = "e" * 40
            elif mutation == "event": doc["event"] = "pull_request"
            elif mutation == "gate": doc["gates"] = []
            elif mutation == "hash": (directory / "portable.xml").write_bytes(b"edited")
            else: (directory / "unlisted.txt").write_bytes(b"extra")
            n.write(directory / "candidate.json", doc)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.develop(directory)
            self.assertFalse(self.github.writes)
            self.assertFalse(self.branch.writes)

    def test_failed_or_foreign_run_artifact_never_publishes(self):
        for mutation in ("event", "job", "artifact"):
            directory, _ = self.candidate()
            self.github.bad_run = "pull_request" if mutation == "event" else None
            self.github.bad_job = next(iter(n.REQUIRED_JOBS)) if mutation == "job" else None
            self.github.bad_artifact = mutation == "artifact"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.develop(directory)
            self.assertFalse(self.github.writes)

    def test_publish_exact_bytes_and_idempotent_pointer(self):
        directory, doc = self.candidate()
        originals = {row["name"]: (directory / row["name"]).read_bytes() for row in doc["assets"]}
        self.assertEqual("published", self.develop(directory))
        release = self.github.releases[doc["release"]["tag"]]
        self.assertFalse(release["draft"])
        for asset in release["assets"]:
            if asset["name"] in originals:
                self.assertEqual(originals[asset["name"]], self.github.bytes[asset["id"]])
        directory2, _ = self.candidate()
        writes = list(self.github.writes)
        self.assertEqual("unchanged", self.develop(directory2))
        self.assertEqual(writes, self.github.writes)

    def test_partial_draft_recovery_and_randomized_record_reuse(self):
        self.github.hide_drafts_by_tag = True
        directory, doc = self.candidate()
        self.github.fail_download_once = True  # After all uploads, before publish.
        with self.assertRaises(ValueError):
            self.develop(directory)
        release = self.github.releases[doc["release"]["tag"]]
        self.assertTrue(release["draft"])
        record = next(row for row in release["assets"] if row["name"] == "release-record.dsse.json")
        record_bytes = self.github.bytes[record["id"]]
        directory2, _ = self.candidate()
        self.assertEqual("published", self.develop(directory2))
        self.assertEqual(record_bytes, self.github.bytes[record["id"]])
        self.assertEqual(1, len([row for row in self.github.writes if row == ("upload", "release-record.dsse.json")]))

    def test_partial_missing_upload_resumes_without_clobber(self):
        directory, _ = self.candidate()
        self.github.fail_upload = 3
        with self.assertRaises(ValueError):
            self.develop(directory)
        self.assertEqual(2, len([row for row in self.github.writes if row[0] == "upload"]))
        self.github.fail_upload = None
        directory2, _ = self.candidate()
        self.assertEqual("published", self.develop(directory2))
        names = [row[1] for row in self.github.writes if row[0] == "upload"]
        self.assertEqual(len(names), len(set(names)))

    def test_wrong_existing_bytes_fail_and_never_clobber(self):
        directory, doc = self.candidate()
        self.github.fail_download_once = True
        with self.assertRaises(ValueError): self.develop(directory)
        release = self.github.releases[doc["release"]["tag"]]
        asset = next(row for row in release["assets"] if row["name"] == doc["release"]["bundle"]["name"])
        self.github.bytes[asset["id"]] = b"corrupt"
        writes = list(self.github.writes)
        directory2, _ = self.candidate()
        with self.assertRaises(ValueError): self.develop(directory2)
        self.assertEqual(writes, self.github.writes)
        self.assertFalse(self.branch.writes)

    def test_tag_race_at_publish_never_exposes_pointer(self):
        directory, _ = self.candidate()
        self.github.tag_override = "0" * 40
        with self.assertRaisesRegex(ValueError, "tag-target-mismatch"): self.develop(directory)
        self.assertFalse(self.branch.writes)

    def test_invalid_pointer_is_not_first_publication(self):
        directory, _ = self.candidate()
        self.branch.documents["development"] = b'{"not":"signed"}'
        with self.assertRaises(ValueError): self.develop(directory)
        self.assertFalse(self.github.writes)

    def test_supersession_same_version_payload_and_non_descendant(self):
        directory, doc = self.candidate()
        newer = copy.deepcopy(doc["release"])
        for field in ("displayVersion", "buildVersion", "releaseId"):
            newer[field] = "0.2.0-dev.1.6.1"
        newer["tag"] = "v" + newer["buildVersion"]
        z = "caelestia-windows-" + newer["buildVersion"] + "-windows-x64"
        newer["bundle"].update(name=z + ".zip", root=z,
                              url=f"https://github.com/{n.REPO}/releases/download/{newer['tag']}/{z}.zip")
        newer["notesUrl"] = f"https://github.com/{n.REPO}/releases/tag/{newer['tag']}"
        self.branch.documents["development"] = self.pointer(newer)
        self.assertEqual("superseded", self.develop(directory))
        self.assertFalse(self.github.writes)
        changed = copy.deepcopy(doc["release"]); changed["bundle"]["sha256"] = "0" * 64
        self.branch.documents["development"] = self.pointer(changed)
        with self.assertRaises(ValueError): self.develop(directory)
        older = copy.deepcopy(doc["release"])
        for field in ("displayVersion", "buildVersion", "releaseId"): older[field] = "0.2.0-dev.1.4.1"
        older["tag"] = "v" + older["buildVersion"]
        z = "caelestia-windows-" + older["buildVersion"] + "-windows-x64"
        older["bundle"].update(name=z + ".zip", root=z, url=f"https://github.com/{n.REPO}/releases/download/{older['tag']}/{z}.zip")
        older["notesUrl"] = f"https://github.com/{n.REPO}/releases/tag/{older['tag']}"
        self.branch.documents["development"] = self.pointer(older)
        with patch.object(n, "ancestor", return_value=False), self.assertRaises(ValueError):
            self.develop(directory)
        self.assertFalse(self.github.writes)

    def test_pointer_cas_rereads_and_bounds_retries(self):
        directory, _ = self.candidate()
        self.branch.conflicts = 1
        self.assertEqual("published", self.develop(directory))
        self.assertGreaterEqual(self.branch.reads, 2)
        self.assertEqual(1, len([row for row in self.github.writes if row[0] == "create"]))
        self.branch.documents.clear(); self.branch.conflicts = 3
        directory2, _ = self.candidate()
        with self.assertRaisesRegex(ValueError, "cas-exhausted"): self.develop(directory2)

    def test_all_channel_refresh_expired_rotation_and_revocation(self):
        for channel in ("development", "preview", "stable"):
            self.branch.documents[channel] = base64.b64decode(MATERIAL["historical"][channel])
        promotion = n.Crypto(ROOT, self.work, self.trust, MATERIAL["promotion"])
        for channel, crypto in (("development", self.crypto), ("preview", promotion), ("stable", promotion)):
            before = crypto.invoke("ReadChannel", channel, self.branch.keys, document=self.branch.documents[channel])
            self.assertEqual("refreshed", n.refresh(channel, self.branch, crypto))
            after = crypto.invoke("ReadChannel", channel, self.branch.keys, document=self.branch.documents[channel])
            self.assertEqual(before["release"], after["release"])
            self.assertEqual(before["sequence"] + 1, after["sequence"])
        self.branch.keys = base64.b64decode(MATERIAL["keys2"])
        self.assertEqual("refreshed", n.refresh("development", self.branch, self.crypto))
        renewed = self.crypto.invoke("ReadChannel", "development", self.branch.keys, document=self.branch.documents["development"])
        self.assertEqual(2, renewed["keysVersion"])
        writes = list(self.branch.writes)
        self.branch.keys = base64.b64decode(MATERIAL["revoked"])
        with self.assertRaises(ValueError): n.refresh("development", self.branch, self.crypto)
        self.assertEqual(writes, self.branch.writes)
        self.branch.keys = base64.b64decode(MATERIAL["expiredKeys"])
        with self.assertRaises(ValueError): n.refresh("stable", self.branch, promotion)

    def test_dev_key_cannot_refresh_promotion_and_missing_is_not_seeded(self):
        self.assertEqual("not-configured", n.refresh("stable", self.branch, self.crypto))
        self.assertFalse(self.branch.writes)
        for channel in ("preview", "stable"):
            self.branch.documents[channel] = base64.b64decode(MATERIAL["historical"][channel])
            with self.assertRaises(ValueError): n.refresh(channel, self.branch, self.crypto)
        self.assertFalse(self.branch.writes)

    def test_distinct_delegated_threshold_signatures(self):
        _, doc = self.candidate()
        payload = n.make_pointer("development", doc["release"], None, 2)
        keys = base64.b64decode(MATERIAL["threshold"])
        with self.assertRaises(ValueError):
            self.crypto.invoke("SignChannel", "development", keys, payload=payload)
        crypto = n.Crypto(ROOT, self.work, self.trust, json.dumps([MATERIAL["dev"], MATERIAL["secondDev"]]))
        raw = crypto.invoke("SignChannel", "development", keys, payload=payload)
        self.assertEqual(2, crypto.invoke("ReadChannel", "development", keys, document=raw)["keysVersion"])

    def test_promote_identical_bytes_preview_then_stable_1_plus(self):
        directory, doc = self.candidate("1.0.0")
        self.assertEqual("published", self.develop(directory))
        promotion = n.Crypto(ROOT, self.work, self.trust, MATERIAL["promotion"])
        originals = {path.name: path.read_bytes() for path in directory.iterdir()}
        for channel, alias in (("preview", "1.0.0-preview.1"), ("stable", "1.0.0")):
            with patch.object(n, "ancestor", return_value=True), patch.object(n.pair, "git", return_value=self.ctx["sha"]):
                self.assertEqual("published", n.promote(directory, doc["release"]["buildVersion"], channel, alias,
                                                       self.github, self.branch, promotion, ROOT, lambda _: None))
            target = self.github.releases["v" + alias]
            for asset in target["assets"]:
                if asset["name"] != "alias-record.dsse.json":
                    self.assertEqual(originals[asset["name"]], self.github.bytes[asset["id"]])
            # Next promotion starts from immutable development assets only.
            (directory / "alias-record.dsse.json").unlink()

    def test_promotion_rejects_core_relabel_stable_zero_and_bad_alias(self):
        directory, doc = self.candidate()
        for channel, alias in (("stable", "1.0.0"), ("stable", "0.2.0"), ("preview", "0.3.0-preview.1"),
                               ("preview", "0.2.0-preview.01")):
            with self.subTest(alias=alias), self.assertRaises(ValueError):
                n.promote(directory, doc["release"]["buildVersion"], channel, alias,
                          self.github, self.branch, self.crypto, ROOT, lambda _: None)
        self.assertFalse(self.github.writes)

    def test_real_bare_git_fast_forward_cas(self):
        bare, seed = self.root / "bare.git", self.root / "seed"
        subprocess.check_call(["git", "init", "--bare", "--quiet", str(bare)])
        subprocess.check_call(["git", "init", "--quiet", str(seed)])
        (seed / "v1").mkdir()
        (seed / "v1/keys.dsse.json").write_bytes(self.branch.keys)
        commit(seed)
        git(seed, "push", "--quiet", str(bare), "HEAD:refs/heads/nexus-channels")
        for name in ("one", "two"): (self.root / name).mkdir()
        one = n.ChannelBranch(self.root / "one", str(bare))
        two = n.ChannelBranch(self.root / "two", str(bare))
        one.read("development"); two.read("development")
        self.assertTrue(one.push("development", b"first"))
        self.assertFalse(two.push("development", b"stale"))
        self.assertEqual(b"first", two.read("development")[1])
        self.assertTrue(two.push("development", b"second"))

    def test_source_zip_paths_and_inventory_caps(self):
        for index, name in enumerate(("../x", "/x", "C:/x", "a\\b", "CON", "a.", "a ")):
            archive = self.root / f"unsafe-{index}.zip"
            entry = zipfile.ZipInfo("placeholder")
            entry.filename = name  # Bypass the writer's Windows normalization.
            with zipfile.ZipFile(archive, "w") as stream: stream.writestr(entry, b"data")
            target = self.root / f"extract-{index}"
            with self.subTest(name=name), self.assertRaises(ValueError): n.extract_source(archive, target)
            self.assertFalse(target.exists())

    def test_actual_gh_adapter_auth_missing_json_and_upload_controls(self):
        github = n.GitHub()
        for code in (401, 403):
            response = subprocess.CompletedProcess([], 1, b"", f"HTTP {code}".encode())
            with self.subTest(code=code), patch.object(n.subprocess, "run", return_value=response) as call:
                with self.assertRaises(PermissionError): github.api("fixture", missing=True)
                self.assertEqual(1, call.call_count)  # No auth retry or login.
        response = subprocess.CompletedProcess([], 1, b"", b"HTTP 404")
        with patch.object(n.subprocess, "run", return_value=response):
            self.assertIsNone(github.api("fixture", missing=True))
            with self.assertRaises(ValueError): github.api("fixture")
        response = subprocess.CompletedProcess([], 0, b'{"id":1,"ID":2}', b"")
        with patch.object(n.subprocess, "run", return_value=response):
            with self.assertRaisesRegex(ValueError, "ambiguous-json"): github.api("fixture")
        response = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(n.subprocess, "run", return_value=response) as call:
            github.upload("v0.2.0-dev.1.1.1", self.root / "inert.zip")
            argv = call.call_args.args[0]
            self.assertEqual(["gh", "release", "upload"], argv[:3])
            self.assertNotIn("--clobber", argv)
            self.assertEqual(n.REPO, argv[-1])

    def test_actual_gh_download_stream_size_and_hash_controls(self):
        github = n.GitHub()
        body = b"inert fixture transport body"
        expected = {"size": len(body), "sha256": hashlib.sha256(body).hexdigest()}
        popen = subprocess.Popen
        for index, actual in enumerate((body, body[:-1], body + b"x", b"x" * len(body))):
            target = self.root / f"transport-{index}"
            def transport(argv, **kwargs):
                self.assertEqual("gh", argv[0])
                self.assertIn("Accept: application/octet-stream", argv)
                self.assertEqual(f"repos/{n.REPO}/releases/assets/7", argv[-1])
                return popen([sys.executable, "-I", "-c",
                              "import sys;sys.stdout.buffer.write(" + repr(actual) + ")"], **kwargs)
            with patch.object(n.subprocess, "Popen", side_effect=transport):
                if index == 0:
                    github.download({"id": 7, "size": len(body)}, target, expected)
                    self.assertEqual(body, target.read_bytes())
                else:
                    with self.assertRaises(ValueError):
                        github.download({"id": 7, "size": len(body)}, target, expected)

    def test_workflow_boundaries_and_template(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_bytes()
        self.assertEqual(workflow, (ROOT / "windows/ci/windows-build.yml.template").read_bytes())
        text = workflow.decode().replace("\r\n", "\n")
        before, publish = text.split("\n  publish:\n")
        self.assertNotIn("secrets.", before)
        self.assertNotIn("contents: write", before)
        self.assertIn("needs: [candidate, validation]", publish)
        scope = text.split("\n  scope:\n")[1].split("\n  checks:\n")[0]
        self.assertIn("runs-on: ubuntu-24.04", scope)
        self.assertIn("fetch-depth: 0", scope)
        self.assertIn("Refuse mutable dispatch inputs", scope)
        self.assertIn("Get-NativeBuildRequired.ps1", scope)
        for job, next_job in (("checks", "packaging"), ("packaging", "reuse"),
                              ("fixtures", "build"), ("build", "pair")):
            block = text.split(f"\n  {job}:\n")[1].split(f"\n  {next_job}:\n")[0]
            if job in ("fixtures", "build"):
                self.assertIn("needs: [scope, reuse]", block)
            else:
                self.assertNotIn("needs:", block)
                guard = scope.split("    steps:\n")[1].split("      - name: Checkout")[0]
                self.assertTrue(block.split("    steps:\n")[1].startswith(guard))
            self.assertNotIn("Get-NativeBuildRequired.ps1", block)
            self.assertNotIn("New-NexusCandidate.ps1", block)
        validation, candidate = text.split("\n  validation:\n")[1].split("\n  candidate:\n")
        candidate = candidate.split("\n  publish:\n")[0]
        self.assertIn("needs: [scope, checks, packaging, reuse, fixtures, build, pair]", validation)
        for shard in (1, 2):
            self.assertIn(f"Installer and colour regressions ({shard}/2)", n.REQUIRED_JOBS)
            self.github.bad_job = f"Installer and colour regressions ({shard}/2)"
            with self.assertRaisesRegex(ValueError, "required-job-nonpass"):
                n.validate_run(self.github, self.ctx)
        self.github.bad_job = None
        self.assertNotIn("candidate", validation.lower())
        self.assertIn("needs.scope.outputs.native", validation)
        self.assertIn("-notin @('none', 'reuse', 'full')", validation)
        self.assertIn("needs: [scope, pair, validation]", candidate)
        # The PR-only reuse job is a skipped ancestor on every main push; an
        # implicit success() would silently skip delivery (main run 42411463069).
        publish = text.split("\n  publish:\n")[1]
        for job in (candidate, publish):
            self.assertIn("if: >-\n      !cancelled() && github.event_name == 'push'", job)
        # Eligibility rechecks backend-main ancestry; only pair resolution
        # fetches that ref, so it must run before the trusted bootstrap.
        self.assertLess(candidate.index("Resolve-PairRequest.ps1"), candidate.index("pair_result.py\" bootstrap"))
        for condition in ("needs.validation.result == 'success'", "needs.pair.result == 'success'",
                          "needs.scope.result == 'success'", "needs.scope.outputs.native == 'full'",
                          "github.event_name == 'push'", "github.ref == 'refs/heads/main'"):
            self.assertIn(condition, candidate)
        self.assertIn("New-NexusCandidate.ps1", candidate)
        self.assertNotIn("actions/cache/save@", candidate)
        saves = re.findall(r"        if: ([^\n]+)\n        uses: actions/cache/save@", text)
        self.assertEqual(4, text.count("actions/cache/save@"))
        self.assertEqual(4, len(saves))
        for condition in saves:
            self.assertIn("github.ref == 'refs/heads/main' && github.event_name == 'push'", condition)
            self.assertNotIn("||", condition)
        self.assertEqual(4, text.count("key: windows-x64-tools-contract-v1-py"))
        self.assertIn("name: nexus-inputs-${{ github.run_id }}-${{ github.run_attempt }}", candidate)
        self.assertIn("path: C:/", candidate)
        build = text.split("\n  build:\n")[1].split("\n  pair:\n")[0]
        self.assertIn("retention-days: 1\n", build)
        fixtures = text.split("\n  fixtures:\n")[1].split("\n  build:\n")[0]
        pair = text.split("\n  pair:\n")[1].split("\n  validation:\n")[0]
        self.assertIn("Test-CaptureRust.ps1", fixtures)
        self.assertIn("name: capture-rust-${{ github.run_id }}-${{ github.run_attempt }}", fixtures)
        for job in (build, pair, candidate, publish):
            self.assertNotIn("ci-capture", job)
            self.assertNotIn("capture-rust", job)
        self.assertIn("needs: [scope, fixtures, build]", pair)
        self.assertIn("needs.fixtures.result == 'success' && needs.build.result == 'success'", pair)
        self.assertIn("Require identical actual toolchains", pair)
        self.assertIn('pair_result.py" join', pair)
        for command in ('pair_result.py" join', 'candidate-result.json" finalize', 'pair_result.py" envelope'):
            self.assertEqual(1, text.count(command))
            self.assertIn(command, pair)
        self.assertIn("--stage $phase --echo", fixtures)
        self.assertNotIn("--stage $phase", build)
        self.assertEqual(1, fixtures.count("actions/cache/save@"))
        self.assertIn("name: nexus-inputs-${{ github.run_id }}-${{ github.run_attempt }}", pair)
        self.assertIn("vars.NEXUS_DEVELOPMENT_PUBLISH == 'enabled'", publish)
        self.assertIn("environment: nexus-development", publish)
        self.assertIn("cancel-in-progress: false", publish)
        self.assertNotIn("workflow_run", text)
        self.assertNotIn("pull_request_target", text)
        self.assertIn("actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131", text)
        self.assertIn("path: C:/nexus-candidate/private/*.state.json", text)
        self.assertNotIn("path: C:/nexus-candidate/private/*.log", text)
        for file in ("nexus-promote.yml", "nexus-refresh.yml"):
            text = (ROOT / ".github/workflows" / file).read_text()
            self.assertNotIn("workflow_run", text)
            self.assertNotIn("self-hosted", text)
            self.assertIn("NEXUS_PROMOTION_PUBLISH == 'enabled'", text)
            self.assertIn("environment: nexus-promotion", text)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    if suite.countTestCases() < 41:
        raise SystemExit("Nexus behavioral test inventory unexpectedly reduced.")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() and result.testsRun >= 32 and not result.skipped else 1)
