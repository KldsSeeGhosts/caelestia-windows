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
    if ($BuildVersion -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z' -or
        $Channel -cnotin @('preview', 'stable') -or $Alias -cne $BuildVersion) { throw 'Invalid explicit promotion input.' }
    $arguments += @('--build', $BuildVersion, '--channel', $Channel, '--alias', $Alias)
}
try {
    & $Python @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Nexus publication refused; production state must not be assumed changed.' }
} finally { $env:NEXUS_SIGNING_KEY = $null }
