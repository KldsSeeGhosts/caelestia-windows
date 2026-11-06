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
