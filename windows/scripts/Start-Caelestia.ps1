[CmdletBinding()]
param(
    [string]$Prefix,
    [ValidateSet('Start', 'State', 'Quit', 'Restart')][string]$Command = 'Start',
    [switch]$Smoke,
    [switch]$Wait
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
if (-not $Prefix) {
    $Prefix = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json')) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows' }
}
$Prefix = Resolve-CaelestiaDirectory $Prefix
$record = Read-CaelestiaInstall $Prefix
$profile = Resolve-CaelestiaDirectory $record.profile
$stage = Join-Path $Prefix 'shell'
$exe = Join-Path $Prefix 'qs.exe'
if ($Smoke -and $Command -ne 'Start') { throw '-Smoke requires -Command Start.' }

if ($Command -eq 'Start') {
    foreach ($dir in @('config', 'state', 'cache', 'data', 'runtime', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $dir) | Out-Null
    }
    $config = Join-Path $profile 'config\shell.json'
    # Seed once. Updates/restarts never overwrite user edits or malformed files.
    if (-not (Test-Path -LiteralPath $config)) {
        Copy-Item -LiteralPath (Join-Path $Prefix 'defaults\shell.json') -Destination $config
    }
}

$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.WorkingDirectory = $Prefix
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
# Preserve the user's launch environment in normal use. Smoke deliberately
# excludes developer PATH entries to check the deployed runtime independently.
$info.EnvironmentVariables['PATH'] = $(if ($Smoke) { "$Prefix;$env:SystemRoot\System32;$env:SystemRoot" } else { "$Prefix;$env:PATH" })
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$Prefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$Prefix\qml"
$info.EnvironmentVariables['QT_PLUGIN_PATH'] = Join-Path $Prefix 'plugins'
$info.EnvironmentVariables['QT_QPA_PLATFORM_PLUGIN_PATH'] = Join-Path $Prefix 'plugins\platforms'
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $profile 'cache\qml'
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = Join-Path $profile 'config'
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = Join-Path $profile 'state'
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = Join-Path $profile 'runtime'
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
$info.EnvironmentVariables['QT_LOGGING_RULES'] = 'quickshell.windows.tracker.debug=false;quickshell.windows.inputmask.debug=false'
$info.EnvironmentVariables['CAELESTIA_SHELL_LIVE'] = '1'
$info.EnvironmentVariables['CAELESTIA_COMBINED_LIVE'] = $(if ($Smoke) { '0' } else { '1' })
$info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = $(if ($Smoke) { '1' } else { '0' })
foreach ($slice in @('AUDIO', 'BATTERY', 'BLUETOOTH', 'BRIGHTNESS', 'MEDIA', 'NETWORK', 'APPS', 'TRAY', 'NOTIFICATIONS', 'SESSION', 'POWER_PROFILES')) {
    $info.EnvironmentVariables["CAELESTIA_WINDOWS_$slice"] = '1'
}
$liveValue = $(if ($Smoke) { '0' } else { '1' })
foreach ($gate in @('AUDIO_CONTROLS', 'BLUETOOTH_CONTROLS', 'BRIGHTNESS_CONTROLS', 'MEDIA_CONTROLS', 'NETWORK_CONTROLS', 'APP_LAUNCH', 'TRAY_ACTIVATION', 'POWER_PROFILE_WRITES', 'SESSION_ACTIONS', 'NOTIFICATION_MIRROR', 'NOTIFICATION_MIRROR_DISMISS', 'NOTIFICATION_APP_OPEN')) {
    $info.EnvironmentVariables["CAELESTIA_WINDOWS_$gate"] = $liveValue
}
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = $liveValue
$info.EnvironmentVariables['CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE'] = '0'
$info.EnvironmentVariables['CAELESTIA_SHELL_SESSION'] = '1'
$info.EnvironmentVariables['CAELESTIA_SHELL_SESSION_MODE'] = 'Observe'
$info.EnvironmentVariables['CAELESTIA_TRAY_FIXTURE'] = '0'
# Reserved integration gates. Future controllers must honor their own opt-in;
# this entry does not instantiate them or mutate Explorer/taskbar settings.
$info.EnvironmentVariables['CAELESTIA_WINDOWS_TILING'] = '0'
$info.EnvironmentVariables['CAELESTIA_WINDOWS_GLOBAL_SHORTCUTS'] = '0'
# Do not inherit synthetic DPI or QPA settings from development/probe sessions.
foreach ($name in @('QT_SCALE_FACTOR', 'QT_SCREEN_SCALE_FACTORS', 'QT_FONT_DPI', 'QT_ENABLE_HIGHDPI_SCALING', 'QT_QPA_PLATFORM')) {
    $info.EnvironmentVariables.Remove($name)
}

if ($Command -ne 'Start') {
    $info.Arguments = 'ipc --path "' + (Join-Path $stage 'shell.qml') + '" call shell ' + $Command.ToLowerInvariant()
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Shell IPC timed out.' }
    $output = $outTask.GetAwaiter().GetResult()
    $errors = $errTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "Shell IPC failed: $output $errors" }
    Write-Output $output
    return
}

$info.Arguments = '--no-duplicate --no-color --log-times --path "' + (Join-Path $stage 'shell.qml') + '"'
$info.RedirectStandardOutput = $Smoke.IsPresent -or $Wait.IsPresent
$info.RedirectStandardError = $Smoke.IsPresent -or $Wait.IsPresent
$process = [Diagnostics.Process]::Start($info)
if (-not $Smoke -and -not $Wait) {
    Write-Output "Started Caelestia (PID $($process.Id)). Profile: $profile"
    return
}
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = $false
if ($Smoke) { $timedOut = -not $process.WaitForExit(30000) } else { $process.WaitForExit() }
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$output = $outTask.GetAwaiter().GetResult()
$errors = $errTask.GetAwaiter().GetResult()
$output | Set-Content -LiteralPath (Join-Path $profile 'logs\shell.stdout.log') -Encoding UTF8
$errors | Set-Content -LiteralPath (Join-Path $profile 'logs\shell.stderr.log') -Encoding UTF8
Write-Output "$output`n$errors"
$diagnostics = "$output`n$errors" -match '(?m)^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})?\s*(WARN(?:ING)?|ERROR|FATAL|CRIT(?:ICAL)?)\b'
if ($timedOut -or $process.ExitCode -ne 0 -or ($Smoke -and ($diagnostics -or -not $output.Contains('CAELESTIA_SHELL_LIVE_PASS')))) {
    throw "Caelestia failed (exit $($process.ExitCode), timeout $timedOut). See $profile\logs."
}
