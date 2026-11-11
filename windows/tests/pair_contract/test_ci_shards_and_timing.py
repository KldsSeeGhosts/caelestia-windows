"""CI scheduling, complete shard inventories and path-free diagnostics."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
class CiShardsAndTiming(unittest.TestCase):
    def test_shell_inventory_includes_idle_regression(self):
        source = (ROOT / "windows/scripts/Test-Validation.ps1").read_text()
        shell = source.split("@('Test-AccessibilityLauncher'", 1)[1].split("\n        }", 1)[0]
        self.assertIn("'Test-IdleWork'", shell)
        self.assertEqual(26, 1 + len(re.findall(r"'Test-[A-Za-z0-9]+'", shell)))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ci-diagnostics-",
                                                 dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def ps(self, script, *args):
        return subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                               str(script), *map(str, args)], capture_output=True, text=True, timeout=30)

    def test_shards_partition_the_authoritative_inventory_and_fail_closed(self):
        script = ROOT / "windows/scripts/Test-Validation.ps1"
        def names(*args):
            result = self.ps(script, "-Suite", "Packaging", "-ListTests", *args)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            return json.loads(result.stdout)
        full, first, second = names(), names("-Shard", "1/2"), names("-Shard", "2/2")
        self.assertEqual(8, len(full))
        self.assertEqual(["Test-VersionedInstall"], first)
        self.assertCountEqual(full, first + second)
        self.assertEqual(len(full), len(set(first + second)))
        source = script.read_text()
        for row in ("@{ name = 'Test-NewPackagingTest' }",
                    "@{ name = 'Test-NewPackagingTest'; shard = 3 }",
                    "@{ name = 'Test-VersionedInstall'; shard = 2 }"):
            mutated = self.root / "mutated.ps1"
            mutated.write_text(source.replace("$packagingTests = @(", "$packagingTests = @(\n    " + row, 1))
            result = self.ps(mutated, "-Suite", "Packaging", "-ListTests")
            self.assertNotEqual(0, result.returncode)
            self.assertIn("exactly one valid shard assignment", result.stderr)
        for args in (("-Suite", "Unit", "-Shard", "1/2"),
                     ("-Suite", "Packaging", "-Shard", "3/2")):
            self.assertNotEqual(0, self.ps(script, *args).returncode)

    def test_unit_shards_partition_the_authoritative_inventory_and_fail_closed(self):
        script = ROOT / "windows/scripts/Test-Validation.ps1"
        def names(*args):
            result = self.ps(script, "-Suite", "Unit", "-ListTests", *args)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            return json.loads(result.stdout)
        full, first, second, third = (names(), names("-Shard", "1/3"),
                                      names("-Shard", "2/3"), names("-Shard", "3/3"))
        self.assertEqual(21, len(full))
        self.assertIn("public-release-metadata", third)
        self.assertEqual(["Test-CIAcceleration"], first)
        self.assertEqual(["Test-PairContract", "toolchain-modules"], second)
        self.assertCountEqual(full, first + second + third)
        self.assertEqual(len(full), len(set(first + second + third)))
        source = script.read_text()
        for row in ("@{ name = 'Test-NewUnitTest' }",
                    "@{ name = 'Test-NewUnitTest'; shard = 4 }",
                    "@{ name = 'Test-PublicDocs'; shard = 2 }"):
            mutated = self.root / "mutated-unit.ps1"
            mutated.write_text(source.replace("$unitTests = @(", "$unitTests = @(\n    " + row, 1))
            result = self.ps(mutated, "-Suite", "Unit", "-ListTests")
            self.assertNotEqual(0, result.returncode)
            self.assertIn("exactly one valid shard assignment", result.stderr)

    def test_jobs_start_independently_with_byte_exact_first_step_guard(self):
        text = (ROOT / ".github/workflows/windows-build.yml").read_text()
        def job(name):
            return re.split(r"(?m)^  \w+:\n", text.split(f"\n  {name}:\n")[1])[0]
        guard = job("scope").split("    steps:\n")[1].split("      - name: Checkout")[0]
        for name in ("checks", "packaging"):
            block = job(name)
            self.assertNotIn("needs:", block)
            self.assertTrue(block.split("    steps:\n")[1].startswith(guard))
        checks = job("checks")
        self.assertIn("fail-fast: false", checks)
        self.assertIn("shard: [1, 2, 3]", checks)
        self.assertIn("-Shard '${{ matrix.shard }}/3'", checks)
        self.assertIn("unit-summary-${{ matrix.shard }}-${{ github.run_id }}", checks)
        node = checks.split("      - name: Node 24\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: matrix.shard == 3", node)
        self.assertEqual(1, checks.count("if: matrix.shard == 3"))
        packaging = job("packaging")
        self.assertIn("fail-fast: false", packaging)
        self.assertIn("shard: [1, 2]", packaging)
        self.assertIn("-Shard '${{ matrix.shard }}/2'", packaging)
        self.assertIn("packaging-summary-${{ matrix.shard }}-${{ github.run_id }}", packaging)
        self.assertEqual(2, packaging.count("if: matrix.shard == 1"))
        self.assertNotIn("continue-on-error", packaging)
        validation = job("validation")
        self.assertIn("needs: [scope, checks, packaging, reuse, fixtures, build, pair]", validation)
        self.assertIn("PACKAGING: ${{ needs.packaging.result }}", validation)
        self.assertIn("$env:PACKAGING -ne 'success'", validation)
        self.assertIn("$env:SCOPE -ne 'success'", validation)

    def test_directory_measurement_counts_bytes_without_disclosing_names(self):
        tool = self.root / "private-user-tools"
        for name, body in (("Qt/private-name.txt", b"123"), ("Qt/nested/secret.bin", b"12345"),
                           ("downloads/private.zip", b"12"), ("pip/private.whl", b"1234")):
            path = tool / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
        output = self.root / "counts.json"
        result = self.ps(ROOT / "windows/ci/Measure-ToolRoot.ps1",
                         "-ToolRoot", tool, "-OutputPath", output)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        text = output.read_text(encoding="utf-8-sig")
        self.assertNotIn("private", text)
        self.assertNotIn(str(self.root), text)
        rows = {row["directory"]: row for row in json.loads(text)["directories"]}
        self.assertEqual({"Qt", "LLVM", "downloads", "pip", "deps", "tools"}, set(rows))
        self.assertEqual((8, 2, True), tuple(rows["Qt"][k] for k in ("bytes", "files", "exists")))
        self.assertEqual((0, 0, False), tuple(rows["tools"][k] for k in ("bytes", "files", "exists")))
        self.assertEqual(2, rows["downloads"]["bytes"])
        self.assertEqual(4, rows["pip"]["bytes"])

    def test_real_timing_functions_preserve_native_exit_codes_and_failure(self):
        def quote(value):
            return "'" + str(value).replace("'", "''") + "'"
        harness = self.root / "timing.ps1"
        child = self.root / "native.ps1"
        child.write_text("param([int]$Code)\n[Console]::Error.WriteLine('harmless native stderr')\nexit $Code\n")
        harness.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            f"$logRoot = {quote(self.root)}; $timingRoot = $logRoot\n"
            "$timings = New-Object 'System.Collections.Generic.List[object]'\n"
            "foreach ($entry in @(\n"
            f" @({quote(ROOT / 'windows/scripts/Build-Prototype.ps1')}, 'Invoke-BuildCommand'),\n"
            f" @({quote(ROOT / 'windows/scripts/Prepare-Toolchain.ps1')}, 'Save-ToolchainTiming'))) {{\n"
            " $tokens = $null; $errors = $null\n"
            " $ast = [Management.Automation.Language.Parser]::ParseFile($entry[0], [ref]$tokens, [ref]$errors)\n"
            " if ($errors.Count) { throw 'source does not parse' }\n"
            " $name = $entry[1]\n"
            " $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]"
            " -and $n.Name -eq $name }, $true)\n"
            " . ([scriptblock]::Create($node.Extent.Text))\n"
            "}\n"
            "$script:fixtureExit = 7\n"
            f"function cmake {{ & powershell.exe -NoProfile -NonInteractive -File {quote(child)} -Code $script:fixtureExit }}\n"
            "$refused = $false\n"
            "try { Invoke-BuildCommand 'build-fixture' @('--build', 'private-path') }\n"
            "catch { if ($_.Exception.Message -notlike 'build-fixture failed.*') { throw }; $refused = $true }\n"
            "if (-not $refused) { throw 'native failure was lost' }\n"
            "Save-ToolchainTiming 'fixture' ([Diagnostics.Stopwatch]::StartNew()) $LASTEXITCODE\n"
            "if ($LASTEXITCODE -ne 7) { throw 'timing changed native exit status' }\n"
            "Save-ToolchainTiming 'skipped' ([Diagnostics.Stopwatch]::new()) $null 'skipped'\n"
            "$script:fixtureExit = 0\n"
            "Invoke-BuildCommand 'configure-fixture' @('-S', 'private-path')\n"
            "Save-ToolchainTiming 'success' ([Diagnostics.Stopwatch]::StartNew()) $LASTEXITCODE\n"
            "if ($LASTEXITCODE -ne 0) { throw 'timing changed successful native exit status' }\n"
        )
        result = self.ps(harness)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        native = json.loads((self.root / "build-fixture-timing.json").read_text(encoding="utf-8-sig"))
        self.assertEqual({"durationSeconds", "exitCode"}, set(native))
        self.assertEqual(7, native["exitCode"])
        phases = json.loads((self.root / "prepare-timing.json").read_text(encoding="utf-8-sig"))["phases"]
        self.assertEqual((7, "failure"), (phases[0]["exitCode"], phases[0]["outcome"]))
        self.assertEqual((None, "skipped"), (phases[1]["exitCode"], phases[1]["outcome"]))
        self.assertEqual((0, "success"), (phases[2]["exitCode"], phases[2]["outcome"]))
        configured = json.loads((self.root / "configure-fixture-timing.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(0, configured["exitCode"])
        self.assertGreaterEqual(native["durationSeconds"], 0)

    def test_timing_uploads_are_separate_bounded_and_complete(self):
        text = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual(4, text.count("- name: Measure restored tooling directories"))
        for label in ("tooling-fixtures", "tooling-production", "tooling-reuse", "tooling-candidate",
                      "production-timings"):
            block = text.split("          name: " + label + "-")[1].split("      - name:")[0]
            self.assertIn("retention-days: 7", block)
            self.assertNotIn(".log\n", block)
            self.assertNotIn("build.json", block)
        prepare = (ROOT / "windows/scripts/Prepare-Toolchain.ps1").read_text()
        for phase in ("venv", "pip-$lock", "pip-aqt", "aqt-install-qt", "rust-install", "final-assertions"):
            self.assertIn(f"Save-ToolchainTiming '{phase}'" if "$" not in phase
                          else f'Save-ToolchainTiming "{phase}"', prepare)
        exporter = (ROOT / "windows/ci/Export-NexusCandidateInputs.ps1").read_text()
        for private in ("prepare-timing", "restored-directories", "prepared-directories", "-timing.json"):
            self.assertNotIn(private, exporter)
