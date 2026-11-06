<#
.SYNOPSIS
Bounded same-session A/B measurement. Historical results never decide a verdict.
.DESCRIPTION
Writes self-contained results.json and report.html. Use Measure-Bench.ps1 for
area/diff selection. A worker failure aborts immediately, never "inconclusive".
The external deadline includes staging, workers, summarization and reporting.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$BuildRootB,
    [string]$SourceRoot,
    [string]$SourceRootB,
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateSet('all', 'idle', 'panels', 'lifecycle', 'update', 'tiling', 'tracker', 'providers', 'audio', 'media', 'tray', 'notifications', 'quota', 'scheme')][string]$Area = 'all',
    [ValidateRange(7, 9)][int]$Runs,
    [ValidateSet('AB', 'counterbalanced')][string]$Order = 'counterbalanced',
    [ValidateSet('None', 'CPU', 'Resources', 'Panel', 'Reload', 'Startup', 'Update', 'Tiling', 'Tracker', 'audio', 'media', 'tray', 'notifications', 'quota', 'Qml', 'Scheme', 'Sensitivity')][string]$PlantB = 'None',
    [string]$NativeRootA,
    [string]$NativeRootB,
    [string]$SelectAreas,
    [string]$SchemePython,
    [ValidateRange(0, 100)][double]$PlantPercent = 25,
    [string[]]$NotCovered
)
$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'Normal'
Add-Type -Name BenchmarkErrorMode -Namespace W -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint m);'
[W.BenchmarkErrorMode]::SetErrorMode(0x8003) | Out-Null
$arguments = @('-3', "$PSScriptRoot\ShellBench.py", 'run',
    '--qt', $QtPrefix, '--a', $BuildRoot, '--b', $BuildRootB,
    '--output', $RunRoot, '--area', $Area, '--plant', $PlantB, '--plant-percent', "$PlantPercent", '--order', $Order)
if ($Runs) { $arguments += @('--runs', "$Runs") }
if ($NotCovered) { $arguments += @('--not-covered') + $NotCovered }
if ($SourceRoot) { $arguments += @('--source-a', $SourceRoot) }
if ($SourceRootB) { $arguments += @('--source-b', $SourceRootB) }
if ($NativeRootA) { $arguments += @('--native-a', $NativeRootA) }
if ($NativeRootB) { $arguments += @('--native-b', $NativeRootB) }
if ($SelectAreas) { $arguments += @('--select', $SelectAreas) }
if ($SchemePython) { $arguments += @('--scheme-python', $SchemePython) }
# An outer deadline also covers hung setup, load checks and reporting, not just
# successful workload durations. Killing the owned tree cannot affect the live
# shell, which is never a descendant of this runner.
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = (& py -3 -c 'import sys; print(sys.executable)').Trim()
if ($LASTEXITCODE -ne 0) { throw 'Python 3 is required.' }
$info.Arguments = (@($arguments | Select-Object -Skip 1 | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PYTHONUTF8'] = '1'
$child = [Diagnostics.Process]::Start($info)
try {
    $stdout = $child.StandardOutput.ReadToEndAsync()
    $stderr = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(580000)) {
        & taskkill.exe /PID $child.Id /T /F 2>&1 | Out-Null
        throw 'Benchmark exceeded its 580-second external deadline; owned process tree terminated.'
    }
    Write-Output $stdout.GetAwaiter().GetResult()
    $errorText = $stderr.GetAwaiter().GetResult()
    if ($errorText) { Write-Output $errorText }
    $exitCode = $child.ExitCode
} finally { $child.Dispose() }
exit $exitCode
