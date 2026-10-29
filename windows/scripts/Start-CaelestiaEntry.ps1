# Installed at the stable root as Start-Caelestia.ps1.
[CmdletBinding()]
param(
    [string]$Prefix = $PSScriptRoot,
    [ValidateSet('Start', 'State', 'Quit', 'Restart')][string]$Command = 'Start',
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
$runtime = Resolve-CaelestiaRuntimePrefix $Prefix -Running:($Command -ne 'Start')
if ($runtime -eq $PSScriptRoot) { throw 'Installation migration is incomplete. Run the installer again.' }
$arguments = @{}
foreach ($key in $PSBoundParameters.Keys) { $arguments[$key] = $PSBoundParameters[$key] }
$arguments.Prefix = $runtime
& (Join-Path $runtime 'Start-Caelestia.ps1') @arguments
