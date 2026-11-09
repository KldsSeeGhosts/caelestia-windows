"""Shadow artifacts cannot replace canonical acceptance or silently fall back."""
import copy
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "windows/ci"))
import nexus_shadow as shadow


class ShadowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="shadow-assembly-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shell, self.build, self.work, self.canonical = (
            self.root / name for name in ("shell", "build", "work", "canonical"))
        self.ctx = {"repository": shadow.candidate.REPOSITORY, "event": "push", "ref": "refs/heads/main",
                    "workflow": ".github/workflows/windows-build.yml", "sha": "a" * 40,
                    "runId": "10", "runAttempt": "2", "runNumber": "5"}
        self.put(self.shell / "windows/release/version.json", {"version": "1.2.3", "developmentEpoch": 1})
        self.native = []
        for name in ("quickshell/qs.exe", "install/caelestia-capture.exe", "install/DesktopTakeover.dll",
                     "install/qml/Caelestia/module.dll"):
            self.put(self.build / name, b"tested-native")
            self.native.append({"path": name, "sha256": shadow.digest(self.build / name)})
        self.record = {"nativeInputs": self.native, "sourceRevision": self.ctx["sha"], "sourceDirty": False}
        self.put(self.build / "logs/build.json", self.record)
        self.name = "caelestia-windows-" + shadow.identity(self.shell, self.ctx) + "-windows-x64"
        self.put(self.work / "sources/component-inventory.json", {"source": "verified-sources"})
        self.put(self.work / "assembly" / (self.name + ".zip"), b"synthetic-zip")
        self.put(self.work / "assembly" / self.name / "release.json", {"sourceRevision": self.ctx["sha"]})
        self.put(self.work / "coverage/component-inventory.json", {"payload": "covered"})
        self.put(self.work / "private/native-snapshot.json", {
            "buildSha256": shadow.digest(self.build / "logs/build.json"), "nativeInputs": self.native})
        self.rows = [{"name": name, "outcome": "success", "exitCode": 0} for name in shadow.JOURNAL]
        self.results = self.root / "results"
        self.put(self.results / "integration-stages.json", self.rows)
        self.value = {"shell": str(self.shell), "build": str(self.build), "results": str(self.results),
                      "run": self.ctx, "job": "Local\\CaelestiaShadow-10-2-" + uuid.uuid4().hex,
                      "jobDeadline": int(time.time()) + 6600}
        self.put(self.work / "private/config.json", self.value)
        for name, budget in shadow.STAGES.items():
            self.put(self.work / "private" / (name + ".state.json"),
                     {"stage": name, "outcome": "success", "exitCode": 0, "seconds": 1,
                      "timeoutSeconds": budget})

    def put(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else json.dumps(value).encode())

    def export(self):
        with patch.object(shadow.candidate.pair, "git", side_effect=[self.ctx["sha"], ""]):
            shadow.export(self.work, self.value, self.ctx)

    def verify(self, ctx=None):
        return shadow.verify(self.work / "out", self.shell, self.build, self.work / "sources", ctx or self.ctx)

    def test_verified_round_trip_is_consistency_data_not_release_evidence(self):
        self.export()
        self.assertEqual(self.ctx, self.verify()["run"])
        self.assertEqual({shadow.PROOF, "release.json", "component-inventory.json", self.name + ".zip"},
                         {path.name for path in (self.work / "out").iterdir()})
        self.assertNotIn(str(self.root), (self.work / "out" / shadow.PROOF).read_text())
        self.assertEqual("shadow-only-not-release-evidence", self.verify()["qualification"])

    def test_wrong_run_attempt_sha_and_changed_source_or_native_are_refused(self):
        self.export()
        for key in ("runId", "runAttempt", "sha"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify({**self.ctx, key: "wrong"})
        original = (self.build / self.native[0]["path"]).read_bytes()
        self.put(self.build / self.native[0]["path"], b"changed")
        with self.assertRaisesRegex(ValueError, "tested-native-bytes-changed"):
            self.verify()
        self.put(self.build / self.native[0]["path"], original)
        self.put(self.work / "sources/component-inventory.json", {"wrong": True})
        with self.assertRaisesRegex(ValueError, "shadow-sources-mismatch"):
            self.verify()

    def test_altered_zip_missing_file_extra_file_or_forged_gate_is_refused(self):
        self.export()
        zip_path = self.work / "out" / (self.name + ".zip")
        self.put(zip_path, b"one-changed-byte")
        with self.assertRaisesRegex(ValueError, "shadow-bytes-mismatch"):
            self.verify()
        self.put(zip_path, b"synthetic-zip")
        path = self.work / "out/release.json"
        original = path.read_bytes()
        path.unlink()
        with self.assertRaises(ValueError):
            self.verify()
        self.put(path, original)
        extra = self.work / "out/private.log"
        self.put(extra, b"unapproved")
        with self.assertRaisesRegex(ValueError, "shadow-file-inventory"):
            self.verify()
        extra.unlink()
        proof_path = self.work / "out" / shadow.PROOF
        original = shadow.read(proof_path)
        for field, value in (("outcome", "failure"), ("exitCode", True), ("seconds", -1),
                             ("timeoutSeconds", 3600)):
            document = copy.deepcopy(original)
            document["gates"][0][field] = value
            self.put(proof_path, document)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "shadow-gate-nonpass"):
                self.verify()

    def test_no_readiness_until_both_preconditions_succeed_and_failures_refuse(self):
        rows = copy.deepcopy(self.rows)
        rows[2]["outcome"], rows[2]["exitCode"] = "running", None
        self.assertFalse(shadow.production_ready(None))
        self.assertFalse(shadow.production_ready(rows))
        rows[2]["outcome"], rows[2]["exitCode"] = "success", 0
        self.assertTrue(shadow.production_ready(rows))
        rows[4]["outcome"], rows[4]["exitCode"] = "failure", 1
        with self.assertRaisesRegex(ValueError, "shadow-integration-nonpass"):
            shadow.production_ready(rows)

    def test_join_terminates_only_owned_job_on_success_failure_and_timeout(self):
        for mode in ("ready", "failed", "waiting"):
            shadow.state(self.work, self.ctx, mode, "fixture")
            with self.subTest(mode=mode), patch.object(shadow.nexus_job, "terminate") as terminate:
                with patch.object(shadow.candidate.pair, "git", side_effect=[self.ctx["sha"], ""]):
                    result = shadow.join(self.work, self.ctx, True, timeout=0)
                self.assertEqual(0 if mode == "ready" else 1, result)
                terminate.assert_called_once_with(self.value["job"])
        shadow.state(self.work, self.ctx, "waiting", "fixture")
        with patch.object(shadow.nexus_job, "terminate") as terminate:
            self.assertEqual(1, shadow.join(self.work, self.ctx, False))
            terminate.assert_called_once_with(self.value["job"])
        self.value["jobDeadline"] = int(time.time()) - 1
        self.put(self.work / "private/config.json", self.value)
        shadow.state(self.work, self.ctx, "waiting", "fixture")
        with patch.object(shadow.nexus_job, "terminate") as terminate:
            self.assertEqual(1, shadow.join(self.work, self.ctx, True))
            terminate.assert_called_once_with(self.value["job"])

    @unittest.skipUnless(os.name == "nt", "Windows delete sharing")
    def test_polled_readers_do_not_block_powershell_journal_or_shadow_state_replace(self):
        path, replacement = self.root / "journal.json", self.root / "journal.tmp"
        self.put(path, {"generation": 1})
        self.put(replacement, {"generation": 2})
        quote = lambda value: "'" + str(value).replace("'", "''") + "'"
        with shadow.nexus_job.open_shared(path) as stream:
            result = subprocess.run(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                 "$ErrorActionPreference='Stop'; Move-Item -LiteralPath " + quote(replacement)
                 + " -Destination " + quote(path) + " -Force"],
                capture_output=True, text=True, timeout=10, creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual({"generation": 1}, json.loads(stream.read()))
            self.assertEqual({"generation": 2}, shadow.shared_read(path))
        with shadow.nexus_job.open_shared(path) as stream:
            shadow.atomic(path, {"generation": 3})
            self.assertEqual({"generation": 2}, json.loads(stream.read()))
            self.assertEqual({"generation": 3}, shadow.shared_read(path))
        self.put(path, b'{"status": "ready", "Status": "failed"}')
        with self.assertRaisesRegex(ValueError, "ambiguous-json"):
            shadow.shared_read(path)

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell initialization")
    def test_real_shadow_wrapper_initializes_inbox_modules_from_restricted_parent(self):
        # Only fake gate scripts run here. The real wrapper, runner, inbox
        # modules, hashes, ZIP expansion and four state records are exercised.
        self.put(self.shell / "windows/toolchain.json", {"qtDirectory": "synthetic-qt"})
        wrapper = self.root / "wrapper"
        self.put(wrapper / "sources/component-inventory.json", {"fixture": True})
        (wrapper / "private").mkdir()
        assembly = r'''
param($BuildRoot,$ReleaseId,$OutputDirectory,$SupplementalNoticesRoot,$QtPrefix)
$ErrorActionPreference='Stop'
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1"
$name="caelestia-windows-$ReleaseId-windows-x64"
$bundle=Join-Path $OutputDirectory $name
[IO.Directory]::CreateDirectory($bundle) | Out-Null
[IO.File]::WriteAllText("$bundle\release.json", '{"fixture":true}')
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$archive=[IO.Compression.ZipFile]::Open("$OutputDirectory\$name.zip", [IO.Compression.ZipArchiveMode]::Create)
try {
    $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, "$bundle\release.json", "$name/release.json")
} finally { $archive.Dispose() }
'''
        coverage = r'''
param($AssetsRoot,$BundleRoot,$ExpectedInventorySha256,$ExpectedManifestSha256,$CoverageOutputDirectory)
$ErrorActionPreference='Stop'
[IO.Directory]::CreateDirectory($CoverageOutputDirectory) | Out-Null
[IO.File]::WriteAllText("$CoverageOutputDirectory\component-inventory.json", '{"fixture":true}')
'''
        verify = r'''
param($BundleRoot,[switch]$VerifyOnly,$ExpectedManifestSha256)
if (-not $VerifyOnly -or -not [IO.File]::Exists("$BundleRoot\release.json")) { exit 1 }
'''
        for name, script in (("New-CaelestiaRelease.ps1", assembly),
                             ("Prepare-CaelestiaSourceAssets.ps1", coverage),
                             ("Test-InstallLicenses.ps1",
                              "param($BuildRoot,$QtPrefix,[switch]$NoIntegration)\nif(-not $NoIntegration){exit 1}"),
                             ("Install-CaelestiaRelease.ps1", verify)):
            self.put(self.shell / "windows/scripts" / name, script.encode())
        environment = dict(os.environ, PSModulePath=str(self.root / "no-inbox-modules"))
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
             str(ROOT / "windows/ci/Invoke-NexusShadowAssembly.ps1"), "-ShellRoot", str(self.shell),
             "-BuildRoot", str(self.build), "-ToolRoot", str(self.root / "tools"),
             "-OutputDirectory", str(wrapper), "-ReleaseId", shadow.identity(self.shell, self.ctx),
             "-Python", sys.executable], env=environment, capture_output=True, text=True,
            timeout=45, creationflags=subprocess.CREATE_NO_WINDOW)
        assembly_log = wrapper / "private/assembly.log"
        detail = assembly_log.read_text(encoding="utf-8-sig", errors="replace") if assembly_log.exists() else ""
        self.assertEqual(0, result.returncode, result.stdout + result.stderr + detail)
        for name, budget in shadow.STAGES.items():
            shadow.check_stage(shadow.read(wrapper / "private" / (name + ".state.json")), name, budget)

    def test_final_source_dirt_native_mutation_and_failed_gate_block_export(self):
        with patch.object(shadow.candidate.pair, "git", side_effect=[self.ctx["sha"], " M shell.qml"]):
            with self.assertRaisesRegex(ValueError, "shadow-source-dirty"):
                shadow.export(self.work, self.value, self.ctx)
        self.put(self.build / self.native[0]["path"], b"changed")
        with self.assertRaises(ValueError):
            self.export()
        self.put(self.build / self.native[0]["path"], b"tested-native")
        path = self.work / "private/license-lifecycle.state.json"
        document = shadow.read(path)
        document["exitCode"], document["outcome"] = 1, "failure"
        self.put(path, document)
        with self.assertRaisesRegex(ValueError, "shadow-gate-nonpass"):
            self.export()
        self.assertFalse((self.work / "out").exists())

    def canonical_fixture(self):
        for source, target in (
                (self.work / "out" / (self.name + ".zip"), self.canonical / "out" / (self.name + ".zip")),
                (self.work / "out/release.json", self.canonical / "assembly" / self.name / "release.json"),
                (self.work / "out/component-inventory.json", self.canonical / "out/component-inventory.json"),
                (self.work / "sources/component-inventory.json", self.canonical / "sources/component-inventory.json")):
            self.put(target, source.read_bytes())

    def compare(self, status="ready", transfer=None):
        report = self.root / "comparison.json"
        result = shadow.compare(status, transfer or self.work / "out", self.shell, self.build,
                                self.canonical, report, self.ctx)
        return result, shadow.read(report)

    def test_comparison_demands_all_three_exact_hashes_without_mutating_candidate(self):
        self.export()
        self.canonical_fixture()
        self.assertEqual("equal", self.compare()[1]["result"])
        self.put(self.canonical / "out" / (self.name + ".zip"), b"different-canonical")
        result, document = self.compare()
        self.assertEqual(1, result)
        self.assertEqual("mismatch", document["result"])
        self.assertEqual({"zip": False, "manifest": True, "coverage": True}, document["equal"])
        self.assertEqual(b"different-canonical",
                         (self.canonical / "out" / (self.name + ".zip")).read_bytes())

    def test_ready_missing_artifact_or_failed_never_become_fallback(self):
        self.assertEqual("failed", self.compare(transfer=self.root / "missing")[1]["result"])
        self.assertEqual("failed", self.compare("failed")[1]["result"])
        self.assertEqual("fallback", self.compare("fallback")[1]["result"])
        target = self.root / "not-ready"
        with patch.object(shadow.sources, "materialize") as materialize:
            shadow.start(self.shell, self.build, self.root / "tools", self.results, self.root / "transfer",
                         target, False, self.ctx)
            materialize.assert_not_called()
        self.assertEqual("fallback", shadow.read(target / "state.json")["status"])
        with patch.object(shadow.nexus_job, "terminate") as terminate:
            self.assertEqual(0, shadow.join(target, self.ctx, True))
            terminate.assert_not_called()

    def test_workflow_is_shadow_only_main_only_and_outside_pinned_integration(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual(workflow.encode(), (ROOT / "windows/ci/windows-build.yml.template").read_text().encode())
        build = workflow.split("\n  build:\n")[1].split("\n  pair:\n")[0]
        self.assertLess(build.index('nexus_shadow.py" start'), build.index("name: Exact-pair production integration"))
        self.assertLess(build.index("name: Exact-pair production integration"), build.index('nexus_shadow.py" join'))
        self.assertNotIn("actions: read", build)
        self.assertIn("SHADOW_JOB_DEADLINE=", build)
        self.assertNotIn("nexus_shadow", (ROOT / "windows/ci/Invoke-PairIntegration.ps1").read_text())
        candidate = workflow.split("\n  candidate:\n")[1].split("\n  publish:\n")[0]
        self.assertLess(candidate.index("New-NexusCandidate.ps1"), candidate.index('nexus_shadow.py" compare'))
        self.assertIn("Canonical acceptance is unchanged.", build)
        self.assertIn("Consumption remains disabled.", candidate)
        self.assertIn("needs: [scope, pair, validation, sources]", candidate)
        publisher = workflow.split("\n  publish:\n")[1]
        self.assertNotIn("shadow", publisher)


@unittest.skipUnless(os.name == "nt", "Windows-owned job tests")
class OwnedJobTests(unittest.TestCase):
    def test_normal_exit_and_abrupt_termination_kill_descendants_with_below_normal_priority(self):
        # The script is intentionally not the production supervisor. Exercise
        # the OS lifetime invariant without build tools, GUI, sleeps in the
        # parent tool call or touching another process tree.
        for abrupt in (False, True):
            with self.subTest(abrupt=abrupt), tempfile.TemporaryDirectory(
                    prefix="owned-job-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT")) as temp:
                root = Path(temp)
                marker = root / "child.json"
                child = (
                    "import ctypes,json,os,time; from pathlib import Path; "
                    "api=ctypes.WinDLL('kernel32'); api.GetCurrentProcess.restype=ctypes.c_void_p; "
                    "api.GetPriorityClass.argtypes=[ctypes.c_void_p]; "
                    f"Path({str(marker)!r}).write_text(json.dumps("
                    "{'pid':os.getpid(),'priority':api.GetPriorityClass(api.GetCurrentProcess())})); "
                    "time.sleep(120)")
                script = (
                    "import subprocess,sys,time; from pathlib import Path; "
                    f"sys.path.insert(0,{str(ROOT / 'windows/ci')!r}); import nexus_job; "
                    f"job=nexus_job.OwnedJob('Local\\\\CaelestiaShadow-test-{uuid.uuid4().hex}'); "
                    f"p=subprocess.Popen([sys.executable,'-I','-B','-c',{child!r}],"
                    "creationflags=subprocess.CREATE_NO_WINDOW); "
                    f"marker=Path({str(marker)!r}); deadline=time.monotonic()+5\n"
                    "while not marker.exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
                    "assert marker.exists()\n"
                    + ("time.sleep(120)\n" if abrupt else ""))
                parent = subprocess.Popen([sys.executable, "-I", "-B", "-c", script],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          creationflags=subprocess.CREATE_NO_WINDOW)
                api = ctypes.WinDLL("kernel32", use_last_error=True)
                api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
                api.OpenProcess.restype = wintypes.HANDLE
                api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
                api.CloseHandle.argtypes = [wintypes.HANDLE]
                handle = None
                try:
                    deadline = time.monotonic() + 8
                    while not marker.exists() and time.monotonic() < deadline and parent.poll() is None:
                        time.sleep(0.02)
                    self.assertTrue(marker.exists(), parent.communicate(timeout=1) if parent.poll() is not None else "")
                    # The writer closes immediately after its small JSON write.
                    deadline = time.monotonic() + 2
                    while True:
                        try:
                            record = json.loads(marker.read_text())
                            break
                        except json.JSONDecodeError:
                            self.assertLess(time.monotonic(), deadline)
                            time.sleep(0.01)
                    self.assertEqual(0x4000, record["priority"])
                    handle = api.OpenProcess(0x100000, False, record["pid"])  # SYNCHRONIZE
                    if abrupt:
                        parent.kill()
                    parent.communicate(timeout=8)
                    if handle:
                        self.assertEqual(0, api.WaitForSingleObject(handle, 3000), "owned child survived supervisor")
                    else:
                        self.assertEqual(87, ctypes.get_last_error(), "unexpected process query failure")
                    if not abrupt:
                        self.assertEqual(0, parent.returncode)
                finally:
                    if parent.poll() is None:
                        parent.kill()
                        parent.communicate(timeout=5)
                    if handle:
                        api.CloseHandle(handle)


if __name__ == "__main__":
    unittest.main()
