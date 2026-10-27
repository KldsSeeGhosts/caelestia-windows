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
$process = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $StateDirectory 'watchdog.stdout.log') `
    -RedirectStandardError (Join-Path $StateDirectory 'watchdog.stderr.log')
$null = $process.Handle
# The child starts only after snapshot persistence and takeover ownership.
$deadline = [DateTime]::UtcNow.AddSeconds(20)
$statusPath = Join-Path $StateDirectory 'watchdog.json'
while (-not (Test-Path -LiteralPath $statusPath)) {
    if ($process.HasExited -or [DateTime]::UtcNow -ge $deadline) {
        throw "Desktop watchdog did not start. See $StateDirectory\watchdog.stderr.log"
    }
    Start-Sleep -Milliseconds 100
}
[pscustomobject]@{ Watchdog = $process; StatusPath = $statusPath; StateDirectory = $StateDirectory }
