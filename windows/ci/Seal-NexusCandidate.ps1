#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ShellRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$PairResults,
    [Parameter(Mandatory)][string]$TrustedRoot,
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
if ($env:GH_TOKEN -or $env:NEXUS_SIGNING_KEY) { throw 'Sealing must run without publication credentials.' }
. "$PSScriptRoot\..\scripts\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\..\scripts\Caelestia-Update.ps1"
& $Python -I -B "$PSScriptRoot\nexus_assembly.py" seal --shell $ShellRoot --build $BuildRoot `
    --results $PairResults --validator "$TrustedRoot\.github\scripts\candidate_contract.py" --directory $CandidateDirectory
if ($LASTEXITCODE -ne 0) { throw 'Exact-tested candidate sealing refused.' }
$doc = Read-CaelestiaStrictJsonFile "$CandidateDirectory\candidate.json" 1048576
$trust = Read-CaelestiaStrictJsonFile "$ShellRoot\windows\release\update-trust.json"
Assert-CaelestiaReleaseMetadata $doc.release $trust 'development'
Write-Output 'NEXUS_SEAL_PASS exact main evidence and native/asset hashes; signed format unchanged.'
