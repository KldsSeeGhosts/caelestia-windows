<#
.SYNOPSIS
Runs the candidate validation gate and writes one machine-readable result manifest.

.DESCRIPTION
Orchestrates existing checks only:

    Test-Environment.ps1 -Json -Strict
    Build-Prototype.ps1 -Tests
    Test-BackendNative.ps1
    Test-Smoke.ps1
    every windows\scripts\Test-*Service.ps1 offscreen fixture
    Measure-ShellBenchmark.ps1 -CompareBaseline, only with -PerformanceBaseline

The build root is built once; -SkipBuild reuses it for a cached run. A failed
step makes the overall result fail and the exit code nonzero. A step that needs
a failed prerequisite is skipped, never counted as a pass. Live-desktop,
hardware, input and visible-window suites are listed under notRun and are not
executed.

Output: the manifest at -OutFile, with each step's command, exit code,
duration, pass/fail/skip counts where the step reports them, skip reasons and
log paths. Per-step logs are written beside the manifest under <BuildRoot>\logs.

Exit code: 0 when the overall result is pass, otherwise 1.

.PARAMETER QtPrefix
Qt 6 msvc2022_64 prefix, passed to the build, smoke and fixtures.

.PARAMETER LlvmBin
Directory containing clang-cl.exe, passed to the build.

.PARAMETER Cli11Include
CLI11 include directory, passed to the build.

.PARAMETER ToolsBin
Optional directory containing cmake/ninja, passed to the build.

.PARAMETER BuildRoot
Build output root. Required so a run never builds inside the repository.

.PARAMETER OutFile
Manifest path. Defaults to <BuildRoot>\candidate-validation\manifest.json.

.PARAMETER Jobs
Build parallelism, passed to Build-Prototype.ps1. Defaults to 4.

.PARAMETER SkipBuild
Reuse the existing build root instead of rebuilding.

.EXAMPLE
windows\scripts\Test-Candidate.ps1 -QtPrefix $qt -LlvmBin $llvm -Cli11Include $cli11 -ToolsBin $tools -BuildRoot C:\b-cand

.PARAMETER PerformanceBaseline
Also compare this build with a saved Measure-ShellBenchmark.ps1 baseline, using
the baseline's metrics, mode and workload. The step fails unless the verdict is
same or improved. It runs about an hour for Idle, Panel and Reload, so the
default run leaves it out.

.PARAMETER BaselineRoot
Baseline store for -PerformanceBaseline. Defaults to the benchmark default.

.EXAMPLE
windows\scripts\Test-Candidate.ps1 -QtPrefix $qt -LlvmBin $llvm -Cli11Include $cli11 -ToolsBin $tools -BuildRoot C:\b-cand -SkipBuild

.EXAMPLE
windows\scripts\Test-Candidate.ps1 -QtPrefix $qt -LlvmBin $llvm -Cli11Include $cli11 -ToolsBin $tools -BuildRoot C:\b-cand -SkipBuild -PerformanceBaseline main-44691989
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$LlvmBin,
    [Parameter(Mandatory)][string]$Cli11Include,
    [string]$ToolsBin,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$OutFile,
    [ValidateRange(1, 64)][int]$Jobs = 4,
    [switch]$SkipBuild,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$PerformanceBaseline,
    [string]$BaselineRoot = (Join-Path $env:LOCALAPPDATA 'caelestia-windows-bench\baselines'),
    # Check an existing manifest for private paths and user names, then exit.
    [string]$VerifyManifest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
. (Join-Path $PSScriptRoot 'Caelestia-Versions.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$QtPrefix = [IO.Path]::GetFullPath($QtPrefix).TrimEnd('\')
$LlvmBin = [IO.Path]::GetFullPath($LlvmBin).TrimEnd('\')
$Cli11Include = [IO.Path]::GetFullPath($Cli11Include).TrimEnd('\')
if ($ToolsBin) { $ToolsBin = [IO.Path]::GetFullPath($ToolsBin).TrimEnd('\') }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\')
if (-not $OutFile) { $OutFile = Join-Path $BuildRoot 'candidate-validation\manifest.json' }
$OutFile = [IO.Path]::GetFullPath($OutFile)
$logRoot = Join-Path $BuildRoot ('logs\candidate-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$powershell = Join-Path $PSHOME 'powershell.exe'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-candidate-' + [guid]::NewGuid().ToString('N'))

# The manifest is a candidate record, not a machine dump. Caelestia-Privacy.ps1
# redacts repository roots and personal paths and verifies the result.
. (Join-Path $PSScriptRoot 'Caelestia-Privacy.ps1')
Initialize-CaelestiaPrivacy @(
    @{ from = (Join-Path $env:LOCALAPPDATA 'caelestia-dev'); to = '<toolchain>' },
    @{ from = $repoRoot; to = '<repo>' },
    @{ from = $BuildRoot; to = '<buildRoot>' }
)

if ($VerifyManifest) {
    $verifyPath = [IO.Path]::GetFullPath($VerifyManifest)
    $privacy = Get-ManifestPrivacyReport $verifyPath
    $shownPath = Protect-ManifestString $verifyPath
    if (-not $privacy.exists) {
        Write-Output "PRIVACY FAIL: no manifest at $shownPath"
        exit 1
    }
    if ($privacy.total -gt 0) {
        Write-Output "PRIVACY FAIL: $($privacy.homeHits) home-path occurrences, $($privacy.userHits) user-name occurrences in $shownPath"
        exit 1
    }
    Write-Output "PRIVACY PASS: no home-path or user-name occurrences in $shownPath"
    exit 0
}

New-Item -ItemType Directory -Force -Path $scratch, $logRoot, (Split-Path -Parent $OutFile) | Out-Null

# Live-desktop, hardware, input and visible-window suites are intentionally not
# claimed by this offscreen gate. Keep this list explicit: adding one means
# claiming it, so it must be safe to run under an agent session.
$notRun = @(
    [ordered]@{ name = 'windows/scripts/Test-CombinedAppBar.ps1'; reason = 'live/hardware: not claimed by this gate' },
    [ordered]@{ name = 'windows/scripts/Test-DesktopTakeover.ps1'; reason = 'live/hardware: not claimed by this gate' },
    [ordered]@{ name = 'windows/scripts/Test-InstalledFrame.ps1'; reason = 'live/hardware: not claimed by this gate' },
    [ordered]@{ name = 'windows/scripts/Test-InstalledTray.ps1'; reason = 'live/hardware: not claimed by this gate' },
    [ordered]@{ name = 'windows/scripts/Test-InvisibleTaskbarProbe.ps1'; reason = 'live/hardware: not claimed by this gate' },
    [ordered]@{ name = 'windows/scripts/Test-NexusAudioStress.ps1'; reason = 'live/hardware: not claimed by this gate' }
)

$manifest = [ordered]@{
    schemaVersion = 1
    runId = [guid]::NewGuid().ToString('N')
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    completedAtUtc = $null
    completed = $false
    result = 'failed'
    exitCode = 1
    buildRoot = $BuildRoot
    options = [ordered]@{ skipBuild = [bool]$SkipBuild; jobs = $Jobs; performanceBaseline = $PerformanceBaseline }
    shell = [ordered]@{ head = $null; dirty = $null }
    backend = [ordered]@{
        path = 'windows/deps/quickshell'
        gitlink = $null
        checkedOut = $null
        sourcesLock = $null
        lockMatches = $false
        checkedOutMatchesLock = $false
        dirty = $null
    }
    toolchain = [ordered]@{
        qt = $null; qtPrefix = $QtPrefix; clang = $null; cmake = $null; ninja = $null
        windows = [Environment]::OSVersion.VersionString; msvc = $null; windowsSdk = $null
    }
    steps = @()
    totals = [ordered]@{ steps = 0; passed = 0; failed = 0; skipped = 0; assertions = 0 }
    notRun = @($notRun)
    errors = @()
}

function Write-Manifest {
    Write-CaelestiaJsonAtomic $OutFile (ConvertTo-SafeManifestValue $manifest)
}

function Format-Argument([string]$Value) {
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function ConvertFrom-JsonOutput([string]$Text) {
    if (-not $Text) { return $null }
    $trimmed = $Text.Trim()
    # Runners may print fixture output before their result object. The result is
    # the last pretty-printed block that starts on its own line.
    $lines = @($trimmed -split "`r?`n")
    $start = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Trim() -eq '{') { $start = $i; break }
    }
    if ($start -ge 0) {
        try { return (($lines[$start..($lines.Count - 1)] -join "`n") | ConvertFrom-Json) } catch { }
    }
    $first = $trimmed.IndexOf('{')
    $last = $trimmed.LastIndexOf('}')
    if ($first -lt 0 -or $last -le $first) { return $null }
    try { return ($trimmed.Substring($first, $last - $first + 1) | ConvertFrom-Json) }
    catch { return $null }
}

# Runners name their fixtures differently (fixture, battery, profiles or a
# top-level assertions field). Sum every reported fixture-assertion field, but
# ignore the aggregate top-level `fixture` alias when named fixture fields
# exist. Battery keeps each fixture's assertions under its own fixture object.
function Add-AssertionFields($Value, [bool]$SkipFixture, [ref]$Sum, [ref]$Found) {
    if ($null -eq $Value -or $Value -is [string]) { return }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary])) {
        foreach ($item in $Value) { Add-AssertionFields $item $false $Sum $Found }
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [System.Collections.IDictionary]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($SkipFixture -and $property.Name -eq 'fixture') { continue }
            if ($property.Name -eq 'assertions') {
                $number = 0
                if ([int]::TryParse("$($property.Value)", [ref]$number)) {
                    $Sum.Value += $number
                    $Found.Value = $true
                }
                continue
            }
            Add-AssertionFields $property.Value $false $Sum $Found
        }
    }
}

function Get-ReportedAssertions($Parsed) {
    if (-not $Parsed) { return $null }
    $sum = 0
    $found = $false
    Add-AssertionFields $Parsed $true ([ref]$sum) ([ref]$found)
    if (-not $found -and $null -ne $Parsed.fixture) {
        Add-AssertionFields $Parsed.fixture $false ([ref]$sum) ([ref]$found)
    }
    if ($found) { return $sum }
    return $null
}

function Read-BuildRecord {
    $path = Join-Path $BuildRoot 'logs\build.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Update-Provenance {
    try {
        $head = (& git -C $repoRoot rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'git rev-parse HEAD failed' }
        $manifest.shell.head = "$head".Trim()
        $manifest.shell.dirty = [bool]@(& git -C $repoRoot status --porcelain 2>$null)
        $lock = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\sources.lock.json') -Raw | ConvertFrom-Json
        $gitlinkLine = & git -C $repoRoot ls-tree HEAD -- $manifest.backend.path 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $gitlinkLine) { throw "Could not read the backend gitlink from $repoRoot." }
        $manifest.backend.gitlink = ($gitlinkLine -split '\s+')[2]
        $manifest.backend.sourcesLock = [string]$lock.quickshell.revision
        $backendPath = Join-Path $repoRoot $manifest.backend.path
        if (Test-Path -LiteralPath (Join-Path $backendPath '.git')) {
            $checkedOut = & git -C $backendPath rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0) { $manifest.backend.checkedOut = "$checkedOut".Trim() }
            $manifest.backend.dirty = [bool]@(& git -C $backendPath status --porcelain 2>$null)
        }
        $manifest.backend.lockMatches = ($manifest.backend.gitlink -eq $manifest.backend.sourcesLock)
        $manifest.backend.checkedOutMatchesLock = ($manifest.backend.checkedOut -eq $manifest.backend.sourcesLock)
        if (-not ($manifest.backend.lockMatches -and $manifest.backend.checkedOutMatchesLock)) {
            $manifest.errors += "The backend gitlink, checkout and sources.lock.json do not agree."
        }
    } catch {
        $manifest.errors += "Provenance check failed: $_"
    }
}

function Update-Toolchain {
    $record = Read-BuildRecord
    if ($record) {
        $manifest.toolchain.qt = $record.qtVersion
        $manifest.toolchain.qtPrefix = $record.qtPrefix
        $manifest.toolchain.clang = $record.compiler
        $manifest.toolchain.cmake = $record.cmake
        $manifest.toolchain.ninja = "$($record.ninja)".Trim()
        $manifest.toolchain.windows = $record.windows
        $manifest.toolchain.msvc = $record.msvcToolsVersion
        $manifest.toolchain.windowsSdk = $record.windowsSdkVersion
    }
}

# Build-Prototype.ps1 enters only its own VS environment. The environment and
# fixture steps run as child processes and inherit PATH, so enter the same VS
# environment here first. This mirrors the build script; it runs no check.
function Enter-BuildEnvironment {
    $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $vswhere = Join-Path $installer 'vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Build Tools with C++ tools are required.' }
    $vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsRoot) { throw 'No Visual Studio installation with the x64 C++ tools was found.' }
    $env:PATH = "$installer;$env:PATH"
    & (Join-Path $vsRoot 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
    $env:PATH = "$LlvmBin;$QtPrefix\bin;$env:PATH"
    if ($ToolsBin) { $env:PATH = "$ToolsBin;$env:PATH" }
}

function New-Step {
    param([string]$Name, [string]$Kind, [string]$Command)
    return [ordered]@{
        name = $Name
        kind = $Kind
        command = $Command
        exitCode = $null
        durationSeconds = 0.0
        status = 'skipped'
        skipReason = $null
        counts = $null
        assertions = $null
        skipReasons = @()
        details = $null
        log = [ordered]@{ stdout = $null; stderr = $null }
    }
}

function Add-SkippedStep([string]$Name, [string]$Kind, [string]$Command, [string]$Reason) {
    $step = New-Step $Name $Kind $Command
    $step.skipReason = $Reason
    $manifest.steps += $step
    Write-Manifest
}

function Invoke-ScriptStep {
    param(
        [string]$Name,
        [string]$Kind,
        [string]$ScriptPath,
        [string[]]$ScriptArguments,
        [string]$LogStem
    )
    $argumentLine = (@($ScriptArguments | ForEach-Object { Format-Argument $_ }) -join ' ')
    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (Format-Argument $ScriptPath)
    if ($argumentLine) { $command += ' ' + $argumentLine }
    $step = New-Step $Name $Kind $command
    $stdoutPath = Join-Path $logRoot "$LogStem.stdout.log"
    $stderrPath = Join-Path $logRoot "$LogStem.stderr.log"
    $step.log.stdout = $stdoutPath
    $step.log.stderr = $stderrPath

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Format-Argument $ScriptPath)
    if ($argumentLine) { $info.Arguments += ' ' + $argumentLine }
    $info.WorkingDirectory = $scratch
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $child = $null
    try {
        $child = [Diagnostics.Process]::Start($info)
        $outTask = $child.StandardOutput.ReadToEndAsync()
        $errTask = $child.StandardError.ReadToEndAsync()
        $child.WaitForExit()
        $stdout = [string]$outTask.GetAwaiter().GetResult()
        $stderr = [string]$errTask.GetAwaiter().GetResult()
        $step.exitCode = $child.ExitCode
    } catch {
        $stdout = ''
        $stderr = "Could not run the step: $_"
        $step.exitCode = 1
        $manifest.errors += "$Name could not run: $_"
    } finally {
        $stopwatch.Stop()
        if ($child) { $child.Dispose() }
    }
    $step.durationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    [IO.File]::WriteAllText($stdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrPath, $stderr, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Step = $step; Stdout = $stdout; Stderr = $stderr }
}

try {
    Update-Provenance
    Write-Manifest

    try {
        Enter-BuildEnvironment
    } catch {
        $manifest.errors += "Build environment setup failed: $_"
    }

    $environmentScript = Join-Path $PSScriptRoot 'Test-Environment.ps1'
    $environmentArguments = @('-QtPrefix', $QtPrefix, '-Json', '-Strict')
    $run = Invoke-ScriptStep 'environment' 'environment' $environmentScript $environmentArguments 'environment'
    $environment = $run.Step
    $report = ConvertFrom-JsonOutput $run.Stdout
    if ($report) {
        $environment.details = [ordered]@{
            nativeToolchainReady = [bool]$report.nativeToolchainReady
            blockers = @($report.blockers)
            sourceMatches = [bool]$report.source.matches
            stagingEntries = $report.stagingManifest.entries
        }
        if (($null -ne $report.nativeToolchainReady) -and -not $report.nativeToolchainReady) {
            $environment.skipReasons = @($report.blockers)
        }
    }
    $environment.status = if ($environment.exitCode -eq 0) { 'passed' } else { 'failed' }
    $manifest.steps += $environment
    Write-Manifest

    $environmentOk = $environment.status -eq 'passed'
    $buildScript = Join-Path $PSScriptRoot 'Build-Prototype.ps1'
    $buildArguments = @('-QtPrefix', $QtPrefix, '-LlvmBin', $LlvmBin, '-Cli11Include', $Cli11Include)
    if ($ToolsBin) { $buildArguments += @('-ToolsBin', $ToolsBin) }
    $buildArguments += @('-BuildRoot', $BuildRoot, '-Jobs', "$Jobs", '-Tests')
    $buildCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (Format-Argument $buildScript) +
        ' ' + ((@($buildArguments | ForEach-Object { Format-Argument $_ })) -join ' ')

    $buildOk = $false
    if (-not $environmentOk) {
        Add-SkippedStep 'build' 'build' $buildCommand 'environment check failed'
    } elseif ($SkipBuild) {
        Add-SkippedStep 'build' 'build' $buildCommand 'cached run (-SkipBuild): using the existing build root'
        $buildOk = $true
    } else {
        $run = Invoke-ScriptStep 'build' 'build' $buildScript $buildArguments 'build'
        $build = $run.Step
        $build.status = if ($build.exitCode -eq 0) { 'passed' } else { 'failed' }
        $buildRecord = Read-BuildRecord
        if ($buildRecord) {
            $build.details = [ordered]@{
                sourceRevision = $buildRecord.sourceRevision
                sourceDirty = $buildRecord.sourceDirty
                backendRevision = $buildRecord.backendRevision
                glazierRevision = $buildRecord.glazierRevision
                glazierBundled = $buildRecord.glazierBundled
                builtAtUtc = $buildRecord.builtAtUtc
            }
        }
        $manifest.steps += $build
        Write-Manifest
        $buildOk = $build.status -eq 'passed'
    }
    Update-Toolchain

    if (-not $environmentOk) {
        $reason = 'environment check failed'
    } elseif (-not $buildOk) {
        $reason = 'build step failed'
    } else {
        $reason = $null
    }

    $backendScript = Join-Path $PSScriptRoot 'Test-BackendNative.ps1'
    $backendArguments = @('-BuildRoot', $BuildRoot)
    $backendCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (Format-Argument $backendScript) +
        ' ' + ((@($backendArguments | ForEach-Object { Format-Argument $_ })) -join ' ')
    if ($reason) {
        Add-SkippedStep 'backend-native' 'backend-native' $backendCommand $reason
    } else {
        $run = Invoke-ScriptStep 'backend-native' 'backend-native' $backendScript $backendArguments 'backend-native'
        $backend = $run.Step
        $backendManifestPath = Join-Path $BuildRoot 'backend-native-tests\manifest.json'
        $backendManifest = $null
        if (Test-Path -LiteralPath $backendManifestPath -PathType Leaf) {
            try { $backendManifest = Get-Content -LiteralPath $backendManifestPath -Raw | ConvertFrom-Json } catch { }
        }
        $backendPassed = $backend.exitCode -eq 0
        if ($backendManifest) {
            $backendPassed = $backendPassed -and [bool]$backendManifest.passed
            $backend.counts = [ordered]@{
                passed = [int]$backendManifest.totals.passed
                failed = [int]$backendManifest.totals.failed
                skipped = [int]$backendManifest.totals.skipped
                fixtures = [int]$backendManifest.totals.fixtures
                casesSkipped = [int]$backendManifest.totals.casesSkipped
            }
            $backend.skipReasons = @($backendManifest.tests |
                Where-Object { $_.result -eq 'skipped' -and $_.skipReason } |
                ForEach-Object { "$($_.name): $($_.skipReason)" })
            $backend.details = [ordered]@{
                manifest = $backendManifestPath
                manifestPassed = [bool]$backendManifest.passed
                gateFailures = @($backendManifest.gateFailures)
                error = $backendManifest.error
            }
        } else {
            $backend.details = [ordered]@{ manifest = $backendManifestPath; manifestPassed = $null }
        }
        $backend.status = if ($backendPassed) { 'passed' } else { 'failed' }
        $manifest.steps += $backend
        Write-Manifest
    }

    $smokeScript = Join-Path $PSScriptRoot 'Test-Smoke.ps1'
    $smokeArguments = @('-BuildRoot', $BuildRoot, '-QtPrefix', $QtPrefix)
    $smokeCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (Format-Argument $smokeScript) +
        ' ' + ((@($smokeArguments | ForEach-Object { Format-Argument $_ })) -join ' ')
    if ($reason) {
        Add-SkippedStep 'smoke' 'smoke' $smokeCommand $reason
    } else {
        $run = Invoke-ScriptStep 'smoke' 'smoke' $smokeScript $smokeArguments 'smoke'
        $smoke = $run.Step
        $smoke.status = if ($smoke.exitCode -eq 0) { 'passed' } else { 'failed' }
        $smoke.counts = [ordered]@{
            passed = $(if ($smoke.exitCode -eq 0) { 1 } else { 0 })
            failed = $(if ($smoke.exitCode -eq 0) { 0 } else { 1 })
            skipped = 0
        }
        $manifest.steps += $smoke
        Write-Manifest
    }

    $runners = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*Service.ps1' -File | Sort-Object Name)
    foreach ($runner in $runners) {
        $name = $runner.BaseName
        $runnerArguments = @('-QtPrefix', $QtPrefix, '-BuildRoot', $BuildRoot)
        $runnerCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (Format-Argument $runner.FullName) +
            ' ' + ((@($runnerArguments | ForEach-Object { Format-Argument $_ })) -join ' ')
        if ($reason) {
            Add-SkippedStep $name 'fixture' $runnerCommand $reason
            continue
        }
        $run = Invoke-ScriptStep $name 'fixture' $runner.FullName $runnerArguments $name
        $step = $run.Step
        $parsed = ConvertFrom-JsonOutput $run.Stdout
        if ($parsed) {
            $step.assertions = Get-ReportedAssertions $parsed
            $step.counts = [ordered]@{
                passed = $(if (($step.exitCode -eq 0) -and ($parsed.passed -ne $false)) { 1 } else { 0 })
                failed = $(if (($step.exitCode -ne 0) -or ($parsed.passed -eq $false)) { 1 } else { 0 })
                skipped = 0
            }
            $step.details = [ordered]@{
                reportedPassed = $parsed.passed
                timedOut = $parsed.timedOut
                diagnostics = @($parsed.diagnostics).Count
                fixture = $parsed.fixture
            }
        } else {
            $step.counts = [ordered]@{
                passed = $(if ($step.exitCode -eq 0) { 1 } else { 0 })
                failed = $(if ($step.exitCode -eq 0) { 0 } else { 1 })
                skipped = 0
            }
        }
        $step.status = if (($step.exitCode -eq 0) -and -not ($parsed -and ($parsed.passed -eq $false))) { 'passed' } else { 'failed' }
        $manifest.steps += $step
        Write-Manifest
    }

    # Test-RunningApps is offscreen with fakes; the other adapter/live checks
    # stay in notRun.
    $adapterScript = Join-Path $PSScriptRoot 'Test-RunningApps.ps1'
    $adapterArguments = @('-QtPrefix', $QtPrefix, '-BuildRoot', $BuildRoot)
    $adapterCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (Format-Argument $adapterScript) +
        ' ' + ((@($adapterArguments | ForEach-Object { Format-Argument $_ })) -join ' ')
    if ($reason) {
        Add-SkippedStep 'Test-RunningApps' 'fixture' $adapterCommand $reason
    } else {
        $run = Invoke-ScriptStep 'Test-RunningApps' 'fixture' $adapterScript $adapterArguments 'Test-RunningApps'
        $step = $run.Step
        $parsed = ConvertFrom-JsonOutput $run.Stdout
        $step.assertions = Get-ReportedAssertions $parsed
        $step.counts = [ordered]@{
            passed = $(if (($step.exitCode -eq 0) -and -not ($parsed -and ($parsed.passed -eq $false))) { 1 } else { 0 })
            failed = $(if (($step.exitCode -ne 0) -or ($parsed -and ($parsed.passed -eq $false))) { 1 } else { 0 })
            skipped = 0
        }
        if ($parsed) {
            $step.details = [ordered]@{
                sourceMatchesBuild = $parsed.sourceMatchesBuild
                platform = $parsed.platform
                timedOut = $parsed.timedOut
                fixture = $parsed.fixture
            }
        }
        $step.status = if (($step.exitCode -eq 0) -and -not ($parsed -and ($parsed.passed -eq $false))) { 'passed' } else { 'failed' }
        $manifest.steps += $step
        Write-Manifest
        $evidence = [string]$parsed.evidenceDirectory
        if ($step.status -eq 'passed' -and $evidence -and
            ([IO.Path]::GetFullPath($evidence)).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $evidence) -like 'caelestia-running-apps-*') {
            Remove-Item -LiteralPath $evidence -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($PerformanceBaseline) {
        $benchScript = Join-Path $PSScriptRoot 'Measure-ShellBenchmark.ps1'
        $benchRun = Join-Path $logRoot 'performance'
        $benchArguments = @('-QtPrefix', $QtPrefix, '-BuildRoot', $BuildRoot, '-SourceRoot', $repoRoot,
            '-RunRoot', $benchRun, '-BaselineRoot', $BaselineRoot, '-CompareBaseline', $PerformanceBaseline)
        $benchCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + (Format-Argument $benchScript) +
            ' ' + ((@($benchArguments | ForEach-Object { Format-Argument $_ })) -join ' ')
        if ($reason) {
            Add-SkippedStep 'performance' 'performance' $benchCommand $reason
        } else {
            $run = Invoke-ScriptStep 'performance' 'performance' $benchScript $benchArguments 'performance'
            $step = $run.Step
            $verdictPath = Join-Path $benchRun 'verdict.json'
            $verdict = $null
            if (Test-Path -LiteralPath $verdictPath -PathType Leaf) {
                try { $verdict = Get-Content -LiteralPath $verdictPath -Raw | ConvertFrom-Json } catch { }
            }
            # Exit 0 means same or improved; 2 regressed, 3 inconclusive, 4 contract mismatch.
            $step.status = if (($step.exitCode -eq 0) -and $verdict -and ($verdict.overall -in @('same', 'improved'))) { 'passed' } else { 'failed' }
            if ($verdict) {
                $metrics = @($verdict.comparisons | ForEach-Object { $_.metrics.PSObject.Properties } |
                    Where-Object { $_.Value.gating } | ForEach-Object { [pscustomobject]@{ name = $_.Name; verdict = $_.Value.verdict } })
                $step.details = [ordered]@{
                    baseline = $PerformanceBaseline
                    verdict = $verdictPath
                    overall = $verdict.overall
                    metrics = [ordered]@{}
                }
                foreach ($kind in @('improved', 'same', 'regressed', 'inconclusive')) {
                    $step.details.metrics[$kind] = @($metrics | Where-Object verdict -eq $kind | ForEach-Object name)
                }
            }
            $manifest.steps += $step
            Write-Manifest
        }
    }
} catch {
    $manifest.errors += "The gate stopped unexpectedly: $_"
} finally {
    $manifest.completed = $true
    $manifest.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    $manifest.totals.steps = @($manifest.steps).Count
    $manifest.totals.passed = @($manifest.steps | Where-Object { $_.status -eq 'passed' }).Count
    $manifest.totals.failed = @($manifest.steps | Where-Object { $_.status -eq 'failed' }).Count
    $manifest.totals.skipped = @($manifest.steps | Where-Object { $_.status -eq 'skipped' }).Count
    $manifest.totals.assertions = (@($manifest.steps | ForEach-Object { [int]$_.assertions } |
        Where-Object { $_ -gt 0 } | Measure-Object -Sum).Sum)
    if ($null -eq $manifest.totals.assertions) { $manifest.totals.assertions = 0 }
    $provenanceOk = ($manifest.backend.lockMatches -and $manifest.backend.checkedOutMatchesLock)
    $manifest.result = if (($manifest.totals.failed -eq 0) -and ($manifest.errors.Count -eq 0) -and $provenanceOk) { 'passed' } else { 'failed' }
    $manifest.exitCode = if ($manifest.result -eq 'passed') { 0 } else { 1 }
    Write-Manifest
    $privacy = Get-ManifestPrivacyReport $OutFile
    if ($privacy.total -gt 0) {
        $manifest.errors += 'The manifest contains private path or user-name data.'
        $manifest.result = 'failed'
        $manifest.exitCode = 1
        Write-Manifest
        Write-Output "PRIVACY FAIL: $($privacy.homeHits) home-path and $($privacy.userHits) user-name occurrences remain in the manifest."
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($manifest.result -ne 'passed') {
    foreach ($step in $manifest.steps) {
        if ($step.status -eq 'failed') {
            Write-Output "FAIL $($step.name) (exit $($step.exitCode)): $($step.log.stderr)"
        }
    }
    foreach ($errorText in $manifest.errors) { Write-Output "ERROR $errorText" }
    Write-Output "FAIL candidate validation: $($manifest.totals.passed) passed, $($manifest.totals.failed) failed, $($manifest.totals.skipped) skipped. Manifest: $OutFile"
    exit 1
}
Write-Output "PASS candidate validation: $($manifest.totals.passed) passed, 0 failed, $($manifest.totals.skipped) skipped, $($manifest.totals.assertions) assertions. Manifest: $OutFile"
exit 0
