#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Nexus-OwnerCommon.ps1"
$trust = Read-CaelestiaStrictJsonFile "$PSScriptRoot\..\release\update-trust.json"
$result = Get-NexusBootstrapRelease $trust ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory))
Write-Output "Bundle: $($result.Bundle)"
Write-Output "Authenticated manifestSha256: $($result.Release.manifestSha256)"
Write-Output "Build version: $($result.Release.buildVersion)"
Write-Output "Source revision: $($result.Release.sourceRevision)"
Write-Output 'Extract the bundle into the output directory, then run:'
Write-Output $result.InstallCommand
