# Installed at the stable root as Start-Caelestia.ps1.
[CmdletBinding()]
param(
    [string]$Prefix,
    [ValidateSet('Start', 'State', 'Quit', 'Restart', 'Settings', 'NotifyTest', 'AutostartStatus')][string]$Command = 'Start',
    # Quit only. The stable root owns this installation's Run entry, so remove
    # it here before routing to a version payload.
    [switch]$DisableAutostart,
    [switch]$Smoke,
    [ValidateRange(0, 15)][int]$ScreenIndex,
    [ValidateSet('Disabled', 'Observe', 'Interactive')][string]$TilingMode = 'Disabled',
    [string]$TilingIncluded = '',
    [string]$TilingExcluded = '',
    [switch]$SkipSchemeRuntime,
    [switch]$PreparedSchemeRuntime,
    [switch]$Wait
)
if ($DisableAutostart -and $Command -ne 'Quit') { throw '-DisableAutostart requires -Command Quit.' }
# Windows PowerShell -File can bind parameter defaults before $PSScriptRoot
# is populated. Resolve the default in the script body for sign-in launches.
if (-not $Prefix) { $Prefix = $PSScriptRoot }
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$Prefix = Resolve-CaelestiaDirectory $Prefix
# Answer and remove the stable root's Run entry before the version route can
# replace the launcher context. The runtime payload must never compute another
# prefix's hashed name.
if ($Command -eq 'AutostartStatus') {
    [ordered]@{ schema = 1; enabled = (Test-CaelestiaAutostart $Prefix) } |
        ConvertTo-Json -Compress
    return
}
$autostartFailure = ''
if ($Command -eq 'Quit' -and $DisableAutostart) {
    $autostartFailure = Disable-CaelestiaAutostartForQuit $Prefix
}
# NotifyTest uses the selected launcher, even if an older payload is running:
# it submits to Windows independently of the shell's IPC or runtime version.
$runtime = Resolve-CaelestiaRuntimePrefix $Prefix -Running:($Command -notin @('Start', 'NotifyTest'))
if (Test-CaelestiaSamePath $runtime $PSScriptRoot) { throw 'Installation migration is incomplete. Run the installer again.' }
if ($Command -eq 'Settings') {
    if ($Smoke) { throw '-Smoke requires -Command Start.' }
    $null = Invoke-CaelestiaIpc $runtime settings
    return
}
$arguments = @{}
foreach ($key in $PSBoundParameters.Keys) {
    # The stable root already consumed this switch.
    if ($key -eq 'DisableAutostart') { continue }
    $arguments[$key] = $PSBoundParameters[$key]
}
# A retained pre-versioning payload can neither consume the prepared record
# nor be trusted to skip provisioning on its own. During activation, disable
# its provisioner instead of letting pip run inside the readiness budget. A
# normal start (no -PreparedSchemeRuntime) keeps its old behaviour.
if ($arguments.ContainsKey('PreparedSchemeRuntime')) {
    $prepared = $false
    $skip = $false
    try {
        $target = [IO.File]::ReadAllText((Join-Path $runtime 'Start-Caelestia.ps1'))
        $prepared = $target -match '\[switch\]\$PreparedSchemeRuntime\b'
        $skip = $target -match '\[switch\]\$SkipSchemeRuntime\b'
    } catch { }
    if (-not $prepared) {
        $requested = [bool]$arguments['PreparedSchemeRuntime']
        $arguments.Remove('PreparedSchemeRuntime')
        # Only a bound $true request translates to the legacy skip switch. An
        # explicit -PreparedSchemeRuntime:$false must not become an unintended
        # -SkipSchemeRuntime on the old payload, and SwitchParameter::Present
        # keeps the bound shape the payload's IsPresent check expects.
        if ($requested -and $skip) {
            $arguments['SkipSchemeRuntime'] = [System.Management.Automation.SwitchParameter]::Present
        }
    }
}
# Invoke-CaelestiaPayloadCommand always rebinds Prefix to the resolved runtime,
# so whatever root spelling the caller bound never reaches the payload.
$payloadError = $null
try {
    Invoke-CaelestiaPayloadCommand $runtime $arguments
} catch {
    $payloadError = $_
} finally {
    # The runtime Quit has finished and the supervisor has restored the desktop.
    # The shell has exited, so this launcher owns the visible report; notify even
    # though the throw below still fails the call.
    if ($autostartFailure) { Show-CaelestiaHandoffDialog $autostartFailure }
}
if ($autostartFailure) { throw $autostartFailure }
if ($payloadError) {
    # A cross-host payload failure recorded its real exit code before throwing;
    # surface it exactly instead of letting the exception collapse to 1.
    $code = $global:CaelestiaLastPayloadExitCode
    if ($code -and $code -ne 0) { exit $code }
    throw $payloadError
}
