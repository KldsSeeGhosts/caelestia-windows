#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('development', 'promote', 'refresh-development', 'refresh-promotion')][string]$Mode,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [string]$CandidateDirectory,
    [string]$BuildVersion = $env:NEXUS_BUILD_VERSION,
    [string]$Channel = $env:NEXUS_CHANNEL,
    [string]$Alias = $env:NEXUS_ALIAS,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$shell = (Resolve-Path "$PSScriptRoot\..\..").Path
$arguments = @('-I', '-B', "$PSScriptRoot\nexus_publish.py", $Mode, '--shell', $shell, '--work', $WorkDirectory)
if ($Mode -eq 'development') {
    if (-not $CandidateDirectory) { throw 'Exact same-run candidate directory is required.' }
    $arguments += @('--candidate', $CandidateDirectory)
}
if ($Mode -eq 'promote') {
    . "$PSScriptRoot\..\scripts\Caelestia-SemVer.ps1"
    if (-not (Test-CaelestiaDevVersion $BuildVersion) -or $Channel -cnotin @('preview', 'stable') -or
        $Alias -cnotmatch '\A[0-9A-Za-z.-]+\z') { throw 'Invalid explicit promotion input.' }
    $arguments += @('--build', $BuildVersion, '--channel', $Channel, '--alias', $Alias)
}
try {
    & $Python @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Nexus publication refused; production state must not be assumed changed.' }
} finally { $env:NEXUS_SIGNING_KEY = $null }
