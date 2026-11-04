<#
.SYNOPSIS
Runs repeated shell measurements and compares per-machine baselines.
.EXAMPLE
powershell -NoProfile -File windows/scripts/Measure-ShellBenchmark.ps1 -QtPrefix <Qt> -BuildRoot C:\b-bench -BuildRootB C:\b-bench-b -RunRoot C:\b-bench\runs\aa -Metric Idle -Mode NonVisible
.DESCRIPTION
Each side runs at least five times, in A,B,A,B order. Each metric has its own
fresh process and isolated profile. Nothing is installed or restarted.
Use -SaveBaseline <name> to store a successful unplanted A result outside the
repository. Use -CompareBaseline <name> with the same workload and mode.
The default store is %LOCALAPPDATA%\caelestia-windows-bench\baselines\<machine>.

Use -PlantB CPU, Resources, Panel, or Reload only for sensitivity experiments.
Plants affect disposable staged QML, never source or production behavior.
Run each category separately to keep its plant and workload explicit.

Live mode refuses without -LiveDesktop. Only the designated desktop QA owner
may run it. NonVisible never calls SwitchDesktop. Offscreen measures software
rendering and must not be described as native D3D11 presentation performance.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$BuildRootB,
    [string]$SourceRoot,
    [string]$SourceRootB,
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateSet('Idle', 'Resources', 'Panel', 'Reload')][string[]]$Metric = @('Idle', 'Resources', 'Panel', 'Reload'),
    [ValidateSet('NonVisible', 'Offscreen', 'Live')][string]$Mode = 'NonVisible',
    [ValidateRange(5, 100)][int]$Runs = 5,
    [ValidateRange(1, 3600)][int]$WarmupSeconds = 120,
    [ValidateRange(2, 86400)][int]$IdleSeconds = 300,
    [ValidateRange(2, 10000)][int]$Cycles = 100,
    [ValidateRange(0, 60)][int]$CycleIntervalSeconds = 15,
    [ValidateRange(0, 600)][int]$RecoverySeconds = 30,
    [ValidateRange(0, 15)][int]$ScreenIndex = 0,
    [ValidateSet('None', 'CPU', 'Resources', 'Panel', 'Reload')][string]$PlantB = 'None',
    [string]$BaselineRoot = (Join-Path $env:LOCALAPPDATA 'caelestia-windows-bench\baselines'),
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$SaveBaseline,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$CompareBaseline,
    [switch]$LiveDesktop
)
$ErrorActionPreference = 'Stop'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($Mode -eq 'Live' -and -not $LiveDesktop) { throw 'Live trials require -LiveDesktop.' }
if ($PlantB -ne 'None' -and (-not $BuildRootB -or $SaveBaseline)) { throw 'Plants require a B build and cannot save a baseline.' }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be new.' }
$BaselineRoot = Join-Path ([IO.Path]::GetFullPath($BaselineRoot)) $env:COMPUTERNAME
$repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
if ($BaselineRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline store must be outside the repository.' }
$baseline = if ($CompareBaseline) { Join-Path $BaselineRoot "$CompareBaseline.json" } else { $null }
if ($baseline -and -not (Test-Path -LiteralPath $baseline)) { throw "Baseline does not exist: $baseline" }
if ($SaveBaseline -and (Test-Path -LiteralPath "$BaselineRoot\$SaveBaseline.json")) { throw 'Choose a new baseline name. Existing baselines are immutable.' }
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$manifest = [ordered]@{ schemaVersion=2; twoBuilds=[bool]$BuildRootB; runs=@() }
$sides = [ordered]@{ A=$BuildRoot }
if ($BuildRootB) { $sides.B = $BuildRootB }
for ($index = 1; $index -le $Runs; $index++) {
    foreach ($category in $Metric) {
        foreach ($side in $sides.Keys) {
            $path = Join-Path $RunRoot "$category-$side-$index"
            $plant = if ($side -eq 'B') { $PlantB } else { 'None' }
            $arguments = @('-NoProfile', '-File', "$PSScriptRoot\Measure-ShellRuntime.ps1",
                '-QtPrefix', $QtPrefix, '-BuildRoot', $sides[$side], '-RunRoot', $path,
                '-Metric', $category, '-Mode', $Mode, '-WarmupSeconds', $WarmupSeconds,
                '-IdleSeconds', $IdleSeconds, '-Cycles', $Cycles, '-RecoverySeconds', $RecoverySeconds,
                '-CycleIntervalSeconds', $CycleIntervalSeconds,
                '-ScreenIndex', $ScreenIndex, '-Plant', $plant)
            $source = if ($side -eq 'B') { $SourceRootB } else { $SourceRoot }
            if ($source) { $arguments += @('-SourceRoot', $source) }
            if ($LiveDesktop) { $arguments += '-LiveDesktop' }
            Write-Host "$category $side trial $index/$Runs ($Mode, plant $plant)"
            & $windowsPowerShell @arguments *> "$RunRoot\$category-$side-$index.worker.log"
            $manifest.runs += [ordered]@{ side=$side; metric=$category; index=$index; path=$path; exitCode=$LASTEXITCODE }
            $manifest | ConvertTo-Json -Depth 8 | Set-Content "$RunRoot\manifest.json" -Encoding UTF8
        }
    }
}
$summaryArguments = @('-3', "$PSScriptRoot\Summarize-ShellRuntime.py", "$RunRoot\manifest.json", '--manifest', '--output', "$RunRoot\benchmark.json")
if ($baseline) { $summaryArguments += @('--compare', $baseline) }
& py @summaryArguments
if ($LASTEXITCODE -ne 0) { throw 'Summary failed.' }
$result = Get-Content "$RunRoot\benchmark.json" -Raw | ConvertFrom-Json
if ($SaveBaseline) {
    if (@($result.groups.PSObject.Properties | Where-Object { -not $_.Value.valid }).Count) { throw 'Incomplete results cannot become a baseline.' }
    New-Item -ItemType Directory -Force -Path $BaselineRoot | Out-Null
    [IO.File]::Copy("$RunRoot\benchmark.json", "$BaselineRoot\$SaveBaseline.json", $false)
}
Write-Output "$RunRoot\benchmark.json"
if ($result.errorCount -or @($result.groups.PSObject.Properties | Where-Object { -not $_.Value.valid }).Count) {
    throw 'One or more metric groups are inconclusive. Read benchmark.json and worker logs.'
}
