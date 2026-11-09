#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ShellRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$ToolRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
# Experimental duplicate execution only. New-NexusCandidate remains authoritative.
# Keep these four gates and their budgets identical to that entrypoint.
. "$PSScriptRoot\..\scripts\Caelestia-Toolchain.ps1"
Initialize-CaelestiaToolchainModules
. "$PSScriptRoot\..\scripts\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\..\scripts\Caelestia-Update.ps1"
$scripts = Join-Path $ShellRoot 'windows\scripts'
$privateLogs = Join-Path $OutputDirectory 'private'
$assets = Join-Path $OutputDirectory 'sources'
$spec = Get-Content "$ShellRoot\windows\toolchain.json" -Raw | ConvertFrom-Json
$qt = Join-Path $ToolRoot $spec.qtDirectory
$env:PYTHONDONTWRITEBYTECODE = '1'
$ps = Get-WindowsPowerShellPath
function Invoke-ShadowGate([string]$Name, [string]$Script, [string[]]$Arguments, [int]$TimeoutSeconds) {
    & $Python -I -B "$PSScriptRoot\nexus_process.py" --name $Name --log "$privateLogs\$Name.log" `
        --timeout $TimeoutSeconds -- $ps -NoProfile -NonInteractive -File $Script @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Shadow assembly gate failed: $Name" }
}
$assembly = Join-Path $OutputDirectory 'assembly'
Invoke-ShadowGate 'assembly' "$scripts\New-CaelestiaRelease.ps1" @(
    '-BuildRoot', $BuildRoot, '-ReleaseId', $ReleaseId, '-OutputDirectory', $assembly,
    '-SupplementalNoticesRoot', (Join-Path $assets 'notices'), '-QtPrefix', $qt) 900
$rootName = "caelestia-windows-$ReleaseId-windows-x64"
$bundle = Join-Path $assembly $rootName
$manifestHash = (Get-FileHash "$bundle\release.json").Hash.ToLowerInvariant()
$inventoryHash = (Get-FileHash "$assets\component-inventory.json").Hash.ToLowerInvariant()
Invoke-ShadowGate 'coverage' "$scripts\Prepare-CaelestiaSourceAssets.ps1" @(
    '-AssetsRoot', $assets, '-BundleRoot', $bundle, '-ExpectedInventorySha256', $inventoryHash,
    '-ExpectedManifestSha256', $manifestHash, '-CoverageOutputDirectory', (Join-Path $OutputDirectory 'coverage')) 300
Invoke-ShadowGate 'license-lifecycle' "$scripts\Test-InstallLicenses.ps1" @(
    '-BuildRoot', $BuildRoot, '-QtPrefix', $qt, '-NoIntegration') 600
$zip = Join-Path $assembly ($rootName + '.zip')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entries = $archive.Entries.Count
    $unpacked = [long](($archive.Entries | Measure-Object Length -Sum).Sum)
} finally { $archive.Dispose() }
$extracted = Expand-CaelestiaUpdate $zip (Join-Path $OutputDirectory 'verify-extracted') $rootName $entries $unpacked
Invoke-ShadowGate 'verify-original-zip' "$scripts\Install-CaelestiaRelease.ps1" @(
    '-BundleRoot', $extracted, '-VerifyOnly', '-ExpectedManifestSha256', $manifestHash) 300
