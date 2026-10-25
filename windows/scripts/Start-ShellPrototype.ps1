[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [switch]$Smoke,
    [switch]$Wait,
    [switch]$MonitorCycle,
    [switch]$TraceInput,
    [switch]$Audio,
    [ValidateSet('Disabled', 'ReadOnly', 'Interactive')][string]$AudioMode = 'Disabled',
    [switch]$Battery,
    [ValidateSet('Disabled', 'ReadOnly')][string]$BatteryMode = 'Disabled',
    [switch]$Media,
    [ValidateSet('Disabled', 'ReadOnly', 'Interactive')][string]$MediaMode = 'Disabled',
    [ValidateSet('native', '1', '1.5', '1.75')][string]$ScaleFactor = 'native',
    [ValidateRange(0, 15)][int]$ScreenIndex = 0
)

$ErrorActionPreference = 'Stop'
if ($MonitorCycle -and (-not $Smoke -or $ScaleFactor -ne 'native')) {
    throw '-MonitorCycle requires -Smoke and native scaling.'
}
if ($Audio -and $Battery) { throw 'Select one prototype entry point per run.' }
if ($Media -and ($Audio -or $Battery)) { throw 'Select one prototype entry point per run.' }
if (($Audio -or $Battery -or $Media) -and $MonitorCycle) { throw 'The audio/battery/media prototypes do not implement monitor cycling.' }
if (-not $Audio -and $AudioMode -ne 'Disabled') { throw '-AudioMode requires -Audio.' }
if (-not $Battery -and $BatteryMode -ne 'Disabled') { throw '-BatteryMode requires -Battery.' }
if (-not $Media -and $MediaMode -ne 'Disabled') { throw '-MediaMode requires -Media.' }
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
foreach ($required in @($exe, "$QtPrefix\bin\Qt6Core.dll", "$qmlRoot\Caelestia\Config\qmldir", "$qmlRoot\Caelestia\Windows\qmldir")) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Build prerequisite missing: $required" }
}
$kind = $(if ($Audio) { 'audio' } elseif ($Battery) { 'battery' } elseif ($Media) { 'media' } else { 'shell' })
$marker = $(if ($Audio) { 'CAELESTIA_AUDIO' } elseif ($Battery) { 'CAELESTIA_BATTERY' } elseif ($Media) { 'CAELESTIA_MEDIA' } else { 'CAELESTIA_SHELL' })
$runName = $kind + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$profileRoot = Join-Path $BuildRoot "$kind-prototype-profile"
# A fresh stage avoids stale QML types from a previous implementation.
$stage = & (Join-Path $PSScriptRoot 'Stage-ShellPrototype.ps1') `
    -Destination (Join-Path $BuildRoot "shell-runs\$runName") -ProfileRoot $profileRoot -Audio:$Audio -Battery:$Battery -Media:$Media
foreach ($dir in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profileRoot $dir) | Out-Null
}
# This dedicated prototype profile intentionally accepts only this audited slice.
# Never read or write ordinary Caelestia configuration.
$config = Join-Path $profileRoot 'config\shell.json'
@'
{
  "bar": {
    "persistent": false,
    "showOnHover": true,
    "entries": [
      {"id":"spacer","enabled":true},
      {"id":"clock","enabled":true},
      {"id":"spacer","enabled":true},
      {"id":"power","enabled":true}
    ],
    "clock": {"showIcon":true,"showDate":true,"showSeconds":true},
    "scrollActions": {"workspaces":false,"volume":false,"brightness":false},
    "popouts": {"activeWindow":false,"tray":false,"statusIcons":false}
  },
  "session": {
    "enabled": true,
    "vimKeybinds": true,
    "commands": {"logout":[],"shutdown":[],"hibernate":[],"reboot":[]}
  },
  "paths": {"sessionGif":""},
  "dashboard": {"enabled":false,"showOnHover":false},
  "launcher": {"enabled":false,"showOnHover":false},
  "sidebar": {"enabled":false,"showOnHover":false},
  "osd": {"enabled":false},
  "utilities": {"enabled":false}
}
'@ | Set-Content -LiteralPath $config -Encoding UTF8
$logRoot = Join-Path $BuildRoot 'logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$screenshot = Join-Path $logRoot "$runName.png"
$stdoutPath = Join-Path $logRoot "$runName.stdout.log"
$stderrPath = Join-Path $logRoot "$runName.stderr.log"
$info = New-Object System.Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '--no-color --log-times --path "' + (Join-Path $stage 'shell.qml') + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $profileRoot 'cache'
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = Join-Path $profileRoot 'config'
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = Join-Path $profileRoot 'state'
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = Join-Path $profileRoot 'runtime'
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$info.EnvironmentVariables['QT_LOGGING_RULES'] = 'quickshell.windows.tracker.debug=false;quickshell.windows.inputmask.debug=false'
if ($TraceInput) {
    $info.EnvironmentVariables['QT_LOGGING_RULES'] = 'quickshell.windows.tracker.debug=false;quickshell.windows.inputmask.debug=true'
}
$info.EnvironmentVariables['CAELESTIA_SHELL_TRACE_INPUT'] = $(if ($TraceInput) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_WINDOWS_AUDIO'] = $(if ($Audio -and $AudioMode -ne 'Disabled') { '1' } else { '0' })
# Smoke is always read-only, including when Interactive was requested.
$info.EnvironmentVariables['CAELESTIA_WINDOWS_AUDIO_CONTROLS'] = $(if ($Audio -and $AudioMode -eq 'Interactive' -and -not $Smoke) { '1' } else { '0' })
# Battery observation has no interactive mode: this slice performs no writes.
$info.EnvironmentVariables['CAELESTIA_WINDOWS_BATTERY'] = $(if ($Battery -and $BatteryMode -ne 'Disabled') { '1' } else { '0' })
# Media observation and explicit transport requests are separate opt-ins. Smoke
# is always read-only, including when Interactive was requested.
$info.EnvironmentVariables['CAELESTIA_WINDOWS_MEDIA'] = $(if ($Media -and $MediaMode -ne 'Disabled') { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_WINDOWS_MEDIA_CONTROLS'] = $(if ($Media -and $MediaMode -eq 'Interactive' -and -not $Smoke) { '1' } else { '0' })
if ($ScaleFactor -ne 'native') {
    $info.EnvironmentVariables['QT_ENABLE_HIGHDPI_SCALING'] = '0'
    $info.EnvironmentVariables['QT_SCALE_FACTOR'] = $ScaleFactor
    $info.EnvironmentVariables['QT_FONT_DPI'] = '96'
    $info.EnvironmentVariables.Remove('QT_SCREEN_SCALE_FACTORS')
    $info.EnvironmentVariables['QT_SCALE_FACTOR_ROUNDING_POLICY'] = 'PassThrough'
}
$info.EnvironmentVariables['CAELESTIA_SHELL_SCALE'] = $ScaleFactor
$info.EnvironmentVariables['CAELESTIA_SHELL_SCREEN'] = [string]$ScreenIndex
$info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = $(if ($Smoke) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_SHELL_MONITOR_CYCLE'] = $(if ($MonitorCycle) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_SHELL_SCREENSHOT'] = ([Uri]$screenshot).AbsoluteUri
$info.RedirectStandardOutput = $Smoke.IsPresent -or $Wait.IsPresent
$info.RedirectStandardError = $Smoke.IsPresent -or $Wait.IsPresent

$elapsed = [Diagnostics.Stopwatch]::StartNew()
$process = [Diagnostics.Process]::Start($info)
if (-not $Smoke -and -not $Wait) {
    Write-Output "Started isolated $kind prototype (PID $($process.Id))."
    Write-Output "Staged source: $stage"
    Write-Output "Stop only this process when finished: Stop-Process -Id $($process.Id)"
    return
}
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = $false
if ($Smoke) {
    $timedOut = -not $process.WaitForExit(45000)
} else {
    Write-Output "Started isolated $kind prototype (PID $($process.Id)); capturing logs until it exits."
    Write-Output "Staged source: $stage"
    $process.WaitForExit()
}
if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
}
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$elapsed.Stop()
$stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
$stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8
$combined = "$stdout`n$stderr"
$runtimeDiagnostics = $combined -match '(?m)^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})?\s*(WARN(?:ING)?|ERROR|FATAL|CRIT(?:ICAL)?)\b'
$passed = -not $timedOut -and -not $runtimeDiagnostics -and
    $process.ExitCode -eq 0 -and $combined.Contains("${marker}_PASS") -and
    (Test-Path -LiteralPath $screenshot)
Copy-Item -LiteralPath (Join-Path $stage 'sources.json') -Destination (Join-Path $logRoot "$runName.sources.json")
$result = [ordered]@{
    passed = $(if ($Smoke) { $passed } else { $null }); smoke = $Smoke.IsPresent
    prototype = $kind; audioMode = $AudioMode; batteryMode = $BatteryMode; mediaMode = $MediaMode
    timedOut = $timedOut; exitCode = $process.ExitCode
    scaleFactor = $ScaleFactor; screenIndex = $ScreenIndex
    monitorCycle = $MonitorCycle.IsPresent
    traceInput = $TraceInput.IsPresent
    actualScreens = @([regex]::Matches($combined, "${marker}_SCREEN (\{[^\r\n]+\})") | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
    captures = @([regex]::Matches($combined, "${marker}_CAPTURE ([^\r\n]+)") | ForEach-Object { $_.Groups[1].Value })
    audioSnapshots = @([regex]::Matches($combined, 'CAELESTIA_AUDIO_(INITIAL|FINAL) (\{[^\r\n]+\})') | ForEach-Object {
        [ordered]@{ phase = $_.Groups[1].Value; state = ($_.Groups[2].Value | ConvertFrom-Json) }
    })
    batterySnapshots = @([regex]::Matches($combined, 'CAELESTIA_BATTERY_(INITIAL|FINAL) (\{[^\r\n]+\})') | ForEach-Object {
        [ordered]@{ phase = $_.Groups[1].Value; state = ($_.Groups[2].Value | ConvertFrom-Json) }
    })
    mediaSnapshots = @([regex]::Matches($combined, 'CAELESTIA_MEDIA_(INITIAL|FINAL) (\{[^\r\n]+\})') | ForEach-Object {
        [ordered]@{ phase = $_.Groups[1].Value; state = ($_.Groups[2].Value | ConvertFrom-Json) }
    })
    elapsedMilliseconds = $elapsed.ElapsedMilliseconds
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (& git -C (Join-Path $repoRoot 'windows\deps\quickshell') rev-parse HEAD).Trim()
    buildRecordSha256 = (Get-FileHash -LiteralPath (Join-Path $logRoot 'build.json')).Hash
    configSha256 = (Get-FileHash -LiteralPath $config).Hash
    command = $info.FileName; arguments = $info.Arguments
    executableSha256 = (Get-FileHash -LiteralPath $exe).Hash
    stage = $stage; profile = $profileRoot
    sources = "$logRoot\$runName.sources.json"
    screenshot = $screenshot; stdout = $stdoutPath; stderr = $stderrPath
} | ConvertTo-Json -Depth 12
$result | Set-Content -LiteralPath (Join-Path $logRoot "$runName.json") -Encoding UTF8
Write-Output $result
if (($Smoke -and -not $passed) -or $process.ExitCode -ne 0) {
    throw "$kind prototype failed. See $stdoutPath and $stderrPath."
}
