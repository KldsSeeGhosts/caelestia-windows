#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$PairResults,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$Integration
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Caelestia-InstallCommon.ps1"
$BuildRoot = Resolve-CaelestiaDirectory $BuildRoot
$PairResults = Resolve-CaelestiaDirectory $PairResults
$OutputDirectory = Resolve-CaelestiaDirectory $OutputDirectory
foreach ($root in @($BuildRoot, $PairResults)) {
    if ($OutputDirectory -eq $root -or $OutputDirectory.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $root.StartsWith($OutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Transfer overlaps an input.' }
    Assert-CaelestiaNoReparsePoints $root
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Transfer requires fresh output.' }
function Copy-TransferFile([string]$Root, [string]$Relative, [string]$Directory) {
    $source = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing assembly input: $Relative" }
    $target = Join-Path (Join-Path $OutputDirectory $Directory) $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
}
# Native inventory is independently re-hashed against logs/build.json after
# restore. No CMake state, object files, PDBs or unrelated install files.
foreach ($relative in @('logs/build.json', 'quickshell/qs.exe',
    'install/caelestia-capture.exe', 'install/DesktopTakeover.dll')) {
    Copy-TransferFile $BuildRoot $relative 'b-public'
}
$qml = Join-Path $BuildRoot 'install\qml'
if (-not (Test-Path -LiteralPath $qml -PathType Container)) { throw 'Missing native QML tree.' }
foreach ($file in Get-ChildItem -LiteralPath $qml -File -Recurse -Force) {
    Copy-TransferFile $BuildRoot $file.FullName.Substring($BuildRoot.Length + 1) 'b-public'
}
$pairFiles = @('pair-request.json', 'candidate-result.json',
    'integration-stages.json', 'integration.xml', 'plugins.raw.xml')
if ($Integration) {
    $pairFiles += 'pair-local.json'
    # This is the production compiler's measured record, not a runner banner
    # or the fixture job's record. Preserve every identity for the join check.
    $build = Get-Content -LiteralPath (Join-Path $BuildRoot 'logs/build.json') -Raw | ConvertFrom-Json
    if (-not $build.toolchain) { throw 'Missing production actual toolchain.' }
    New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'ci-pair') -Force | Out-Null
    $build.toolchain | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'ci-pair/actual-toolchain.json') -Encoding UTF8
} else {
    $pairFiles += @('pair-result.json', 'portable.xml')
}
foreach ($relative in $pairFiles) {
    Copy-TransferFile $PairResults $relative 'ci-pair'
}
foreach ($suite in @('Services', 'Shell')) {
    Copy-TransferFile $PairResults "$suite/summary.json" 'ci-pair'
    $summary = Get-Content -LiteralPath (Join-Path $PairResults "$suite/summary.json") -Raw | ConvertFrom-Json
    foreach ($row in $summary.results) {
        if ($row.name -cnotmatch '^[A-Za-z0-9_-]+$') { throw 'Unsafe suite log name.' }
        # compute_envelope/suite_counts reads these logs to recount assertions.
        Copy-TransferFile $PairResults "$suite/$($row.name).log" 'ci-pair'
    }
}
