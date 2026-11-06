[CmdletBinding()]
param(
    [string]$Prefix,
    [switch]$Purge
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
if (-not $Prefix) {
    $Prefix = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json')) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows' }
}
$Prefix = Resolve-CaelestiaDirectory $Prefix
# Use the installers' nonblocking prefix lock before reading any mutable
# installation/profile identity. Keep it through integration and purge cleanup.
$installLock = Enter-CaelestiaInstallLock $Prefix
try {
if (-not $installLock) { throw 'An installation, rollback or uninstall is already in progress.' }
$record = Read-CaelestiaInstall $Prefix
$profile = Resolve-CaelestiaDirectory $record.profile
if ($profile -eq $Prefix -or $Prefix.StartsWith($profile + '\', [StringComparison]::OrdinalIgnoreCase) -or $profile.StartsWith($Prefix + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installation and profile must be separate directories.'
}
$integration = Get-CaelestiaIntegration $Prefix
# Decide up front whether -Purge may delete the profile, so a refusal leaves
# the installation untouched.
if ($Purge -and (Test-Path -LiteralPath $profile)) {
    $owner = Read-CaelestiaProfileOwner $profile
    if (-not $owner -or $owner.prefix -ne $Prefix -or $owner.exclusive -ne $true -or
        ($record.installId -and $owner.installId -ne $record.installId)) {
        throw "Refusing -Purge: $profile is not marked as created exclusively for $Prefix. Remove it manually if it is yours."
    }
    Assert-CaelestiaNoReparsePoints $profile
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
    if ($actions.Count -ne 1 -or $actions[0].WorkingDirectory -ne $Prefix -or
        ([string]$actions[0].Arguments).IndexOf('-File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') + '"', [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        ([string]$actions[0].Arguments).IndexOf('-Prefix "' + $Prefix + '"', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    Stop-ScheduledTask -TaskPath '\' -TaskName $task.TaskName -ErrorAction Stop
    Unregister-ScheduledTask -TaskPath '\' -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
    $cancelledOperations += $taskOperation
}
$operationFile = Join-Path $profile 'state\update-operation.json'
if (Test-Path -LiteralPath $operationFile -PathType Leaf) {
    $null = Resolve-CaelestiaDirectory ([IO.Path]::GetDirectoryName($operationFile))
    $operation = Get-Content -LiteralPath $operationFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($operation.schema -eq 1 -and $operation.operationId -match '^[a-f0-9]{32}$' -and
        (-not $operation.prefix -or $operation.prefix -eq $Prefix) -and
        (-not $operation.installId -or $operation.installId -eq $record.installId)) {
        $ownsOperation = ($operation.prefix -eq $Prefix -and $operation.installId -eq $record.installId) -or
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
$tombstone = $Prefix + '.uninstall-' + [guid]::NewGuid().ToString('N')
try { [IO.Directory]::Move($Prefix, $tombstone) }
catch {
    throw "Cannot uninstall Caelestia because $Prefix is still in use (a file is open or locked). Close Caelestia and any programs using it, then retry. The installation was not changed."
}
# The installation is out of the way. Remove its per-user integration, then the
# renamed tree; a cleanup failure must not report a partially failed uninstall.
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Get-ItemProperty -LiteralPath $run -Name $integration.RunName -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -LiteralPath $run -Name $integration.RunName
}
if (Test-Path -LiteralPath $integration.Shortcut) { Remove-Item -LiteralPath $integration.Shortcut -Force }
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
} finally {
    Exit-CaelestiaInstallLock $installLock
}
