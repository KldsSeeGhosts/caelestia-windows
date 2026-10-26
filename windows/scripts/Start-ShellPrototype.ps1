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
    [ValidateSet('Disabled', 'ReadOnly', 'Profiles', 'ProfileWrites')][string]$BatteryMode = 'Disabled',
    [switch]$Media,
    [ValidateSet('Disabled', 'ReadOnly', 'Interactive')][string]$MediaMode = 'Disabled',
    [switch]$Brightness,
    [ValidateSet('Disabled', 'ReadOnly', 'Interactive')][string]$BrightnessMode = 'Disabled',
    [switch]$Network,
    [ValidateSet('Disabled', 'ReadOnly', 'Interactive')][string]$NetworkMode = 'Disabled',
    [switch]$Bluetooth,
    [ValidateSet('Disabled', 'ReadOnly', 'Interactive')][string]$BluetoothMode = 'Disabled',
    [switch]$Apps,
    [ValidateSet('Disabled', 'ReadOnly', 'Interactive')][string]$AppsMode = 'Disabled',
    [string]$AppsSearchQuery = '',
    [switch]$Tray,
    [ValidateSet('Disabled', 'ReadOnly', 'Interactive')][string]$TrayMode = 'Disabled',
    [switch]$TrayFixture,
    [switch]$Session,
    [ValidateSet('Disabled', 'Observe')][string]$SessionMode = 'Disabled',
    [switch]$SessionActions,
    [switch]$Notifications,
    [ValidateSet('Disabled', 'Local', 'Mirror')][string]$NotificationsMode = 'Disabled',
    [switch]$NotificationDismiss,
    [switch]$NotificationAppOpen,
    [switch]$Combined,
    [ValidateSet('native', '1', '1.5', '1.75')][string]$ScaleFactor = 'native',
    [ValidateRange(0, 15)][int]$ScreenIndex = 0
)

$ErrorActionPreference = 'Stop'
if ($MonitorCycle -and (-not $Smoke -or $ScaleFactor -ne 'native')) {
    throw '-MonitorCycle requires -Smoke and native scaling.'
}
# One row per bounded slice. Observe is the observation opt-in; Controls is the
# separate write/action opt-in, set only for its control mode and never during
# smoke. Session extends the M1 bar/session host, so it stages the shell host
# and its pass marker stays CAELESTIA_SHELL; its control opt-in is the explicit
# -SessionActions switch.
$slices = [ordered]@{
    audio     = @{ On = $Audio; Mode = $AudioMode; Observe = 'CAELESTIA_WINDOWS_AUDIO'; Controls = 'CAELESTIA_WINDOWS_AUDIO_CONTROLS'; ControlMode = 'Interactive' }
    battery   = @{ On = $Battery; Mode = $BatteryMode; Observe = 'CAELESTIA_WINDOWS_BATTERY'; Controls = 'CAELESTIA_WINDOWS_POWER_PROFILE_WRITES'; ControlMode = 'ProfileWrites' }
    media     = @{ On = $Media; Mode = $MediaMode; Observe = 'CAELESTIA_WINDOWS_MEDIA'; Controls = 'CAELESTIA_WINDOWS_MEDIA_CONTROLS'; ControlMode = 'Interactive' }
    brightness = @{ On = $Brightness; Mode = $BrightnessMode; Observe = 'CAELESTIA_WINDOWS_BRIGHTNESS'; Controls = 'CAELESTIA_WINDOWS_BRIGHTNESS_CONTROLS'; ControlMode = 'Interactive' }
    network   = @{ On = $Network; Mode = $NetworkMode; Observe = 'CAELESTIA_WINDOWS_NETWORK'; Controls = 'CAELESTIA_WINDOWS_NETWORK_CONTROLS'; ControlMode = 'Interactive' }
    bluetooth = @{ On = $Bluetooth; Mode = $BluetoothMode; Observe = 'CAELESTIA_WINDOWS_BLUETOOTH'; Controls = 'CAELESTIA_WINDOWS_BLUETOOTH_CONTROLS'; ControlMode = 'Interactive' }
    apps      = @{ On = $Apps; Mode = $AppsMode; Observe = 'CAELESTIA_WINDOWS_APPS'; Controls = 'CAELESTIA_WINDOWS_APP_LAUNCH'; ControlMode = 'Interactive' }
    tray      = @{ On = $Tray; Mode = $TrayMode; Observe = 'CAELESTIA_WINDOWS_TRAY'; Controls = 'CAELESTIA_WINDOWS_TRAY_ACTIVATION'; ControlMode = 'Interactive' }
    session   = @{ On = $Session; Mode = $SessionMode; Observe = 'CAELESTIA_WINDOWS_SESSION'; Controls = 'CAELESTIA_WINDOWS_SESSION_ACTIONS'; ControlSwitch = $SessionActions; Stage = 'shell'; Marker = 'CAELESTIA_SHELL' }
    # Mirror mode adds its own opt-ins below; smoke never mirrors.
    notifications = @{ On = $Notifications; Mode = $NotificationsMode; Observe = 'CAELESTIA_WINDOWS_NOTIFICATIONS' }
}
$selected = @($slices.Keys | Where-Object { $slices[$_].On })
if ($selected.Count -gt 1) { throw 'Select one prototype entry point per run.' }
if ($Combined -and $selected.Count -gt 0) { throw '-Combined cannot be combined with a single-slice entry point.' }
if ($Combined -and $MonitorCycle) { throw 'Only the M1 shell prototype implements monitor cycling.' }
foreach ($name in $slices.Keys) {
    $label = (Get-Culture).TextInfo.ToTitleCase($name)
    if (-not $slices[$name].On -and $slices[$name].Mode -ne 'Disabled') { throw "-${label}Mode requires -$label." }
}
if ($selected.Count -gt 0 -and $MonitorCycle) { throw 'Only the M1 shell prototype implements monitor cycling.' }
if (-not $Apps -and $AppsSearchQuery) { throw '-AppsSearchQuery requires -Apps.' }
# The fixture preview must never run with native observation or activation.
if ($TrayFixture -and (-not $Tray -or -not $Smoke -or $TrayMode -ne 'Disabled')) {
    throw '-TrayFixture requires -Tray -TrayMode Disabled -Smoke.'
}
if ($SessionActions -and (-not $Session -or $SessionMode -ne 'Observe')) {
    throw '-SessionActions requires -Session -SessionMode Observe.'
}
if ($NotificationDismiss -and $NotificationsMode -ne 'Mirror') { throw '-NotificationDismiss requires -NotificationsMode Mirror.' }
if ($NotificationAppOpen -and $NotificationsMode -ne 'Mirror') { throw '-NotificationAppOpen requires -NotificationsMode Mirror.' }
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
foreach ($required in @($exe, "$QtPrefix\bin\Qt6Core.dll", "$qmlRoot\Caelestia\Config\qmldir", "$qmlRoot\Caelestia\Windows\qmldir")) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Build prerequisite missing: $required" }
}
$kind = $(if ($selected.Count -eq 1) { $selected[0] } elseif ($Combined) { 'combined' } else { 'shell' })
$stagePrototype = $(if ($kind -ne 'shell' -and $slices[$kind].Stage) { $slices[$kind].Stage } else { $kind })
$marker = $(if ($kind -ne 'shell' -and $slices[$kind].Marker) { $slices[$kind].Marker } else { 'CAELESTIA_' + $kind.ToUpperInvariant() })
$runName = $kind + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$profileRoot = Join-Path $BuildRoot "$kind-prototype-profile"
# A fresh stage avoids stale QML types from a previous implementation.
$stage = & (Join-Path $PSScriptRoot 'Stage-ShellPrototype.ps1') `
    -Destination (Join-Path $BuildRoot "shell-runs\$runName") -ProfileRoot $profileRoot -Prototype $stagePrototype
foreach ($dir in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profileRoot $dir) | Out-Null
}
# This dedicated prototype profile intentionally accepts only this audited slice.
# Never read or write ordinary Caelestia configuration.
$config = Join-Path $profileRoot 'config\shell.json'
$configText = @'
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
'@
# Only the tray profile opts into icon recolouring; the upstream default stays
# false for every other prototype slice.
if ($Tray) {
    $configObject = $configText | ConvertFrom-Json
    $configObject.bar | Add-Member -NotePropertyName tray `
        -NotePropertyValue ([pscustomobject]@{ recolour = $true }) -Force
    $configText = $configObject | ConvertTo-Json -Depth 10
}
# Session runs bind the original buttons to the adapter's allowlisted command
# names. The M1 default keeps empty commands. Dispatch still needs
# CAELESTIA_WINDOWS_SESSION_ACTIONS, and destructive actions still stop at the
# confirmation gate.
if ($Session) {
    $configText = $configText.Replace(
        '"commands": {"logout":[],"shutdown":[],"hibernate":[],"reboot":[]}',
        '"commands": {"logout":["logout"],"shutdown":["shutdown"],"hibernate":["hibernate"],"reboot":["reboot"]}')
}
# The combined profile keeps every original bar entry that has a reviewed
# facade (logo, tray, clock, status icons, power), enables the status-icon
# popouts, the OSD, the hover-driven launcher and the media dashboard panel,
# and leaves every write path out: empty session commands, no sidebar or
# utilities panels and no scroll actions. The lock-status, microphone and
# keyboard-layout status icons stay disabled; they need Hyprland input
# events no Windows facade provides.
if ($Combined) {
    $configText = @'
{
  "bar": {
    "persistent": false,
    "showOnHover": true,
    "entries": [
      {"id":"logo","enabled":true},
      {"id":"spacer","enabled":true},
      {"id":"tray","enabled":true},
      {"id":"clock","enabled":true},
      {"id":"statusIcons","enabled":true},
      {"id":"power","enabled":true}
    ],
    "clock": {"showIcon":true,"showDate":true,"showSeconds":true},
    "scrollActions": {"workspaces":false,"volume":false,"brightness":false},
    "popouts": {"activeWindow":false,"tray":false,"statusIcons":true},
    "statusIcons": [
      {"id":"lockStatus","enabled":false},
      {"id":"audio","enabled":true},
      {"id":"microphone","enabled":false},
      {"id":"kbLayout","enabled":false},
      {"id":"network","enabled":true},
      {"id":"bluetooth","enabled":true},
      {"id":"battery","enabled":true}
    ],
    "tray": {"recolour": true}
  },
  "session": {
    "enabled": true,
    "vimKeybinds": true,
    "commands": {"logout":[],"shutdown":[],"hibernate":[],"reboot":[]}
  },
  "paths": {"sessionGif":""},
  "dashboard": {"enabled":true,"showOnHover":true},
  "launcher": {"enabled":true,"showOnHover":true},
  "sidebar": {"enabled":false,"showOnHover":false},
  "osd": {"enabled":true},
  "utilities": {"enabled":false}
}
'@
}
$configText | Set-Content -LiteralPath $config -Encoding UTF8
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
# Tray runs surface the backend's construction line so the harness can prove
# whether SystemTray was instantiated. It is an INFO record, not a warning.
if ($Tray) {
    $info.EnvironmentVariables['QT_LOGGING_RULES'] = $info.EnvironmentVariables['QT_LOGGING_RULES'] + ';quickshell.windows.systray.info=true'
}
# Every slice's opt-ins are written explicitly, so an inherited value never
# enables a slice. Observation follows the selected mode; controls need their
# control mode (or switch) and are always off during smoke.
foreach ($name in $slices.Keys) {
    $slice = $slices[$name]
    $observe = $slice.On -and $slice.Mode -ne 'Disabled'
    $controls = $false
    if ($slice.Controls) {
        $requested = $(if ($slice.ContainsKey('ControlSwitch')) { [bool]$slice.ControlSwitch } else { $slice.Mode -eq $slice.ControlMode })
        $controls = $slice.On -and $requested -and -not $Smoke
    }
    # The tray fixture preview constructs no native backend at all.
    if ($name -eq 'tray' -and $TrayFixture) { $observe = $false; $controls = $false }
    $info.EnvironmentVariables[$slice.Observe] = $(if ($observe) { '1' } else { '0' })
    if ($slice.Controls) { $info.EnvironmentVariables[$slice.Controls] = $(if ($controls) { '1' } else { '0' }) }
}
# Brightness software gamma is a separate parent-process opt-in. This launcher
# neither supplies it nor forwards it to a smoke run.
$softwareOptIn = $env:CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE -eq '1'
$info.EnvironmentVariables['CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE'] = $(if ($Brightness -and $BrightnessMode -eq 'Interactive' -and -not $Smoke -and $softwareOptIn) { '1' } else { '0' })
# Battery observation stays read-only; Profiles adds read-only PowerProfiles
# observation, and ProfileWrites (the battery control mode above) additionally
# permits explicit profile selection outside smoke.
$info.EnvironmentVariables['CAELESTIA_WINDOWS_POWER_PROFILES'] = $(if ($Battery -and $BatteryMode -in @('Profiles', 'ProfileWrites')) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_APPS_SMOKE_QUERY'] = $(if ($Apps) { $AppsSearchQuery } else { '' })
$info.EnvironmentVariables['CAELESTIA_TRAY_FIXTURE'] = $(if ($TrayFixture) { '1' } else { '0' })
# Tray runs never enable the backend tray hook: with 0 the host skips
# interception and Explorer snapshot scheduling, while SystemTray construction
# still starts its 10 s prune timer. Interception ownership is a separate
# review, so no launcher switch exposes it. Other prototypes keep the inherited
# environment unchanged.
if ($Tray) {
    $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
}
$info.EnvironmentVariables['CAELESTIA_SHELL_SESSION'] = $(if ($Session) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_SHELL_SESSION_MODE'] = $SessionMode
# Mirroring and its two side effects are separate opt-ins that only exist in
# Mirror mode. Smoke always forces all three off, so a smoke run never
# constructs the mirror worker, never requests notification-listener access and
# never enables Windows dismissal or app-open.
$mirrorMode = $Notifications -and $NotificationsMode -eq 'Mirror' -and -not $Smoke
$info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_MIRROR'] = $(if ($mirrorMode) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_MIRROR_DISMISS'] = $(if ($mirrorMode -and $NotificationDismiss) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_APP_OPEN'] = $(if ($mirrorMode -and $NotificationAppOpen) { '1' } else { '0' })
# The combined prototype is the read-only union of every slice: each service's
# observation opt-in is forced on (the session in Observe mode, with dispatch
# still gated off) and every control, write, launch, activation, dispatch and
# mirror opt-in is forced off, regardless of what the parent environment
# contained. The backend tray hook stays off so observation never starts tray
# interception, and software gamma brightness is never supplied.
if ($Combined) {
    foreach ($name in $slices.Keys) {
        $info.EnvironmentVariables[$slices[$name].Observe] = '1'
        if ($slices[$name].Controls) { $info.EnvironmentVariables[$slices[$name].Controls] = '0' }
    }
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_POWER_PROFILES'] = '1'
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE'] = '0'
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_MIRROR'] = '0'
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_MIRROR_DISMISS'] = '0'
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_APP_OPEN'] = '0'
    $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
    $info.EnvironmentVariables['CAELESTIA_SHELL_SESSION'] = '1'
    $info.EnvironmentVariables['CAELESTIA_SHELL_SESSION_MODE'] = 'Observe'
}
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
# Named runOutput: the -Combined switch parameter is type-constrained, and
# PowerShell variable names are case-insensitive, so this log text must not be
# assigned to a variable spelled $combined.
$runOutput = "$stdout`n$stderr"
$sessionButtonRecords = New-Object Collections.Generic.List[object]
foreach ($buttonMatch in [regex]::Matches($runOutput, 'CAELESTIA_SESSION_BUTTONS (\[[^\r\n]+\])')) {
    foreach ($button in ($buttonMatch.Groups[1].Value | ConvertFrom-Json)) {
        $sessionButtonRecords.Add($button)
    }
}
$runtimeDiagnostics = $runOutput -match '(?m)^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})?\s*(WARN(?:ING)?|ERROR|FATAL|CRIT(?:ICAL)?)\b'
$passed = -not $timedOut -and -not $runtimeDiagnostics -and
    $process.ExitCode -eq 0 -and $runOutput.Contains("${marker}_PASS") -and
    (Test-Path -LiteralPath $screenshot)
Copy-Item -LiteralPath (Join-Path $stage 'sources.json') -Destination (Join-Path $logRoot "$runName.sources.json")
$result = [ordered]@{
    passed = $(if ($Smoke) { $passed } else { $null }); smoke = $Smoke.IsPresent
    prototype = $kind; combined = $Combined.IsPresent; audioMode = $AudioMode; batteryMode = $BatteryMode; mediaMode = $MediaMode; brightnessMode = $BrightnessMode
    networkMode = $NetworkMode
    bluetoothMode = $BluetoothMode; appsMode = $AppsMode; appsSearchQuery = $(if ($Apps) { $AppsSearchQuery } else { '' })
    trayMode = $TrayMode; trayFixture = $TrayFixture.IsPresent
    trayHookMode = $(if ($Tray) { $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] } else { $null })
    sessionMode = $SessionMode; sessionActions = $SessionActions.IsPresent; notificationsMode = $NotificationsMode
    notificationsMirror = $mirrorMode
    notificationsDismiss = [bool]($mirrorMode -and $NotificationDismiss)
    notificationsAppOpen = [bool]($mirrorMode -and $NotificationAppOpen)
    mirrorSuppressedBySmoke = [bool]($Notifications -and $NotificationsMode -eq 'Mirror' -and $Smoke)
    timedOut = $timedOut; exitCode = $process.ExitCode
    scaleFactor = $ScaleFactor; screenIndex = $ScreenIndex
    monitorCycle = $MonitorCycle.IsPresent
    traceInput = $TraceInput.IsPresent
    actualScreens = @([regex]::Matches($runOutput, "${marker}_SCREEN (\{[^\r\n]+\})") | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
    captures = @([regex]::Matches($runOutput, "${marker}_CAPTURE ([^\r\n]+)") | ForEach-Object { $_.Groups[1].Value })
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
}
foreach ($name in $slices.Keys) {
    $prefix = 'CAELESTIA_' + $name.ToUpperInvariant()
    $result["${name}Snapshots"] = @([regex]::Matches($runOutput, "${prefix}_(INITIAL|FINAL) (\{[^\r\n]+\})") | ForEach-Object {
        [ordered]@{ phase = $_.Groups[1].Value; state = ($_.Groups[2].Value | ConvertFrom-Json) }
    })
}
if ($Brightness) {
    # Route probes are a plain array, not a phase-tagged snapshot.
    $result['brightnessRoutes'] = @([regex]::Matches($runOutput, 'CAELESTIA_BRIGHTNESS_ROUTES (\[[^\r\n]+\])') | ForEach-Object {
        $_.Groups[1].Value | ConvertFrom-Json
    } | ForEach-Object { $_ })
}
$result['appsSearches'] = @([regex]::Matches($runOutput, 'CAELESTIA_APPS_SEARCH (\{[^\r\n]+\})') | ForEach-Object {
    $_.Groups[1].Value | ConvertFrom-Json
})
$result['sessionButtons'] = @($sessionButtonRecords.ToArray())
$result = $result | ConvertTo-Json -Depth 12
$result | Set-Content -LiteralPath (Join-Path $logRoot "$runName.json") -Encoding UTF8
Write-Output $result
if (($Smoke -and -not $passed) -or $process.ExitCode -ne 0) {
    throw "$kind prototype failed. See $stdoutPath and $stderrPath."
}
