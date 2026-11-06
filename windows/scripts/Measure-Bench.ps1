<#
.SYNOPSIS
Hill-climbing entry point: one area, all areas, or benchmarks selected by a diff.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$BuildRoot,
    [string]$BaseRoot,
    [string]$RunRoot,
    [string]$QtPrefix,
    [string]$SourceRoot,
    [string]$BaseSourceRoot,
    [string]$Area,
    [string]$DiffBase,
    [string]$DiffHead = 'HEAD',
    [switch]$SelectOnly,
    [string]$SchemePython,
    [string]$NativeRootA,
    [string]$NativeRootB,
    [string]$PlantB = 'None',
    [ValidateSet('AB', 'counterbalanced')][string]$Order = 'counterbalanced',
    [ValidateRange(0, 100)][double]$PlantPercent = 25
)
$ErrorActionPreference = 'Stop'
if ($Area -and $DiffBase) { throw 'Choose -Area or -DiffBase, not both.' }
$selection = @()
$details = [pscustomobject]@{ areas=@(); notCovered=@() }
if ($DiffBase) {
    $details = (& py -3 "$PSScriptRoot\ShellBench.py" select --base $DiffBase --head $DiffHead --json) | ConvertFrom-Json
    if ($LASTEXITCODE) { throw 'Diff selection failed.' }
    $selection = @($details.areas)
    foreach ($path in $details.notCovered) { Write-Host "Not covered (native provider, disabled in probes): $path" }
} else { $selection = @($(if ($Area) { $Area } else { 'all' })) }
if ($SelectOnly) { $selection; return }
if (-not $selection.Count) {
    Write-Output 'Only ignored paths changed. No benchmark run.'
    return
}
if (-not $BuildRoot -or -not $BaseRoot -or -not $RunRoot) { throw 'Measurement requires -BuildRoot, -BaseRoot and a new -RunRoot.' }
if (-not $QtPrefix) { $QtPrefix = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).qtPrefix }
$arguments = @{
    QtPrefix=$QtPrefix; BuildRoot=$BaseRoot; BuildRootB=$BuildRoot
    RunRoot=$RunRoot; SelectAreas=($selection -join ','); PlantB=$PlantB; PlantPercent=$PlantPercent; Order=$Order
}
if ($details.notCovered) { $arguments.NotCovered=$details.notCovered }
if ($Area) { $arguments.Area=$Area }
if ($SourceRoot) { $arguments.SourceRootB=$SourceRoot }
if ($BaseSourceRoot) { $arguments.SourceRoot=$BaseSourceRoot }
if ($SchemePython) { $arguments.SchemePython=$SchemePython }
if ($NativeRootA) { $arguments.NativeRootA=$NativeRootA }
if ($NativeRootB) { $arguments.NativeRootB=$NativeRootB }
& "$PSScriptRoot\Measure-ShellBenchmark.ps1" @arguments
exit $LASTEXITCODE
