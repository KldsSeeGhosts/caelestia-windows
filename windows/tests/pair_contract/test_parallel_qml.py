"""Exercise the real validation scheduler with isolated PowerShell fixtures."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
VALIDATION = ROOT / "windows/scripts/Test-Validation.ps1"
HINTS = VALIDATION.with_name("Qml-DurationHints.json")
SOURCE = VALIDATION.read_text()
INVENTORY = re.findall(r"'(Test-[A-Za-z0-9]+)'", SOURCE.split(
    "@('Test-AccessibilityLauncher'", 1)[1].split("\n        }", 1)[0])
INVENTORY.insert(0, "Test-AccessibilityLauncher")


@unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
class ParallelQmlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="parallel qml ", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shell = self.root / "source with spaces"
        self.scripts = self.shell / "windows/scripts"
        self.scripts.mkdir(parents=True)
        shutil.copyfile(VALIDATION, self.scripts / VALIDATION.name)
        shutil.copyfile(HINTS, self.scripts / HINTS.name)
        subprocess.run(["git", "init", "--quiet", str(self.shell)], check=True)
        (self.shell / "tracked").write_text("synthetic repository")
        subprocess.run(["git", "-C", str(self.shell), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.shell), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
                       check=True, capture_output=True)
        self.output = self.root / "output"

    def populate(self, failure=False, jobs=2):
        self.assertEqual(28, len(INVENTORY))
        first = ["Test-CaptureThumbnail", "Test-CapturePicker",
                 "Test-WallpaperDefaults"][:jobs]
        for index, name in enumerate(INVENTORY):
            # First workers rendezvous proves actual overlap without a speed
            # threshold. All other fixtures finish after a short bounded wait.
            barrier = ""
            if name in first:
                for other in first:
                    barrier += (
                        "$deadline = [DateTime]::UtcNow.AddSeconds(15)\n"
                        f"while (-not (Test-Path (Join-Path $PSScriptRoot '{other}.started'))) {{\n"
                        " if ([DateTime]::UtcNow -gt $deadline) { exit 9 }\n"
                        " Start-Sleep -Milliseconds 20\n}\n")
            (self.scripts / (name + ".ps1")).write_text(
                "param($QtPrefix, $BuildRoot)\n"
                "$start = [DateTime]::UtcNow.Ticks\n"
                f"Set-Content (Join-Path $PSScriptRoot '{name}.started') 'started'\n"
                + barrier +
                "Start-Sleep -Milliseconds 100\n"
                # Enough output to fill a redirected pipe. Both streams must
                # drain while multiple children are alive.
                "if ($env:PARALLEL_LARGE_OUTPUT -eq '1') {\n"
                " [Console]::Out.WriteLine('x' * 100000)\n"
                " [Console]::Error.WriteLine('y' * 100000)\n}\n"
                f"[ordered]@{{name='{name}'; start=$start; end=[DateTime]::UtcNow.Ticks;\n"
                " outputRoot=$env:CAELESTIA_TEST_OUTPUT_ROOT; platform=$env:QT_QPA_PLATFORM;\n"
                " qt=$QtPrefix; build=$BuildRoot} | ConvertTo-Json |\n"
                f" Set-Content (Join-Path $PSScriptRoot '{name}.result.json')\n"
                "Write-Output '{\"assertions\": 300}'\n"
                "[Console]::Error.WriteLine('synthetic harmless stderr')\n"
                f"exit {7 if failure and index == 3 else 0}\n")

    def run_suite(self, jobs=2, **env):
        return subprocess.run([
            "powershell.exe", "-NoProfile", "-NonInteractive", "-File",
            str(self.scripts / VALIDATION.name), "-Suite", "Shell",
            "-QtPrefix", "C:\\Qt path\\", "-BuildRoot", "C:\\Build path\\",
            "-OutputRoot", str(self.output), "-QmlJobs", str(jobs)],
            capture_output=True, text=True, timeout=90,
            env={**os.environ, **env})

    def check_complete(self, expected_failure, result, jobs=2):
        summary = json.loads((self.output / "summary.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(not expected_failure, summary["passed"])
        self.assertEqual(INVENTORY, [row["name"] for row in summary["results"]])
        self.assertEqual(INVENTORY, re.findall(
            r"^(?:PASS|FAIL) (Test-\w+) \(", result.stdout, re.MULTILINE))
        failures = [row for row in summary["results"] if row["exitCode"]]
        self.assertEqual([7] if expected_failure else [], [row["exitCode"] for row in failures])
        intervals, roots = [], []
        for name in INVENTORY:
            row = json.loads((self.scripts / (name + ".result.json")).read_text(encoding="utf-8-sig"))
            roots.append(row["outputRoot"])
            self.assertEqual(str(self.output / "fixtures" / name), row["outputRoot"])
            self.assertEqual("offscreen", row["platform"])
            self.assertEqual("C:\\Qt path\\", row["qt"])
            self.assertEqual("C:\\Build path\\", row["build"])
            intervals.extend([(row["start"], 1), (row["end"], -1)])
            log = (self.output / (name + ".log")).read_text(encoding="utf-8-sig")
            self.assertIn('"assertions": 300', log)
            self.assertIn("synthetic harmless stderr", log)
        self.assertEqual(len(INVENTORY), len(set(roots)))
        concurrent, maximum = 0, 0
        for _, change in sorted(intervals):
            concurrent += change
            maximum = max(maximum, concurrent)
        self.assertEqual(jobs, maximum)
        self.assertEqual(0, concurrent)

    def test_parallel_success_is_bounded_complete_isolated_and_drains_both_pipes(self):
        for jobs in (2, 3):
            with self.subTest(jobs=jobs):
                for marker in self.scripts.glob("*.started"):
                    marker.unlink()
                self.populate(jobs=jobs)
                result = self.run_suite(jobs=jobs, PARALLEL_LARGE_OUTPUT="1")
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.check_complete(False, result, jobs=jobs)

    def test_failure_runs_every_fixture_and_keeps_its_nonzero_exit(self):
        self.populate(failure=True)
        result = self.run_suite()
        self.assertNotEqual(0, result.returncode)
        self.check_complete(True, result)

    def test_schedule_is_longest_first_with_stable_ties_and_unknowns_last(self):
        # Extract the real function without running the suite. Deliberately
        # scramble names, tie durations and leave two tests without hints.
        (self.scripts / HINTS.name).write_text(
            '{"seconds": {"short": 1, "tie-z": 5, "long": 20, "tie-a": 5}}\n')
        probe = self.scripts / "schedule.ps1"
        function = "function Get-QmlSchedule" + SOURCE.split(
            "function Get-QmlSchedule", 1)[1].split(
                "function Invoke-ParallelScriptChecks", 1)[0]
        probe.write_text(
            "$ErrorActionPreference = 'Stop'\n" + function +
            "ConvertTo-Json -InputObject @(Get-QmlSchedule "
            "@('unknown-z', 'short', 'tie-z', 'long', 'unknown-a', 'tie-a'))\n")
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(probe)],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(["long", "tie-z", "tie-a", "short", "unknown-z", "unknown-a"],
                         json.loads(result.stdout))

    def test_log_write_failure_never_reports_success(self):
        self.populate()
        (self.output / (INVENTORY[0] + ".log")).mkdir(parents=True)
        result = self.run_suite()
        self.assertNotEqual(0, result.returncode)
        summary = json.loads((self.output / "summary.json").read_text(encoding="utf-8-sig"))
        self.assertFalse(summary["passed"])

    def test_invalid_parallelism_refuses_before_any_fixture(self):
        self.populate()
        for count in (0, 5):
            result = self.run_suite(jobs=count)
            self.assertNotEqual(0, result.returncode)
        self.assertFalse(list(self.scripts.glob("*.started")))
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual(2, workflow.count("-QmlJobs 3"))
        self.assertEqual(
            (ROOT / ".github/workflows/windows-build.yml").read_bytes(),
            (ROOT / "windows/ci/windows-build.yml.template").read_bytes())
        integration = (ROOT / "windows/ci/Invoke-PairIntegration.ps1").read_text()
        shell = integration.split("function Get-ShellArguments", 1)[1].split(
            "function Get-PluginArguments", 1)[0]
        self.assertIn("@('-QmlJobs', \"$QmlJobs\")", shell)
        self.assertNotIn("QmlJobs", integration.split("function Get-ServicesArguments", 1)[1].split(
            "function Get-ShellArguments", 1)[0])


if __name__ == "__main__":
    unittest.main()
