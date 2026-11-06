#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolRoot,
    # New directory outside the checkout. Contains owned Cargo target and logs.
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateRange(1, 64)][int]$Jobs = 2,
    # Diagnostic subset only; an empty execution is always a failure.
    [string]$Filter
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
. "$PSScriptRoot\Caelestia-Toolchain.ps1"
. "$repoRoot\windows\capture\Source.ps1"
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$ToolRoot = (Resolve-Path -LiteralPath $ToolRoot).Path.TrimEnd('\')
foreach ($sourceRoot in @($repoRoot, $ToolRoot)) {
    if ($OutputRoot -eq $sourceRoot -or
        $OutputRoot.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $sourceRoot.StartsWith($OutputRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Capture test output must be separate from the checkout and read-only tools.'
    }
}
if (Test-Path -LiteralPath $OutputRoot) { throw 'Capture test output already exists; preserve it and choose a new directory.' }
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$receipt = [ordered]@{
    schemaVersion = 1; suite = 'caelestia-capture-rust'; result = 'failure'
    evidenceClass = 'unattended-component'; sourceRevision = $null; sourceDirty = $null
    captureOriginRevision = $null; captureCargoLockSha256 = $null; testBinarySha256 = $null
    toolchain = $null; filter = $(if ($Filter) { 'diagnostic-subset' } else { 'all-unattended' })
    counts = [ordered]@{ passed = 0; failed = 0; ignored = 0; filtered = 0 }
    tests = @(); nativeAcceptance = @()
    failure = 'gate-not-completed'
}
function Save-CaptureReceipt {
    $receipt | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath "$OutputRoot\capture-rust.json" -Encoding UTF8
}
function Invoke-CaptureNative([string]$Exe, [string[]]$Arguments, [string]$LogName) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $lines | Set-Content -LiteralPath "$OutputRoot\$LogName.private.log" -Encoding UTF8
    return [pscustomobject]@{ lines = $lines; exitCode = $code }
}
Save-CaptureReceipt
try {
    $source = Get-CaelestiaCaptureSource $repoRoot
    $receipt.sourceRevision = $source.sourceRevision
    $receipt.sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    $receipt.captureOriginRevision = $source.originRevision
    $receipt.captureCargoLockSha256 = $source.cargoLockSha256
    $spec = Get-CaelestiaToolchain
    $qt = Join-Path $ToolRoot $spec.qtDirectory
    $llvm = Join-Path $ToolRoot "$($spec.llvmDirectory)\bin"
    $tools = Join-Path $ToolRoot 'tools\Scripts'
    $null = Enter-CaelestiaToolchain -QtPrefix $qt -LlvmBin $llvm -ToolsBin $tools
    Select-CaelestiaRust
    $receipt.toolchain = Get-CaelestiaActualToolchain -QtPrefix $qt -Cli11Include (Join-Path $ToolRoot $spec.cli11Directory)
    Save-CaptureReceipt
    $arguments = @('test', '--locked', '--no-run', '--message-format=json',
        '--jobs', "$Jobs", '--target', $spec.rustTarget,
        '--manifest-path', "$($source.path)\Cargo.toml", '--target-dir', "$OutputRoot\target")
    $build = Invoke-CaptureNative 'cargo' $arguments 'compile'
    if ($build.exitCode -ne 0) { $receipt.failure = 'compile-failed'; throw 'Capture test compilation failed.' }
    $artifacts = @($build.lines | ForEach-Object {
        if ($_.StartsWith('{')) {
            $item = $_ | ConvertFrom-Json
            if ($item.reason -eq 'compiler-artifact' -and $item.profile.test -eq $true -and $item.executable) {
                $item.executable
            }
        }
    } | Select-Object -Unique)
    if ($artifacts.Count -ne 1) { $receipt.failure = 'ambiguous-test-binary'; throw 'Expected exactly one Cargo-reported capture test binary.' }
    $binary = [IO.Path]::GetFullPath($artifacts[0])
    if (-not $binary.StartsWith("$OutputRoot\target\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cargo reported a test binary outside the owned target directory.'
    }
    $receipt.testBinarySha256 = (Get-FileHash -LiteralPath $binary).Hash.ToLowerInvariant()

    # The test executable, not the production entry point, is run. A fresh
    # owned TEMP cwd and synthetic profile isolate every filesystem test.
    $runRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-capture-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $runRoot | Set-Content -LiteralPath "$OutputRoot\working-directory.private.log" -Encoding UTF8
    $previousEnvironment = @{}
    foreach ($name in @('TEMP', 'TMP', 'APPDATA', 'LOCALAPPDATA', 'USERPROFILE')) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        $directory = Join-Path $runRoot $name
        New-Item -ItemType Directory -Path $directory | Out-Null
        [Environment]::SetEnvironmentVariable($name, $directory, 'Process')
    }
    Push-Location -LiteralPath $runRoot
    try {
        $listed = Invoke-CaptureNative $binary @('--list', '--format', 'terse') 'inventory'
        $ignored = Invoke-CaptureNative $binary @('--list', '--ignored', '--format', 'terse') 'ignored-inventory'
        if ($listed.exitCode -ne 0 -or $ignored.exitCode -ne 0) { throw 'Capture test inventory failed.' }
        $allNames = @($listed.lines | Where-Object { $_ -match '^([A-Za-z0-9_:]+): test$' } |
            ForEach-Object { $_.Substring(0, $_.Length - 6) })
        $ignoredNames = @($ignored.lines | Where-Object { $_ -match '^([A-Za-z0-9_:]+): test$' } |
            ForEach-Object { $_.Substring(0, $_.Length - 6) })
        $safeNames = @($allNames | Where-Object { $_ -notin $ignoredNames } | Sort-Object)
        $allowlist = Get-Content -LiteralPath "$($source.path)\tests\unattended.json" -Raw | ConvertFrom-Json
        if ($allowlist.schemaVersion -ne 1 -or -not $safeNames.Count -or
            @(Compare-Object @($allowlist.tests | Sort-Object) $safeNames).Count -or
            @($allNames | Select-Object -Unique).Count -ne $allNames.Count) {
            $receipt.failure = 'unreviewed-or-empty-test-inventory'
            throw 'Capture unattended inventory changed; review side effects before updating the allowlist.'
        }
        # Read the ignored reasons, then cross-check them against compiled
        # inventory. Attribute counts are never used as execution counts.
        $reasons = @{}
        Get-ChildItem -LiteralPath "$($source.path)\src" -Filter '*.rs' -File | ForEach-Object {
            $module = $_.BaseName
            $text = Get-Content -LiteralPath $_.FullName -Raw
            foreach ($match in [regex]::Matches($text, '#\[ignore = "([^"]+)"\]\s*fn (\w+)')) {
                $prefix = if ($module -eq 'desktop_tests') { 'desktop_tests::' } else { $module + '::tests::' }
                $reasons[$prefix + $match.Groups[2].Value] = $match.Groups[1].Value
            }
        }
        foreach ($name in $ignoredNames) {
            if (-not $reasons.ContainsKey($name)) { throw 'Ignored capture test is missing an explicit acceptance reason.' }
            $receipt.nativeAcceptance += [ordered]@{ test = $name; state = 'not-run'; reason = $reasons[$name] }
        }
        Save-CaptureReceipt
        $testArguments = @('--test-threads=1', '--color', 'never')
        if ($Filter) { $testArguments += $Filter }
        $run = Invoke-CaptureNative $binary $testArguments 'run'
        foreach ($line in $run.lines) {
            if ($line -match '^test ([A-Za-z0-9_:]+) \.\.\. (ok|FAILED|ignored)(?:, (.*))?$') {
                $receipt.tests += [ordered]@{
                    test = $Matches[1]; outcome = $Matches[2]
                    reason = $(if ($Matches[2] -eq 'ignored') { $reasons[$Matches[1]] } else { $null })
                }
            }
        }
        $summaries = @($run.lines | Where-Object {
            $_ -match '^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; (\d+) filtered out;'
        })
        if ($summaries.Count -ne 1) { $receipt.failure = 'missing-test-summary'; throw 'Capture test summary missing or ambiguous.' }
        $null = $summaries[0] -match '^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; (\d+) filtered out;'
        $receipt.counts = [ordered]@{
            passed = [int]$Matches[2]; failed = [int]$Matches[3]
            ignored = [int]$Matches[4]; filtered = [int]$Matches[6]
        }
        $expectedRows = $receipt.counts.passed + $receipt.counts.failed + $receipt.counts.ignored
        if ($receipt.tests.Count -ne $expectedRows -or
            @($receipt.tests | Where-Object outcome -eq 'ok').Count -ne $receipt.counts.passed -or
            @($receipt.tests | Where-Object outcome -eq 'FAILED').Count -ne $receipt.counts.failed -or
            @($receipt.tests | Where-Object outcome -eq 'ignored').Count -ne $receipt.counts.ignored) {
            $receipt.failure = 'test-count-mismatch'; throw 'Capture test rows and summary disagree.'
        }
        if ($run.exitCode -ne 0 -or $receipt.counts.failed -gt 0) {
            $receipt.failure = 'test-failed'; throw 'Capture Rust regression failed.'
        }
        if ($receipt.counts.passed -eq 0) { $receipt.failure = 'empty-execution'; throw 'Capture Rust gate refuses an empty execution.' }
        if (-not $Filter -and ($receipt.counts.passed -ne $safeNames.Count -or
            $receipt.counts.ignored -ne $ignoredNames.Count -or $receipt.counts.filtered -ne 0)) {
            throw 'Full capture Rust gate did not execute every reviewed unattended test.'
        }
        $receipt.result = 'pass'
        $receipt.failure = $null
    } finally {
        Pop-Location
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
} catch {
    Save-CaptureReceipt
    throw
} finally { Save-CaptureReceipt }
Write-Output "PASS Caelestia capture Rust: $($receipt.counts.passed) passed, $($receipt.counts.failed) failed, $($receipt.counts.ignored) ignored, $($receipt.counts.filtered) filtered."
