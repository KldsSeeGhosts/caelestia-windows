# Installed at the stable root as Start-Caelestia.ps1.
[CmdletBinding()]
param(
    [string]$Prefix = $PSScriptRoot,
    [ValidateSet('Start', 'State', 'Quit', 'Restart', 'Settings', 'NotifyTest')][string]$Command = 'Start',
    [switch]$Smoke,
    [ValidateRange(0, 15)][int]$ScreenIndex,
    [ValidateSet('Disabled', 'Observe', 'Interactive')][string]$TilingMode = 'Disabled',
    [string]$TilingIncluded = '',
    [string]$TilingExcluded = '',
    [switch]$SkipSchemeRuntime,
    [switch]$Wait
)
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$Prefix = Resolve-CaelestiaDirectory $Prefix
# NotifyTest uses the selected launcher, even if an older payload is running:
# it submits to Windows independently of the shell's IPC or runtime version.
$runtime = Resolve-CaelestiaRuntimePrefix $Prefix -Running:($Command -notin @('Start', 'NotifyTest'))
if ($runtime -eq $PSScriptRoot) { throw 'Installation migration is incomplete. Run the installer again.' }
if ($Command -eq 'Settings') {
    if ($Smoke) { throw '-Smoke requires -Command Start.' }
    $null = Invoke-CaelestiaIpc $runtime settings
    return
}
$arguments = @{}
foreach ($key in $PSBoundParameters.Keys) { $arguments[$key] = $PSBoundParameters[$key] }
$arguments.Prefix = $runtime
& (Join-Path $runtime 'Start-Caelestia.ps1') @arguments
