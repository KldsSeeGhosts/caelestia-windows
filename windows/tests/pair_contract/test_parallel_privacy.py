"""Exercise the real bounded scanner scheduler under Windows PowerShell 5.1."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
class ParallelPrivacyTests(unittest.TestCase):
    def run_ps(self, script, *args):
        with tempfile.TemporaryDirectory(
                prefix="parallel-privacy-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT")) as temp:
            harness = Path(temp) / "check.ps1"
            harness.write_text(
                "param($Repository, $Work)\n$ErrorActionPreference = 'Stop'\n"
                ". \"$Repository/windows/scripts/Caelestia-ReleasePrivacy.ps1\"\n" + script,
                encoding="utf-8-sig")
            return subprocess.run(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(harness),
                 str(ROOT), temp, *args], capture_output=True, text=True, timeout=45)

    def test_parallel_overlap_is_bounded_complete_and_preserves_input_order(self):
        result = self.run_ps(r'''
foreach ($name in @('first', 'second', 'third')) {
    [IO.File]::WriteAllText("$Work/$name.txt", $name)
}
$files = @('first', 'second', 'third') | ForEach-Object { Get-Item "$Work/$_.txt" }
$scanner = {
    param($Bytes, $Extension, $Roots)
    $name = [Text.Encoding]::UTF8.GetString($Bytes)
    [IO.File]::WriteAllText("$($Roots[0])/$name.started", [string][DateTime]::UtcNow.Ticks)
    if ($name -in @('first', 'second')) {
        $other = if ($name -eq 'first') { 'second' } else { 'first' }
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not [IO.File]::Exists("$($Roots[0])/$other.started")) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Workers did not overlap.' }
            Start-Sleep -Milliseconds 10
        }
    }
    [IO.File]::WriteAllText("$($Roots[0])/$name.finished", [string][DateTime]::UtcNow.Ticks)
    [pscustomobject]@{ Sensitive = ($name -eq 'second'); GenericPath = ($name -eq 'third') }
}
$rows = @(Invoke-CaelestiaReleasePrivacyScan -Files $files -PrivateRoots @($Work) -Jobs 2 `
    -ScannerDefinition $scanner.ToString())
if ($rows.Count -ne 3) { throw 'Incomplete output.' }
if ($rows[0].Sensitive -or -not $rows[1].Sensitive -or -not $rows[2].GenericPath) { throw 'Wrong verdicts.' }
$events = foreach ($name in @('first', 'second', 'third')) {
    [pscustomobject]@{ Ticks = [long][IO.File]::ReadAllText("$Work/$name.started"); Change = 1 }
    [pscustomobject]@{ Ticks = [long][IO.File]::ReadAllText("$Work/$name.finished"); Change = -1 }
}
$active = 0; $maximum = 0
foreach ($event in $events | Sort-Object Ticks, Change) {
    $active += $event.Change
    $maximum = [Math]::Max($maximum, $active)
}
if ($active -ne 0 -or $maximum -ne 2) { throw 'Worker bound or overlap was not preserved.' }
@($rows | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.FullName) }) | ConvertTo-Json -Compress
''')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(["first", "second", "third"], json.loads(result.stdout))

    def test_empty_single_and_invalid_worker_counts(self):
        result = self.run_ps(r'''
$scanner = { [pscustomobject]@{Sensitive=$false; GenericPath=$false} }
if (@(Invoke-CaelestiaReleasePrivacyScan -Files @() -PrivateRoots @() `
    -ScannerDefinition $scanner.ToString()).Count) { throw 'Unexpected empty-input output.' }
[IO.File]::WriteAllText("$Work/one.txt", 'ordinary')
foreach ($jobs in @(1, 4)) {
    $rows = @(Invoke-CaelestiaReleasePrivacyScan -Files @(Get-Item "$Work/one.txt") -PrivateRoots @() `
        -Jobs $jobs -ScannerDefinition $scanner.ToString())
    if ($rows.Count -ne 1 -or $rows[0].Sensitive -or $rows[0].GenericPath) { throw 'Wrong single-file result.' }
}
foreach ($jobs in @(0, 5)) {
    try {
        Invoke-CaelestiaReleasePrivacyScan -Files @() -PrivateRoots @() -Jobs $jobs `
            -ScannerDefinition $scanner.ToString()
        throw 'Unexpected worker-count success.'
    } catch { if ($_.Exception.Message -eq 'Unexpected worker-count success.') { throw } }
}
''')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_real_scanner_matches_serial_results_under_each_culture(self):
        script = r'''
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    "$Repository/windows/scripts/New-CaelestiaRelease.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Scanner does not parse.' }
$definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-ReleaseFilePrivacy'}, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$bodies = @('ordinary', 'ghp_abcdefghijklmnopqrstuvwx', 'C:\Users\fixture\source',
    'GITHUB_PAT_abcdefghijklmnopqrstuvwx', 'GİTHUB_PAT_abcdefghijklmnopqrstuvwx', 'i:\public\file',
    'C:\PRIV\x', '-----BEGIN PRIVATE KEY-----' + "`n" + ('A' * 32))
for ($index = 0; $index -lt $bodies.Count; $index++) {
    [IO.File]::WriteAllText("$Work/$index.dll", $bodies[$index], [Text.Encoding]::UTF8)
}
$files = @(Get-ChildItem $Work -Filter '*.dll')
foreach ($culture in @('SELECTED_CULTURE')) {
    if ($culture -eq 'Invariant') { $culture = '' }
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
    $rows = @(Invoke-CaelestiaReleasePrivacyScan -Files $files -PrivateRoots @('C:\Priv', 'c:\priv\x') `
        -ScannerDefinition ${function:Get-ReleaseFilePrivacy}.ToString())
    for ($index = 0; $index -lt $files.Count; $index++) {
        $expected = Get-ReleaseFilePrivacy ([IO.File]::ReadAllBytes($files[$index].FullName)) `
            $files[$index].Extension @('C:\Priv', 'c:\priv\x')
        if ($rows[$index].Sensitive -ne $expected.Sensitive -or $rows[$index].GenericPath -ne $expected.GenericPath) {
            throw "Parallel scanner differs from serial policy under $culture"
        }
    }
}
Write-Output 'pass'
'''
        # WinPS caches -match regexes process-wide. Use a fresh process for each
        # culture so en-US cannot populate the cache for the other comparisons.
        for culture in ("en-US", "tr-TR", "Invariant"):
            result = self.run_ps(script.replace("SELECTED_CULTURE", culture))
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_worker_errors_bad_output_and_missing_inputs_never_return_partial_success(self):
        for body in ("throw 'Synthetic failure.'",
                     "Write-Error 'Synthetic nonterminating error.'; [pscustomobject]@{Sensitive=$false; GenericPath=$false}",
                     "[pscustomobject]@{Sensitive=$false}",
                     "[pscustomobject]@{Sensitive=$false; GenericPath=$false}; Write-Output 'extra'"):
            result = self.run_ps(r'''
[IO.File]::WriteAllText("$Work/a.dll", 'ordinary')
[IO.File]::WriteAllText("$Work/b.dll", 'ordinary')
$files = @(Get-ChildItem $Work -Filter '*.dll')
$emitted = [Collections.Generic.List[object]]::new()
try {
    Invoke-CaelestiaReleasePrivacyScan -Files $files -PrivateRoots @() -ScannerDefinition {
        param($Bytes, $Extension, $Roots)
        BODY
    }.ToString() | ForEach-Object { $emitted.Add($_) }
    throw 'Unexpected scanner success.'
} catch {
    if ($_.Exception.Message -eq 'Unexpected scanner success.' -or $emitted.Count) { throw }
}
$missing = [IO.FileInfo]::new("$Work/missing.dll")
try {
    Invoke-CaelestiaReleasePrivacyScan -Files @($missing) -PrivateRoots @() -ScannerDefinition {
        [pscustomobject]@{Sensitive=$false; GenericPath=$false}
    }.ToString()
    throw 'Unexpected missing-file success.'
} catch { if ($_.Exception.Message -eq 'Unexpected missing-file success.') { throw } }
'''.replace("BODY", body))
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_both_release_entrypoints_use_parallel_scan_and_keep_all_gates(self):
        for path in ("windows/scripts/New-CaelestiaRelease.ps1", "windows/ci/Test-NexusCandidatePayload.ps1"):
            source = (ROOT / path).read_text()
            self.assertIn("Invoke-CaelestiaReleasePrivacyScan -Files $privacyFiles", source)
            self.assertIn("-ScannerDefinition ${function:Get-ReleaseFilePrivacy}.ToString()", source)
            self.assertIn("$flags.Sensitive -or ($flags.GenericPath -and -not $reviewed", source)
        candidate = (ROOT / "windows/ci/New-NexusCandidate.ps1").read_text()
        self.assertIn("Invoke-CandidateGate 'independent-payload'", candidate)
        publisher = (ROOT / "windows/ci/nexus_publish.py").read_text()
        self.assertIn('"independent-payload"]', publisher)


if __name__ == "__main__":
    unittest.main()
