[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseRoot,
    [Parameter(Mandatory)][string]$Control,
    [Parameter(Mandatory)][ValidateSet('Install', 'SourceInstall', 'Rollback', 'Queue', 'TrackedRollback', 'Watch', 'Uninstall')][string]$Operation,
    [string]$OperationId,
    [string]$Pause = '',
    [switch]$Purge,
    [switch]$ThrowAtBoundary,
    [switch]$KeepAlive,
    [switch]$AliasPrefix,
    # Route the real cleanup to disposable integration files and HKCU test
    # roots, then inject the named external failure. Never the live desktop.
    [switch]$RealIntegration,
    [ValidateSet('', 'locked-shortcut', 'registry-denial')][string]$IntegrationFailure = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$env:CAELESTIA_FIXTURE_CASE = $CaseRoot
$env:CAELESTIA_FIXTURE_OPERATION = $Operation
$env:CAELESTIA_FIXTURE_CONTROL = $Control
$env:CAELESTIA_FIXTURE_PREFIX = Join-Path $CaseRoot 'prefix'
$env:CAELESTIA_FIXTURE_PROFILE = Join-Path $CaseRoot 'profile'
$env:CAELESTIA_FIXTURE_PAUSE = $Pause
$env:CAELESTIA_FIXTURE_THROW = [string][int][bool]$ThrowAtBoundary
$env:CAELESTIA_FIXTURE_INTEGRATION_MODE = if ($RealIntegration) { 'real' } else { 'simulated' }
$env:CAELESTIA_FIXTURE_INTEGRATION_FAILURE = $IntegrationFailure
$env:CAELESTIA_FIXTURE_REGISTRY = 'HKCU:\Software\CaelestiaWindowsTests\' + (Get-CaelestiaInstallLockKey $CaseRoot).Substring(0, 16)
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
        Queue { & (Join-Path $CaseRoot 'scripts\Manage-Caelestia.ps1') -Prefix $prefixArgument -Command Rollback -ExpectedCurrent v2 -PhaseTimeoutSeconds 5 }
        TrackedRollback { & (Join-Path $CaseRoot 'scripts\Manage-Caelestia.ps1') -Prefix $prefixArgument -Command Rollback -Wait -TaskName ('Caelestia-Maintenance-' + $OperationId) -ExpectedCurrent v2 }
        Watch { & (Join-Path $CaseRoot 'scripts\Manage-Caelestia.ps1') -Prefix $prefixArgument -Command Watch -OperationId $OperationId -TaskName ('Caelestia-MaintenanceWatch-' + $OperationId) }
        SourceInstall {
            & (Join-Path $CaseRoot 'scripts\Install-Caelestia.ps1') -Prefix $prefixArgument -ProfileRoot $env:CAELESTIA_FIXTURE_PROFILE `
                -BuildRoot (Join-Path $CaseRoot 'source-build') -QtPrefix (Join-Path $CaseRoot 'source-qt') `
                -VCRuntimeRoot (Join-Path $CaseRoot 'source-crt') -SourceRoot (Join-Path $CaseRoot 'source-repo') -NoIntegration -SkipSchemeRuntime
        }
        Uninstall { & (Join-Path $CaseRoot 'scripts\Uninstall-Caelestia.ps1') -Prefix $prefixArgument -Purge:$Purge -NoDialogs }
    }
} catch {
    $message = Protect-CaelestiaText $_.Exception.Message
    $status = if ($_.Exception.Message -match 'already in progress|Another installation is in progress') { 'Busy' }
        elseif ($_.Exception.Message -eq 'Injected external boundary exception.') { 'Injected' }
        else { 'Error' }
}
# Keep the PowerShell process (and any accidentally unreleased mutex) alive
# while the controller runs a different REAL operation to prove finally release.
$queuedId = ''
if ($Operation -eq 'Queue' -and $status -eq 'Success') { $queuedId = ($output | ConvertFrom-Json).operationId }
# The controller uses existence as its readiness signal. Publish only after
# serialization and close, not while Set-Content still holds the final file.
Write-CaelestiaJsonAtomic (Join-Path $Control 'result.json') @{
    status = $status; message = $message; operationId = $queuedId
}
if ($KeepAlive) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists((Join-Path $Control 'finish'))) {
        if ($clock.Elapsed.TotalSeconds -gt 45) { exit 2 }
        Start-Sleep -Milliseconds 20
    }
}
if ($status -in @('Success', 'Busy', 'Injected')) { exit 0 }
exit 1
