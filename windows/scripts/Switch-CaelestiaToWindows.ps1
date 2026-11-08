# Switch back to the native Windows desktop without a terminal.
#
# This is the script behind the Start-menu "Switch back to Windows" entry. It
# collects one user choice and hands the work to the stable-root
# Start-Caelestia.ps1 -Command Quit entry point, the same entry the shell uses.
# That entry owns Quit, supervisor recovery, desktop restoration, autostart
# removal and its failure report. This wrapper implements no second cleanup,
# restore or autostart path.
[CmdletBinding()]
param(
    # Installed root. Defaults to this script's directory, then the default prefix.
    [string]$Prefix,
    # Ask (default), Keep, or Disable. Ask shows one native Yes/No dialog and
    # defaults to turning autostart off.
    [ValidateSet('Ask', 'Keep', 'Disable')][string]$Autostart = 'Ask',
    # Automated callers: keep autostart and report failures instead of a dialog.
    [switch]$NoDialogs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
try {
    if (-not $Prefix) {
        $Prefix = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json')) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows' }
    }
    $Prefix = Resolve-CaelestiaDirectory $Prefix
    # The stable root owns this installation's Run entry. Query it only to
    # decide whether the optional question is meaningful.
    $hasAutostart = $false
    try { $hasAutostart = Test-CaelestiaAutostart $Prefix } catch { $hasAutostart = $false }
    $disable = $Autostart -eq 'Disable'
    if ($Autostart -eq 'Ask') {
        if ($hasAutostart -and -not $NoDialogs) {
            $disable = Read-CaelestiaConfirmation -Title 'Switch back to Windows' `
                -Text (Get-CaelestiaAutostartPromptText) -DefaultYes
        }
    }

    # One stable-root entry point. It consumes the autostart choice before the
    # version route, performs the existing IPC/supervisor Quit, restores the
    # desktop, and shows its own failure report if the Run entry cannot be
    # removed.
    $arguments = @{ Prefix = $Prefix; Command = 'Quit' }
    if ($disable) { $arguments.DisableAutostart = $true }
    & (Join-Path $Prefix 'Start-Caelestia.ps1') @arguments | Out-Null

    Write-Output 'Caelestia is closed and the Windows taskbar and desktop are back.'
    Write-Output ('Start Caelestia again from the Start menu, or run: powershell -NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $Prefix 'Start-Caelestia.ps1') + '"')
} catch {
    # The stable entry already reported a denied autostart removal with the
    # topmost handoff dialog. Report only errors it did not present.
    if (-not $NoDialogs -and $_.Exception.Message -notmatch 'autostart entry') {
        Show-CaelestiaHandoffDialog ("Caelestia could not fully switch back to Windows.`r`n`r`n" + $_.Exception.Message)
    }
    throw
}
