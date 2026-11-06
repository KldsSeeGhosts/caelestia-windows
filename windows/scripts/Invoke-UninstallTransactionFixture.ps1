[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseRoot,
    [Parameter(Mandatory)][string]$Control,
    [Parameter(Mandatory)][ValidateSet('Install', 'Rollback', 'Uninstall')][string]$Operation,
    [string]$Pause = '',
    [switch]$Purge,
    [switch]$ThrowAtBoundary,
    [switch]$KeepAlive,
    [switch]$AliasPrefix
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$env:CAELESTIA_FIXTURE_CASE = $CaseRoot
$env:CAELESTIA_FIXTURE_CONTROL = $Control
$env:CAELESTIA_FIXTURE_PREFIX = Join-Path $CaseRoot 'prefix'
$env:CAELESTIA_FIXTURE_PROFILE = Join-Path $CaseRoot 'profile'
$env:CAELESTIA_FIXTURE_PAUSE = $Pause
$env:CAELESTIA_FIXTURE_THROW = [string][int][bool]$ThrowAtBoundary
$prefixArgument = $env:CAELESTIA_FIXTURE_PREFIX
if ($AliasPrefix) { $prefixArgument = $prefixArgument.ToUpperInvariant().Replace('\', '/') + '/./' }
$status = 'Success'
$message = ''
try {
    $output = switch ($Operation) {
        Install {
            & (Join-Path $CaseRoot 'bundle\Install-CaelestiaRelease.ps1') -BundleRoot (Join-Path $CaseRoot 'bundle') `
                -Prefix $prefixArgument -ProfileRoot $env:CAELESTIA_FIXTURE_PROFILE -NoIntegration
        }
        Rollback { & (Join-Path $CaseRoot 'scripts\Manage-Caelestia.ps1') -Prefix $prefixArgument -Command Rollback -Wait }
        Uninstall { & (Join-Path $CaseRoot 'scripts\Uninstall-Caelestia.ps1') -Prefix $prefixArgument -Purge:$Purge }
    }
} catch {
    $message = Protect-CaelestiaText $_.Exception.Message
    $status = if ($_.Exception.Message -match 'already in progress') { 'Busy' }
        elseif ($_.Exception.Message -eq 'Injected external boundary exception.') { 'Injected' }
        else { 'Error' }
}
# Keep the PowerShell process (and any accidentally unreleased mutex) alive
# while the controller runs a different REAL operation to prove finally release.
@{ status = $status; message = $message } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $Control 'result.json') -Encoding UTF8
if ($KeepAlive) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists((Join-Path $Control 'finish'))) {
        if ($clock.Elapsed.TotalSeconds -gt 45) { exit 2 }
        Start-Sleep -Milliseconds 20
    }
}
if ($status -in @('Success', 'Busy', 'Injected')) { exit 0 }
exit 1
