[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [switch]$Smoke,
    [switch]$Wait,
    [switch]$MonitorCycle,
    [ValidateSet('native', '1', '1.5', '1.75')][string]$ScaleFactor = 'native',
    [ValidateRange(0, 15)][int]$ScreenIndex = 0
)

$ErrorActionPreference = 'Stop'
if ($MonitorCycle -and (-not $Smoke -or $ScaleFactor -ne 'native')) {
    throw '-MonitorCycle requires -Smoke and native scaling.'
}
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
foreach ($required in @($exe, "$QtPrefix\bin\Qt6Core.dll", "$qmlRoot\Caelestia\Config\qmldir", "$qmlRoot\Caelestia\Windows\qmldir")) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Build prerequisite missing: $required" }
}
$runName = 'shell-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$profileRoot = Join-Path $BuildRoot 'shell-prototype-profile'
# A fresh stage avoids stale QML types from a previous implementation.
$stage = & (Join-Path $PSScriptRoot 'Stage-ShellPrototype.ps1') `
    -Destination (Join-Path $BuildRoot "shell-runs\$runName") -ProfileRoot $profileRoot
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
    Write-Output "Started isolated bar/session prototype (PID $($process.Id))."
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
    Write-Output "Started isolated bar/session prototype (PID $($process.Id)); capturing logs until it exits."
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
    $process.ExitCode -eq 0 -and $combined.Contains('CAELESTIA_SHELL_PASS') -and
    (Test-Path -LiteralPath $screenshot)
Copy-Item -LiteralPath (Join-Path $stage 'sources.json') -Destination (Join-Path $logRoot "$runName.sources.json")
$result = [ordered]@{
    passed = $(if ($Smoke) { $passed } else { $null }); smoke = $Smoke.IsPresent
    timedOut = $timedOut; exitCode = $process.ExitCode
    scaleFactor = $ScaleFactor; screenIndex = $ScreenIndex
    monitorCycle = $MonitorCycle.IsPresent
    actualScreens = @([regex]::Matches($combined, 'CAELESTIA_SHELL_SCREEN (\{[^\r\n]+\})') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
    captures = @([regex]::Matches($combined, 'CAELESTIA_SHELL_CAPTURE ([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
    elapsedMilliseconds = $elapsed.ElapsedMilliseconds
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (& git -C (Join-Path $repoRoot 'windows\deps\quickshell') rev-parse HEAD).Trim()
    buildRecordSha256 = (Get-FileHash -LiteralPath (Join-Path $logRoot 'build.json')).Hash
    configSha256 = (Get-FileHash -LiteralPath $config).Hash
    command = $info.FileName; arguments = $info.Arguments
    stage = $stage; profile = $profileRoot
    sources = "$logRoot\$runName.sources.json"
    screenshot = $screenshot; stdout = $stdoutPath; stderr = $stderrPath
} | ConvertTo-Json
$result | Set-Content -LiteralPath (Join-Path $logRoot "$runName.json") -Encoding UTF8
Write-Output $result
if (($Smoke -and -not $passed) -or $process.ExitCode -ne 0) {
    throw "Bar/session prototype failed. See $stdoutPath and $stderrPath."
}
