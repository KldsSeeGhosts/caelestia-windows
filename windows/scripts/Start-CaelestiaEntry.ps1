# Installed at the stable root as Start-Caelestia.ps1.
[CmdletBinding()]
param(
    [string]$Prefix,
    [ValidateSet('Start', 'State', 'Quit', 'Restart', 'Settings', 'NotifyTest')][string]$Command = 'Start',
    [switch]$Smoke,
    [ValidateRange(0, 15)][int]$ScreenIndex,
    [ValidateSet('Disabled', 'Observe', 'Interactive')][string]$TilingMode = 'Disabled',
    [string]$TilingIncluded = '',
    [string]$TilingExcluded = '',
    [switch]$SkipSchemeRuntime,
    [switch]$PreparedSchemeRuntime,
    [switch]$Wait
)
# Windows PowerShell -File can bind parameter defaults before $PSScriptRoot
# is populated. Resolve the default in the script body for sign-in launches.
if (-not $Prefix) { $Prefix = $PSScriptRoot }
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
# A retained pre-versioning payload predates -PreparedSchemeRuntime. The
# installer already prepared its profile runtime, so its cached check is fast;
# drop the switch instead of failing its parameter binding.
if ($arguments.ContainsKey('PreparedSchemeRuntime')) {
    try {
        $target = [IO.File]::ReadAllText((Join-Path $runtime 'Start-Caelestia.ps1'))
        if ($target -notmatch '\[switch\]\$PreparedSchemeRuntime\b') {
            $arguments.Remove('PreparedSchemeRuntime')
        }
    } catch {
        $arguments.Remove('PreparedSchemeRuntime')
    }
}
$arguments.Prefix = $runtime
& (Join-Path $runtime 'Start-Caelestia.ps1') @arguments
