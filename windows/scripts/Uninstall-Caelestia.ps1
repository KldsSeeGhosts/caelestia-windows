[CmdletBinding()]
param(
    [string]$Prefix,
    [switch]$Purge,
    # Asked by the Settings > Apps uninstall command. One native dialog, and the
    # default (No) keeps settings, configuration and logs.
    [switch]$AskPurge,
    # Automated callers and fixtures: report failures by exception only.
    [switch]$NoDialogs
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
if (-not $Prefix) {
    $Prefix = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json')) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows' }
}
$Prefix = Resolve-CaelestiaDirectory $Prefix
$installLock = $null
try {
# Use the installers' nonblocking prefix lock before reading any mutable
# installation/profile identity. Keep it through integration and purge cleanup.
$installLock = Enter-CaelestiaInstallLock $Prefix
if (-not $installLock) { throw 'An installation, rollback or uninstall is already in progress.' }
$record = Read-CaelestiaInstall $Prefix
$profile = Resolve-CaelestiaDirectory $record.profile
if ($profile -eq $Prefix -or $Prefix.StartsWith($profile + '\', [StringComparison]::OrdinalIgnoreCase) -or $profile.StartsWith($Prefix + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installation and profile must be separate directories.'
}
# Resolve the prefix-derived per-user names before anything destructive. The
# same record is handed to the post-rename cleanup, so the entries removed are
# the ones this uninstall identified.
$integration = Get-CaelestiaIntegration $Prefix
# Decide up front whether -Purge may delete the profile, so a refusal leaves
# the installation untouched. The Apps & features entry only offers the choice
# when the profile is exclusively owned; otherwise it is kept silently.
$profileExists = Test-Path -LiteralPath $profile
$purgeAllowed = $false
if ($profileExists) {
    $owner = Read-CaelestiaProfileOwner $profile
    $purgeAllowed = $null -ne $owner -and (Test-CaelestiaSamePath $owner.prefix $Prefix) -and $owner.exclusive -eq $true -and
        (-not $record.installId -or $owner.installId -eq $record.installId)
}
if ($Purge -and $profileExists) {
    if (-not $purgeAllowed) {
        throw "Refusing -Purge: $profile is not marked as created exclusively for $Prefix. Remove it manually if it is yours."
    }
    Assert-CaelestiaNoReparsePoints $profile
}
if ($AskPurge -and -not $Purge -and $purgeAllowed) {
    if (Read-CaelestiaConfirmation -Title 'Uninstall Caelestia' -Text (Get-CaelestiaPurgePromptText $profile) -DefaultYes:$false) {
        $Purge = $true
        Assert-CaelestiaNoReparsePoints $profile
    }
}
# Only this prefix's executable may be stopped. Never kill other qs instances.
# Quit also stops a supervisor that is starting or in restart backoff (no
# qs.exe) and restores banners/desktop state before the journal can be purged.
# Cancel queued maintenance while holding the same lock as its setup/worker.
# Each task action must prove prefix ownership before it can be stopped or
# removed. Enumerate even without a journal: queue setup can be interrupted
# between registering its watchdog and writing 'queued'. Never leave actions
# pointing at scripts that the tombstone rename is about to remove.
$cancelledOperations = @()
foreach ($task in @(Get-ScheduledTask -TaskPath '\' -TaskName 'Caelestia-Maintenance*' -ErrorAction SilentlyContinue)) {
    if ($task.TaskName -notmatch '^Caelestia-Maintenance(?:Watch)?-([a-f0-9]{32})$') { continue }
    $taskOperation = $Matches[1]
    $actions = @($task.Actions)
    if ($actions.Count -ne 1 -or -not (Test-CaelestiaSamePath $actions[0].WorkingDirectory $Prefix) -or
        ([string]$actions[0].Arguments).IndexOf('-File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') + '"', [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        ([string]$actions[0].Arguments).IndexOf('-Prefix "' + $Prefix + '"', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    Stop-ScheduledTask -TaskPath '\' -TaskName $task.TaskName -ErrorAction Stop
    Unregister-ScheduledTask -TaskPath '\' -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
    $cancelledOperations += $taskOperation
}
$operationFile = Join-Path $profile 'state\update-operation.json'
if (Test-Path -LiteralPath $operationFile -PathType Leaf) {
    $null = Resolve-CaelestiaDirectory ([IO.Path]::GetDirectoryName($operationFile))
    # A corrupt optional reporting journal must not prevent uninstall. Task
    # cancellation above independently proves prefix ownership.
    $operation = $null
    try { $operation = Get-Content -LiteralPath $operationFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { }
    if ($operation.schema -eq 1 -and $operation.operationId -match '^[a-f0-9]{32}$' -and
        (-not $operation.prefix -or (Test-CaelestiaSamePath $operation.prefix $Prefix)) -and
        (-not $operation.installId -or $operation.installId -eq $record.installId)) {
        $ownsOperation = ((Test-CaelestiaSamePath $operation.prefix $Prefix) -and $operation.installId -eq $record.installId) -or
            $operation.operationId -in $cancelledOperations
        if ($ownsOperation -and $operation.phase -in @('queued', 'working')) {
            $operation.phase = 'failed'
            Write-CaelestiaJsonAtomic $operationFile $operation
        }
    }
}
$launcher = Join-Path $Prefix 'Start-Caelestia.ps1'
$processes = @(Get-CaelestiaProcesses $Prefix)
if (Test-Path -LiteralPath $launcher) {
    & $launcher -Prefix $Prefix -Command Quit | Out-Null
}
foreach ($process in $processes) {
    if (-not $process.WaitForExit(60000)) { throw 'Shell did not quit. Stop this installation before uninstalling.' }
}
Stop-CaelestiaHosts $Prefix
if (@(Get-CaelestiaSupervisors $profile).Count -or @(Get-CaelestiaProcesses $Prefix).Count) {
    throw 'Caelestia is still running. Stop this installation before uninstalling.'
}
# Re-resolve immediately before moving the tree. Windows refuses to rename a
# directory that still has open files, so a locked installation aborts here
# with nothing changed and stays resolvable, instead of becoming a half-deleted
# prefix that can no longer be found or uninstalled. Only a marked installation
# and its recorded, separate profile can be removed. The prefix includes all
# packaged notices under licenses/; runtime venv notices stay with the profile
# unless -Purge was explicitly requested.
$Prefix = Resolve-CaelestiaDirectory $Prefix
Assert-CaelestiaNoReparsePoints $Prefix
# Snapshot the per-user entries before anything destructive. If cleanup fails
# after the rename, both this snapshot and the prefix are restored so the
# Settings entry stays resolvable and a retry is possible. A snapshot failure
# aborts here, with the installation untouched.
$integrationSnapshot = Get-CaelestiaUserIntegrationSnapshot $Prefix $integration
$tombstone = $Prefix + '.uninstall-' + [guid]::NewGuid().ToString('N')
try { [IO.Directory]::Move($Prefix, $tombstone) }
catch {
    Remove-CaelestiaUserIntegrationSnapshot $integrationSnapshot
    throw "Cannot uninstall Caelestia because $Prefix is still in use (a file is open or locked). Close Caelestia and any programs using it, then retry. The installation was not changed."
}
# The installation is out of the way. Remove its per-user integration (the
# Start-menu launch and switch-back entries, the optional desktop entry, the
# autostart Run value and the Apps & features key), then the renamed tree. If
# cleanup throws, restore the prefix first and then exactly the entries that
# were there, so the user can retry instead of being left with an Apps &
# features command that names a missing directory.
try {
    Remove-CaelestiaUserIntegration $Prefix $integration
} catch {
    $cleanupError = $_.Exception.Message
    $restoreFailures = @()
    if (Test-Path -LiteralPath $tombstone) {
        try { [IO.Directory]::Move($tombstone, $Prefix) }
        catch { $restoreFailures += "the installation files could not be moved back from $tombstone ($($_.Exception.Message))" }
    } else {
        $restoreFailures += "the moved installation directory $tombstone is missing"
    }
    try { $restoreFailures += @(Restore-CaelestiaUserIntegrationSnapshot $integrationSnapshot) }
    catch { $restoreFailures += "the Start-menu, autostart and Apps & features entries could not be restored ($($_.Exception.Message))" }
    if ($restoreFailures.Count) {
        throw ("Uninstall failed after moving the installation aside: $cleanupError. " +
            "Recovery was incomplete: " + ($restoreFailures -join '; ') + '. ' +
            "The installation files are at $tombstone; do not delete them. Reinstall Caelestia over this prefix, or collect a support bundle, before retrying.")
    }
    Remove-CaelestiaUserIntegrationSnapshot $integrationSnapshot
    throw ("Uninstall could not remove this installation's Start-menu, autostart or Apps & features entries: $cleanupError. " +
        'The installation and its entries were restored, so retrying is safe. Close any program that is using Caelestia, then retry from Settings > Apps > Installed apps.')
}
Remove-CaelestiaUserIntegrationSnapshot $integrationSnapshot
try {
    $safeTombstone = Resolve-CaelestiaDirectory $tombstone
    Assert-CaelestiaNoReparsePoints $safeTombstone
    Remove-Item -LiteralPath $safeTombstone -Recurse -Force
} catch {
    Write-Warning "Caelestia was uninstalled, but its files could not be fully deleted: $tombstone. Remove that directory manually. $($_.Exception.Message)"
}
if ($Purge -and (Test-Path -LiteralPath $profile)) {
    $profile = Resolve-CaelestiaDirectory $profile
    Assert-CaelestiaNoReparsePoints $profile
    Remove-Item -LiteralPath $profile -Recurse -Force
}
Write-Output "Uninstalled Caelestia: $Prefix"
if (-not $Purge) { Write-Output "Kept profile: $profile" }
# This mirrors the documented retention rule in Caelestia-Update.ps1: the state
# is deliberately outside the installation and profile so a rollback or a purge
# cannot erase update revocation/freshness highwater.
Write-Output 'Kept update trust data: %LOCALAPPDATA%\caelestia-update-trust (newest accepted signed update metadata)'
} catch {
    # The launch is hidden, so an exception alone is invisible to the user.
    # Show one actionable dialog unless a scripted caller opted out.
    if (-not $NoDialogs) {
        $retry = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Prefix + '\Uninstall-Caelestia.ps1" -Prefix "' + $Prefix + '"'
        $text = "Caelestia was not uninstalled.`r`n`r`n" + $_.Exception.Message
        if ($_.Exception.Message -notmatch 'installation files are at') {
            $text += "`r`n`r`nRetry from Settings > Apps > Installed apps, or run:`r`n" + $retry
        }
        Show-CaelestiaError -Title 'Uninstall Caelestia' -Text $text
    }
    throw
} finally {
    if ($installLock) { Exit-CaelestiaInstallLock $installLock }
}

