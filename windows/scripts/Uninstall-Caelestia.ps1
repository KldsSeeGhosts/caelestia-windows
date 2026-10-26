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
$record = Read-CaelestiaInstall $Prefix
$profile = Resolve-CaelestiaDirectory $record.profile
if ($profile -eq $Prefix -or $Prefix.StartsWith($profile + '\', [StringComparison]::OrdinalIgnoreCase) -or $profile.StartsWith($Prefix + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installation and profile must be separate directories.'
}
$integration = Get-CaelestiaIntegration $Prefix
# Only this prefix's executable may be stopped. Never kill other qs instances.
$processes = @(Get-CaelestiaProcesses $Prefix)
if ($processes.Count) {
    & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit
    foreach ($process in $processes) {
        if (-not $process.WaitForExit(10000)) { throw 'Shell did not quit. Stop this installation before uninstalling.' }
    }
}
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Get-ItemProperty -LiteralPath $run -Name $integration.RunName -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -LiteralPath $run -Name $integration.RunName
}
if (Test-Path -LiteralPath $integration.Shortcut) { Remove-Item -LiteralPath $integration.Shortcut -Force }
# Re-resolve immediately before recursive removal. Only a marked installation
# and its recorded, separate profile can be removed.
$Prefix = Resolve-CaelestiaDirectory $Prefix
Remove-Item -LiteralPath $Prefix -Recurse -Force
if ($Purge -and (Test-Path -LiteralPath $profile)) {
    $profile = Resolve-CaelestiaDirectory $profile
    Remove-Item -LiteralPath $profile -Recurse -Force
}
Write-Output "Uninstalled Caelestia: $Prefix"
if (-not $Purge) { Write-Output "Kept profile: $profile" }
