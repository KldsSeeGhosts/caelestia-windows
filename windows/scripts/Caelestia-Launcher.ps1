# Caelestia for Windows launch and maintenance entrypoint.
#
# The Start-menu launch and switch-back entries, the optional desktop entry, the
# HKCU Run value and the Apps & features uninstall command all run this file
# through:
#
#   conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass
#       -File Caelestia-Launcher.ps1 -Action <action>
#
# conhost --headless gives Windows PowerShell a console without a window, so
# nothing flashes; -WindowStyle Hidden would be redundant. Windows Script Host
# and VBScript are not used. The per-invocation -ExecutionPolicy Bypass changes
# no machine or user policy.
#
# The launcher is data for the signed inbox conhost and PowerShell components.
# It derives its installation prefix from its own path, starts only scripts that
# live next to it, requires install.json, and refuses a -Prefix that names
# another directory, so a copied shortcut cannot run someone else's install.
# Leaving the prefix out of the command keeps the HKCU Run value under Windows'
# 260-character limit for a default installation. Every entry above is generated
# by Get-CaelestiaLaunchCommand in Caelestia-InstallCommon.ps1, so a signed
# launcher EXE (#20) can replace this file and that helper only.
#
# conhost.exe --headless returns 0 instead of its child's exit code
# (microsoft/terminal#17178), so a caller that needs the result can pass
# -OutcomeFile; normal Start-menu and Settings callers do not.
[CmdletBinding()]
param(
    [string]$Action,
    [string]$Prefix,
    [string]$OutcomeFile,
    # Automated callers: report failures through the exit code and outcome file
    # instead of a blocking native dialog.
    [switch]$NoDialogs
)

$ErrorActionPreference = 'Stop'

# The launcher's own path and a caller-supplied -Prefix can be spelled long or
# 8.3-short. Compare one long form so a short TEMP or a short shortcut path
# still matches the installation it names. This stays local because the
# launcher validates its prefix before loading any code from it.
function Get-NormalizedPath([string]$Path) {
    if (-not $Path) { return '' }
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $Path = '\\' + $Path.Substring(8) }
    elseif ($Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or $Path.StartsWith('\\.\', [StringComparison]::Ordinal)) { $Path = $Path.Substring(4) }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    try {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.FullName) {
            $full = $item.FullName
            if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char[]]@('\', '/')) }
        }
    } catch { }
    return $full
}

function Write-LauncherOutcome([int]$Code, [string]$Message) {
    if (-not $OutcomeFile) { return }
    try {
        $json = [ordered]@{
            schema = 1
            action = $Action
            prefix = $Prefix
            exitCode = $Code
            message = $Message
            recordedAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($OutcomeFile, $json, [Text.UTF8Encoding]::new($false))
    } catch { }
}

# A native error dialog so a hidden launch still reports a failure the user can
# act on. This uses only inbox Windows Forms; it does not load code from the
# prefix before the prefix has been validated.
function Show-LauncherError([string]$Text) {
    if ($NoDialogs) { return }
    if (-not [Environment]::UserInteractive) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($Text, 'Caelestia for Windows',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
}

function Exit-Launcher([int]$Code, [string]$Message) {
    Write-LauncherOutcome $Code $Message
    if ($Code -ne 0 -and $Message) { Show-LauncherError $Message }
    exit $Code
}

try {
    # The prefix is the directory this script was started from. Deriving it from
    # the script path in the body, not from a param() default, keeps the
    # generated command short enough for a Run value. An explicit -Prefix is
    # still accepted, but it must name the same directory.
    $launcherPath = $PSCommandPath
    if (-not $launcherPath) { $launcherPath = $MyInvocation.MyCommand.Path }
    if (-not $launcherPath) { $launcherPath = (Join-Path $PSScriptRoot 'Caelestia-Launcher.ps1') }
    $installRoot = Get-NormalizedPath (Split-Path -Parent $launcherPath)
    if ($Prefix) {
        $prefixPath = Get-NormalizedPath $Prefix
        # A copied shortcut that names a different directory is refused instead
        # of running another prefix's scripts.
        if (-not [string]::Equals($installRoot, $prefixPath, [StringComparison]::OrdinalIgnoreCase)) {
            Exit-Launcher 3 'This shortcut does not belong to the Caelestia installation it names. Start Caelestia from the Start menu entry created by the installer.'
        }
    }
    $Prefix = $installRoot
    if (-not $Action) { Exit-Launcher 2 'The Caelestia launch action is missing.' }
} catch {
    Exit-Launcher 2 'The Caelestia launch arguments are invalid.'
}
if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'install.json') -PathType Leaf)) {
    Exit-Launcher 4 'This Caelestia installation is incomplete: install.json is missing. Reinstall Caelestia from its release bundle.'
}

$target = ''
$targetArguments = @{}
switch ($Action.ToLowerInvariant()) {
    'start' {
        $target = 'Start-Caelestia.ps1'
        $targetArguments = @{ Prefix = $installRoot }
    }
    'switch-back' {
        $target = 'Switch-CaelestiaToWindows.ps1'
        $targetArguments = @{ Prefix = $installRoot }
    }
    'uninstall' {
        $target = 'Uninstall-Caelestia.ps1'
        $targetArguments = @{ Prefix = $installRoot; AskPurge = $true }
    }
    'uninstall-quiet' {
        $target = 'Uninstall-Caelestia.ps1'
        $targetArguments = @{ Prefix = $installRoot }
    }
    default {
        Exit-Launcher 2 'The Caelestia launch action is not recognized.'
    }
}
$targetPath = Join-Path $installRoot $target
if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    Exit-Launcher 5 "This Caelestia installation is incomplete: $target is missing. Reinstall Caelestia from its release bundle."
}

$code = 0
$failure = ''
try {
    # A fresh invocation must not inherit a stale native exit code from the
    # launcher's own checks. Target scripts that call `exit N` set this value.
    $LASTEXITCODE = 0
    & $targetPath @targetArguments
    if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
} catch {
    $failure = $_.Exception.Message
    $code = 1
}
# Switch back and uninstall own their native error dialog; do not show a second
# one. A failed Start has no other visible channel, so report it here.
if ($code -ne 0 -and $Action -ieq 'start') {
    $message = if ($failure) { "Caelestia could not start.`r`n`r`n$failure" }
        else { 'Caelestia could not start. See the profile logs for details.' }
    Show-LauncherError $message
}
Write-LauncherOutcome $code $failure
exit $code
