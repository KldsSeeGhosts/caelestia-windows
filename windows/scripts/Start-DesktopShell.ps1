[CmdletBinding()]
param(
    [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
    [Parameter(Mandatory)][string]$StateDirectory,
    [string]$ConfigPath,
    # Set only when this child directly changes work areas outside AppBar.
    [switch]$RestoreWorkAreas,
    [string]$StdoutPath,
    [string]$StderrPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
if (Test-Path -LiteralPath $StateDirectory) { throw 'Use a fresh, private state directory for each supervisor run.' }
New-Item -ItemType Directory -Path $StateDirectory | Out-Null
$childEnvironment = @{}
# Retain only the caller's process environment, never persist the full inherited
# environment (which may contain credentials). Launch inherits everything else.
foreach ($key in $StartInfo.EnvironmentVariables.Keys) {
    if ($key -match '^(CAELESTIA_|QS_|QT_|QML)' -or $key -eq 'PATH') {
        $childEnvironment[$key] = $StartInfo.EnvironmentVariables[$key]
    }
}
$specPath = Join-Path $StateDirectory 'launch.json'
@{
    Executable = $StartInfo.FileName; Arguments = $StartInfo.Arguments
    WorkingDirectory = $StartInfo.WorkingDirectory; Environment = $childEnvironment
    ConfigPath = $ConfigPath; StateDirectory = $StateDirectory
    RestoreWorkAreas = $RestoreWorkAreas.IsPresent
    StdoutPath = $StdoutPath; StderrPath = $StderrPath
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $specPath -Encoding UTF8
$watcher = Join-Path $PSScriptRoot 'Watch-DesktopShell.ps1'
foreach ($var in @('ELECTRON_RUN_AS_NODE', 'ELECTRON_NO_ASAR')) {
    [Environment]::SetEnvironmentVariable($var, $null, 'Process')
}
$arguments = '-NoProfile -Sta -File "' + $watcher + '" -LaunchSpec "' + $specPath + '"'
$process = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList $arguments -WindowStyle Hidden -PassThru `
    -WorkingDirectory $StartInfo.WorkingDirectory `
    -RedirectStandardOutput (Join-Path $StateDirectory 'watchdog.stdout.log') `
    -RedirectStandardError (Join-Path $StateDirectory 'watchdog.stderr.log')
$null = $process.Handle
# The child starts only after snapshot persistence and takeover ownership. The
# watchdog reports "starting" at once, then "running" after banner recovery
# (up to 45 s) and the shell's first frame on every monitor (20 s per
# attempt). The overall 75 s launch bound can cancel repeated failed attempts.
# This pre-takeover replay is separate from exit's "restoring" phase, which
# returns the desktop first and retains ownership through banner recovery.
$deadline = [DateTime]::UtcNow.AddSeconds(75)
$statusPath = Join-Path $StateDirectory 'watchdog.json'
$phase = ''
while ($true) {
    if (Test-Path -LiteralPath $statusPath) {
        try { $phase = [string](Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).phase } catch { }
        if ($phase -eq 'running') { break }
        if ($phase -in @('watchdog-error', 'crash-give-up', 'recovered', 'clean-exit', 'restore-pending')) {
            throw "Desktop watchdog stopped during startup ($phase). See $StateDirectory\watchdog-error.log"
        }
    }
    if ($process.HasExited) { throw "Desktop watchdog exited during startup. See $StateDirectory\watchdog.stderr.log" }
    if ([DateTime]::UtcNow -ge $deadline) {
        # Never hard-kill just the watchdog and orphan its child/AppBars.
        # Use the same identity-checked bounded recovery as Quit.
        Stop-CaelestiaSupervisor ([pscustomobject]@{ Process = $process; StatusPath = $statusPath })
        $snapshot = Join-Path $StateDirectory 'desktop-before.json'
        $status = Read-CaelestiaSupervisorStatus $statusPath
        if ($status.phase -notin @('clean-exit', 'recovered', 'crash-give-up', 'watchdog-error') -and
            (Test-Path -LiteralPath $snapshot)) {
            & (Join-Path $PSScriptRoot 'Restore-Desktop.ps1') -SnapshotPath $snapshot -InactiveOnly | Out-Null
        }
        throw "Desktop watchdog did not reach 'running' (last phase '$phase'); bounded recovery completed. See $StateDirectory\watchdog.stderr.log"
    }
    Start-Sleep -Milliseconds 100
}
[pscustomobject]@{ Watchdog = $process; StatusPath = $statusPath; StateDirectory = $StateDirectory }
