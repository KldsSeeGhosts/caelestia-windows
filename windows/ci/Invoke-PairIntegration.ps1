[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ShellRoot,
    [Parameter(Mandatory)][string]$BackendRoot,
    [Parameter(Mandatory)][ValidateSet('pinned', 'candidate')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$BackendSha,
    [Parameter(Mandatory)][string]$ToolRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$Results,
    [Parameter(Mandatory)][string]$JUnit,
    [string]$Python = 'python',
    [string]$CompilerLauncher,
    [string]$RustCacheDirectory,
    # Compile parallelism for the production build only.
    [ValidateRange(1, 16)][int]$Jobs = 2,
    [ValidateRange(1, 4)][int]$QmlJobs = 1,
    # Early, unrecorded Services run for a fast first error. It writes only
    # under this fresh root, never Results, and is never pass evidence: the
    # recorded integration reruns the Services gate from scratch.
    [string]$ServicesPreflightRoot,
    # Verified native reuse only. No compiler, smoke/release checks or pair
    # journal/report/receipt may run through this branch.
    [switch]$TestOnly,
    # Only opt in for disposable hosted fixtures, never retained artifacts.
    [switch]$EchoDiagnostics
)
$ErrorActionPreference = 'Stop'
function Test-PathOverlap([string]$Left, [string]$Right) {
    return $Left.Equals($Right, [StringComparison]::OrdinalIgnoreCase) -or
        $Left.StartsWith($Right + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $Right.StartsWith($Left + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Assert-NoReparseAncestor([string]$Path) {
    # GetFullPath normalizes spelling, not filesystem aliases. Preflight must
    # not reach a protected root through a junction/symlink in either path.
    for ($current = $Path; $current; $current = Split-Path -Parent $current) {
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Services preflight paths must not contain reparse points.'
        }
    }
}
$ShellRoot = (Resolve-Path -LiteralPath $ShellRoot).Path.TrimEnd('\')
$BackendRoot = (Resolve-Path -LiteralPath $BackendRoot).Path.TrimEnd('\')
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\')
$Results = [IO.Path]::GetFullPath($Results).TrimEnd('\')
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot).TrimEnd('\')
$outputs = @($BuildRoot, $Results)
if ($ServicesPreflightRoot) {
    $ServicesPreflightRoot = [IO.Path]::GetFullPath($ServicesPreflightRoot).TrimEnd('\')
    $outputs += $ServicesPreflightRoot
    foreach ($path in @($ShellRoot, $BackendRoot, $ToolRoot) + $outputs) { Assert-NoReparseAncestor $path }
}
foreach ($output in $outputs) {
    foreach ($source in @($ShellRoot, $BackendRoot)) {
        if (Test-PathOverlap $output $source) {
            throw 'Pair outputs must stay outside both source roots.'
        }
    }
}
if ($ServicesPreflightRoot) {
    foreach ($protected in @(
        @{ path = $Results; name = 'pair results' },
        @{ path = $BuildRoot; name = 'the production build' },
        @{ path = $ToolRoot; name = 'read-only tools' })) {
        if (Test-PathOverlap $ServicesPreflightRoot $protected.path) {
            throw "The Services preflight must stay separate from $($protected.name)."
        }
    }
    if (Test-Path -LiteralPath $ServicesPreflightRoot) { throw 'The Services preflight requires a fresh output root.' }
}
if (-not $TestOnly -and (Test-Path -LiteralPath $BuildRoot)) { throw 'Pair production build requires a fresh build root.' }
if ($TestOnly -and $ServicesPreflightRoot) { throw 'Test-only reuse cannot run a pair preflight.' }
$spec = Get-Content -LiteralPath "$ShellRoot\windows\toolchain.json" -Raw | ConvertFrom-Json
$qt = Join-Path $ToolRoot $spec.qtDirectory
$llvm = Join-Path $ToolRoot "$($spec.llvmDirectory)\bin"
$tools = Join-Path $ToolRoot 'tools\Scripts'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scripts = Join-Path $ShellRoot 'windows\scripts'
$env:PATH = "$tools;$qt\bin;$BuildRoot\caelestia\lib;$env:PATH"
$env:QT_QPA_PLATFORM = 'offscreen'
$env:QT_QPA_PLATFORM_PLUGIN_PATH = "$qt\plugins\platforms"
$env:QT_QUICK_BACKEND = 'software'
$env:PYTHONDONTWRITEBYTECODE = '1'
$common = @('-NoProfile', '-NonInteractive', '-File')
function Get-ServicesArguments([string]$OutputRoot) {
    return $common + @("$scripts\Test-Validation.ps1", '-Suite', 'Services',
        '-BuildRoot', $BuildRoot, '-QtPrefix', $qt, '-OutputRoot', $OutputRoot)
}
function Get-ShellArguments {
    $arguments = $common + @("$scripts\Test-Validation.ps1", '-Suite', 'Shell',
        '-BuildRoot', $BuildRoot, '-QtPrefix', $qt, '-OutputRoot', "$Results\Shell")
    if ($QmlJobs -gt 1) { $arguments += @('-QmlJobs', "$QmlJobs") }
    return $arguments
}
function Get-PluginArguments {
    return @('--test-dir', "$BuildRoot\caelestia", '--output-on-failure',
        '--timeout', '60', '--no-tests=error', '--output-junit', "$Results\plugins.raw.xml")
}
function Invoke-Logged([string]$Log, [string]$Executable, [string[]]$CommandArguments) {
    $code = 1
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 1
        & $Executable @CommandArguments 2>&1 | ForEach-Object { "$_" } |
            Set-Content -LiteralPath $Log -Encoding UTF8 -ErrorAction Stop
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    return $code
}
function Write-FailureTail([string]$Name, [string]$Log) {
    if (-not $EchoDiagnostics) { return }
    Write-Output "Failed isolated stage: $Name (last 80 lines)"
    $tail = (Get-Content -LiteralPath $Log -Tail 80 -Encoding UTF8) -join "`n"
    if ($tail.Length -gt 16000) { $tail = '[earlier output truncated]' + "`n" + $tail.Substring($tail.Length - 15970) }
    Write-Output $tail
}

if ($TestOnly) {
    if (Test-Path -LiteralPath $Results) { throw 'Reuse tests require fresh results.' }
    New-Item -ItemType Directory -Path $Results | Out-Null
    $outcomes = @('Services', 'plugins', 'Shell') | ForEach-Object {
        [pscustomobject]@{ name = $_; outcome = 'not_run'; exitCode = $null }
    }
    foreach ($stage in @(
        @{ name = 'Services'; exe = $ps; arguments = (Get-ServicesArguments "$Results\Services") },
        @{ name = 'plugins'; exe = "$tools\ctest.exe"; arguments = (Get-PluginArguments) },
        @{ name = 'Shell'; exe = $ps; arguments = (Get-ShellArguments) })) {
        $log = "$Results\$($stage.name).private.log"
        $code = Invoke-Logged $log $stage.exe $stage.arguments
        $outcome = $outcomes | Where-Object name -eq $stage.name
        $outcome.exitCode = $code
        $outcome.outcome = if ($code -eq 0) { 'success' } else { 'failure' }
        $outcomes | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$Results\reuse-tests.json" -Encoding UTF8
        if ($code -ne 0) {
            Write-FailureTail $stage.name $log
            throw "Reuse test failed: $($stage.name)"
        }
    }
    return
}

if ($ServicesPreflightRoot) {
    $preflight = $ServicesPreflightRoot
    New-Item -ItemType Directory -Path $preflight | Out-Null
    $log = Join-Path $preflight 'services.private.log'
    $code = Invoke-Logged $log $ps (Get-ServicesArguments (Join-Path $preflight 'Services'))
    if ($code -ne 0) {
        Write-FailureTail 'services-preflight' $log
        Write-Output "Services preflight failed: exit=$code. Local diagnostic log: $log"
        Write-Output 'This early run is not a pair receipt; the recorded integration stage was not started.'
        exit 1
    }
    Write-Output 'Services preflight passed. It is not evidence; the recorded integration reruns Services.'
    exit 0
}

New-Item -ItemType Directory -Force -Path $Results | Out-Null
$journal = @('services', 'production', 'release-toolchain', 'plugins', 'shell', 'smoke') | ForEach-Object {
    [ordered]@{ name = $_; outcome = 'not_run'; exitCode = $null; durationSeconds = $null }
}
function Save-Journal {
    $temporary = Join-Path $Results 'integration-stages.tmp'
    $journal | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination "$Results\integration-stages.json" -Force
}
function Invoke-Gate([int]$Index, [string]$Executable, [string[]]$CommandArguments) {
    $item = $journal[$Index]
    $item.outcome = 'running'
    Save-Journal
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $code = 1
    $log = "$Results\$($item.name).private.log"
    try {
        $code = Invoke-Logged $log $Executable $CommandArguments
    } finally {
        $item.exitCode = $code
        $item.durationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 6)
        $item.outcome = if ($code -eq 0) { 'success' } else { 'failure' }
        Save-Journal
        # Fixed stage labels and numeric state only, never the private output.
        Write-Output ("Integration timing: {0} outcome={1} exit={2} seconds={3}" -f
            $item.name, $item.outcome, $item.exitCode,
            $item.durationSeconds.ToString('F6', [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($code -ne 0) {
        Write-FailureTail $item.name $log
        throw "Pair integration stage failed: $($item.name). Raw output excluded from retained artifacts."
    }
}
$failed = $false
Save-Journal
try {
    Invoke-Gate 0 $ps (Get-ServicesArguments "$Results\Services")
    $buildArguments = $common + @("$scripts\Build-Prototype.ps1", '-BuildRoot', $BuildRoot,
        '-QtPrefix', $qt, '-LlvmBin', $llvm, '-Cli11Include', (Join-Path $ToolRoot $spec.cli11Directory),
        '-ToolsBin', $tools, '-Jobs', "$Jobs", '-PublicRelease', '-PluginTests')
    if ($Mode -eq 'candidate') { $buildArguments += @('-BackendRoot', $BackendRoot, '-CandidateBackendRevision', $BackendSha) }
    if ($CompilerLauncher) { $buildArguments += @('-CompilerLauncher', $CompilerLauncher) }
    if ($RustCacheDirectory) { $buildArguments += @('-RustCacheDirectory', $RustCacheDirectory) }
    Invoke-Gate 1 $ps $buildArguments
    Invoke-Gate 2 $ps ($common + @("$scripts\New-CaelestiaRelease.ps1", '-BuildRoot', $BuildRoot, '-ValidateToolchainOnly'))
    Invoke-Gate 3 "$tools\ctest.exe" (Get-PluginArguments)
    Invoke-Gate 4 $ps (Get-ShellArguments)
    $smokeArguments = $common + @("$scripts\Test-Smoke.ps1", '-BuildRoot', $BuildRoot,
        '-QtPrefix', $qt, '-RunRoot', "$Results\smoke")
    if ($Mode -eq 'candidate') { $smokeArguments += @('-CandidateBackendRevision', $BackendSha) }
    Invoke-Gate 5 $ps $smokeArguments
} catch {
    $failed = $true
    if ($EchoDiagnostics) {
        $detail = ($_ | Out-String)
        if ($detail.Length -gt 16000) { $detail = $detail.Substring(0, 16000) }
        Write-Output $detail
    }
    foreach ($item in @($journal | Where-Object { $_.outcome -eq 'failure' })) {
        Write-Output "Pair integration failed: stage=$($item.name) exit=$($item.exitCode)"
        Write-Output "Local diagnostic log: $Results\$($item.name).private.log"
    }
    Write-Output 'First failed stage is preserved in integration-stages.json; later stages are not run.'
} finally {
    & $Python -I -B "$PSScriptRoot\pair_result.py" integration-report --results $Results --junit $JUnit
    if ($LASTEXITCODE -ne 0) {
        $failed = $true
        Write-Output "Integration report generation also failed: exit=$LASTEXITCODE. Inspect the earlier stage failure first."
    }
}
if ($failed) { exit 1 }
