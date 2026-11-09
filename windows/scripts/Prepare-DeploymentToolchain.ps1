#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolRoot,
    [string]$Python = 'python',
    # Only an absent exact cache selects full canonical preparation.
    # An invalid restored cache must fail, never heal or bypass verification.
    [switch]$AllowFullPreparation,
    [string]$TimingPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
if ($ToolRoot -eq $repoRoot -or $ToolRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ToolRoot must be outside the source checkout.'
}
if (-not $TimingPath) { $TimingPath = Join-Path $ToolRoot 'logs\deployment-prepare-timing.json' }
$spec = Get-CaelestiaToolchain
$timings = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$total = [Diagnostics.Stopwatch]::StartNew()
function Save-DeploymentTiming([string]$Phase) {
    $timings.Add([ordered]@{ phase = $Phase; durationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 6) })
    $clock.Restart()
}
try {
    if ($AllowFullPreparation) {
        # A cold path retains the existing pinned Python, aqt, Qt, LLVM,
        # CLI11 and Rust provisioning and actual-toolchain assertions.
        & powershell.exe -NoProfile -NonInteractive -File "$PSScriptRoot\Prepare-Toolchain.ps1" `
            -ToolRoot $ToolRoot -Python $Python -InstallRust
        if ($LASTEXITCODE -ne 0) { throw 'Full deployment-cache miss preparation failed.' }
        Save-DeploymentTiming 'full-fallback'
    }
    $qt = Join-Path $ToolRoot $spec.qtDirectory
    foreach ($archive in $spec.qtDownloads) {
        $file = "$($archive.module)-Windows-Windows_11_24H2-MSVC2022-Windows-Windows_11_24H2-X86_64.7z"
        Assert-CaelestiaDownload (Join-Path $ToolRoot "downloads\qt\$file") $archive.sha256
    }
    Save-DeploymentTiming 'qt-archives'
    foreach ($file in @('bin\qtpaths.exe', 'bin\windeployqt.exe', 'bin\Qt6Quick.dll', 'bin\Qt6Svg.dll',
        'bin\Qt6ShaderTools.dll', 'plugins\imageformats\qjpeg.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $qt $file) -PathType Leaf)) {
            throw 'Incomplete deployment Qt prerequisite; refuse the restored cache.'
        }
    }
    Save-DeploymentTiming 'qt-required-files'
    $null = Get-CaelestiaQtSupplier -QtPrefix $qt
    Save-DeploymentTiming 'qt-supplier-metadata'
    # Even CLI Qt tools inherit offscreen on the shared development machine.
    $env:QT_QPA_PLATFORM = 'offscreen'
    $actual = (& "$qt\bin\qtpaths.exe" --qt-version) -join ''
    if ($LASTEXITCODE -ne 0 -or $actual.Trim() -cne $spec.qtVersion) {
        throw 'Deployment Qt version differs from the pinned contract.'
    }
    Save-DeploymentTiming 'qt-version'
    # This is deployment readiness, not a replacement compiler receipt.
    # Candidate eligibility and assembly still verify the full measured build
    # toolchain and exact VS runtime supplier before accepting native bytes.
    Write-Host 'Pinned deployment Qt archives, files, supplier metadata and version verified.'
} finally {
    $timings.Add([ordered]@{ phase = 'total'; durationSeconds = [Math]::Round($total.Elapsed.TotalSeconds, 6) })
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TimingPath) | Out-Null
    [ordered]@{ schemaVersion = 1; profile = 'deployment'; phases = @($timings.ToArray()) } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $TimingPath -Encoding UTF8
}
