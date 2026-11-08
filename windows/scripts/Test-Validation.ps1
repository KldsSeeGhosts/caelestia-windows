#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Packaging', 'Services', 'Shell', 'Scheme')][string]$Suite = 'Unit',
    [string]$QtPrefix,
    [string]$BuildRoot,
    [string]$RuntimePrefix,
    [string]$Python = 'python',
    [string]$OutputRoot,
    [ValidateSet('1/2', '2/2')][string]$Shard,
    [switch]$ListTests
)

$ErrorActionPreference = 'Stop'
# One inventory for both the unsharded suite and hosted shards. Warm hosted
# 42421527915/2 measured VersionedInstall at 139.45s and the remainder at
# 145.90s. Colour regressions run only beside shard 1 in the workflow.
$packagingTests = @(
    @{ name = 'Test-UpdateTrust'; shard = 2 }
    @{ name = 'Test-NexusUpdate'; shard = 2 }
    @{ name = 'Test-NexusWorker'; shard = 2; outputParameter = '-OutputRoot'; directory = 'nexus-worker' }
    @{ name = 'Test-SourceAssets'; shard = 2; outputParameter = '-OutputDirectory'; directory = 'source-assets' }
    @{ name = 'Test-SupportBundle'; shard = 2; outputParameter = '-OutputDirectory'; directory = 'support-bundle' }
    @{ name = 'Test-VersionedInstall'; shard = 1 }
    @{ name = 'Test-UninstallTransaction'; shard = 2; outputParameter = '-OutputRoot'; directory = 'uninstall-transactions' }
    @{ name = 'Test-CaptureRelease'; shard = 2; outputParameter = '-OutputRoot'; directory = 'capture-release' }
)
if (($Shard -or $ListTests) -and $Suite -ne 'Packaging') { throw 'Shard and ListTests apply only to Packaging.' }
if (@($packagingTests | Where-Object { $_.shard -notin @(1, 2) }).Count -or
    @($packagingTests.name | Select-Object -Unique).Count -ne $packagingTests.Count) {
    throw 'Every packaging test requires exactly one valid shard assignment and a unique name.'
}
$selectedPackagingTests = @($packagingTests | Where-Object { -not $Shard -or $_.shard -eq [int]$Shard.Split('/')[0] })
if ($ListTests) {
    ConvertTo-Json -InputObject @($selectedPackagingTests.name)
    return
}
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
if (-not $OutputRoot) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-validation-' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($OutputRoot -eq $repoRoot -or $OutputRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Validation output must stay outside the source checkout.'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$env:CAELESTIA_TEST_OUTPUT_ROOT = $OutputRoot
$env:PYTHONDONTWRITEBYTECODE = '1'
if ($RuntimePrefix) { $env:CAELESTIA_TEST_RUNTIME_PREFIX = [IO.Path]::GetFullPath($RuntimePrefix) }
if ($RuntimePrefix -and -not $BuildRoot) { $BuildRoot = $RuntimePrefix }
if ($Suite -in @('Services', 'Shell') -and -not $QtPrefix) { throw 'QtPrefix is required for QML fixtures.' }
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results = New-Object 'System.Collections.Generic.List[object]'
$completed = $false

function Invoke-ValidationStep([string]$Name, [string]$Executable, [string[]]$CommandArguments, [string]$TestCountPattern = '') {
    $Executable = (Get-Command $Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $logPath = Join-Path $OutputRoot ($Name + '.log')
    # Tests can emit harmless diagnostics on stderr. Only their native exit
    # code decides success; every fixture also checks its assertion floor.
    $ErrorActionPreference = 'Continue'
    & $Executable @CommandArguments 2>&1 | ForEach-Object { "$_" } |
        Set-Content -LiteralPath $logPath -Encoding UTF8
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $testCount = $null
    if ($TestCountPattern) {
        $counts = [regex]::Matches([string](Get-Content -LiteralPath $logPath -Raw -Encoding UTF8), $TestCountPattern)
        if ($counts.Count) { $testCount = [int]$counts[$counts.Count - 1].Groups[1].Value }
        if ($null -eq $testCount -or $testCount -lt 1) {
            Add-Content -LiteralPath $logPath -Value 'Validation requires a nonzero reported test count.' -Encoding UTF8
            if ($code -eq 0) { $code = 1 }
        }
    }
    $results.Add([ordered]@{ name = $Name; exitCode = $code; testCount = $testCount; seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2) })
    Write-Output ("{0} {1} ({2:N2}s)" -f $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }), $Name, $clock.Elapsed.TotalSeconds)
    # The log is not uploaded, so show the end of a failure where it ran.
    if ($code -ne 0) {
        Write-Output "--- last 80 lines of $Name ---"
        Get-Content -LiteralPath $logPath -Tail 80 -Encoding UTF8
        Write-Output "--- end of $Name ---"
    }
}

function Invoke-ScriptCheck([string]$Name, [string[]]$Extra = @()) {
    Invoke-ValidationStep $Name $powershell (@('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot "$Name.ps1")) + $Extra)
}

Push-Location -LiteralPath $repoRoot
try {
    if ($Suite -eq 'Unit') {
        # Fail before running any test when a script cannot even parse.
        foreach ($file in @((Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) +
            (Get-ChildItem -LiteralPath "$repoRoot\windows\ci" -Filter '*.ps1' -File))) {
            $tokens = $null
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "PowerShell syntax check failed: $($file.Name)" }
        }
        $map = Get-Content -LiteralPath "$repoRoot\windows\shell\sources.json" -Raw | ConvertFrom-Json
        if (@($map.PSObject.Properties.Name | Where-Object { $_ -match '(^|/)(tests?|fixtures|validation)/|Test\.qml$' }).Count) {
            throw 'Production staging must not include test fixtures.'
        }
        Invoke-ScriptCheck 'Test-PublicDocs'
        Invoke-ScriptCheck 'Test-Toolchain'
        Invoke-ScriptCheck 'Test-Versioning'
        Invoke-ScriptCheck 'Test-PairContract'
        Invoke-ScriptCheck 'Test-NexusPipeline' @('-Python', $Python)
        Invoke-ScriptCheck 'Test-CaptureIntegration'
        Invoke-ValidationStep 'llvm-extraction' $Python @('-I', '-B', 'windows/tests/LlvmExtract.test.py',
            '--output-root', (Join-Path $OutputRoot 'llvm-extraction'))
        Invoke-ValidationStep 'toolchain-modules' $Python @('-B', 'windows/tests/ToolchainModules.test.py',
            '--output-root', (Join-Path $OutputRoot 'toolchain-modules'))
        foreach ($name in @('Test-CIChanges', 'Test-CIAcceleration', 'Test-SchemeProbeGuard', 'Test-KsgSettingsImport', 'Test-ShellLifecycle', 'Test-ValidationCounts', 'Test-RepositoryPolicy')) {
            Invoke-ScriptCheck $name
        }
        $node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $javascript = @(Get-ChildItem -LiteralPath "$repoRoot\windows\tests" -Filter '*.test.js' -File | Sort-Object Name | ForEach-Object FullName)
        if (-not $javascript.Count) { throw 'No JavaScript regressions were discovered.' }
        Invoke-ValidationStep 'javascript' $node (@('--test', '--test-reporter=tap') + $javascript) '(?m)^# tests ([0-9]+)\s*$'
        Invoke-ValidationStep 'quota-providers' $Python @('-B', '-m', 'unittest', 'discover', '-s', 'windows/tests/quota_providers', '-v') '(?m)^Ran ([0-9]+) tests?\b'
    } elseif ($Suite -eq 'Packaging') {
        foreach ($test in $selectedPackagingTests) {
            $extra = @()
            if ($test.outputParameter) { $extra = @($test.outputParameter, (Join-Path $OutputRoot $test.directory)) }
            Invoke-ScriptCheck $test.name $extra
        }
    } elseif ($Suite -eq 'Scheme') {
        Invoke-ValidationStep 'scheme-worker' $Python @('-B', 'windows/scripts/scheme/test_win_scheme.py', '-v') '(?m)^Ran ([0-9]+) tests?\b'
    } else {
        $scripts = if ($Suite -eq 'Services') {
            @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*Service.ps1' -File | Sort-Object Name | ForEach-Object BaseName)
        } else {
            @('Test-AccessibilityLauncher', 'Test-AccessibilityNotifications', 'Test-DragPreview',
              'Test-HotplugTeardown', 'Test-IdleInhibitStatus', 'Test-LauncherHoverClose',
              'Test-PerMonitorFullscreen', 'Test-PinnedPopoutFocus', 'Test-QuotaPopovers',
              'Test-QuotaProviderKeyboard', 'Test-SessionSwitchBack', 'Test-WallpaperColours',
              'Test-WallpaperHandback', 'Test-WallpaperPreview', 'Test-WindowsBackground',
              'Test-UpdateManager', 'Test-UpdatesPage', 'Test-FileUrls')
        }
        if (-not $scripts.Count) { throw 'No QML regressions were discovered.' }
        $fixtureArguments = @('-QtPrefix', $QtPrefix)
        if ($BuildRoot) { $fixtureArguments += @('-BuildRoot', $BuildRoot) }
        foreach ($name in $scripts) { Invoke-ScriptCheck $name $fixtureArguments }
        if ($Suite -eq 'Services') {
            # This check resolves pinned backend/capture source files. The
            # Services job checks out recursive sources; the fast Unit job does not.
            Invoke-ValidationStep 'provider-support' $powershell @('-NoProfile', '-NonInteractive',
                '-File', (Join-Path $repoRoot 'windows/tests/Test-ProviderSupport.ps1'))
            Invoke-ScriptCheck 'Test-StagedServiceModels' @('-QtPrefix', $QtPrefix,
                '-OutputRoot', (Join-Path $OutputRoot 'staged-models'), '-MutationControls')
        }
    }
    $completed = $true
} finally {
    Pop-Location
    # This compact summary contains no commands, machine paths, profile data
    # or raw fixture output, so it is the only automatic CI test artifact.
    [ordered]@{
        schemaVersion = 1
        suite = $Suite
        shard = $Shard
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        sourceDirty = [bool](& git -C $repoRoot status --porcelain)
        passed = $completed -and $results.Count -gt 0 -and @($results | Where-Object { $_.exitCode -ne 0 }).Count -eq 0
        results = @($results.ToArray())
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
}
if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) { throw "Validation suite failed. See $OutputRoot." }
