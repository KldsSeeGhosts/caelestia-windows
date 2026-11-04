[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [string]$RunRoot,
    [string]$ProfileRoot,
    [string]$TilingConfigFile,
    [switch]$Smoke,
    # Renders the smoke on the offscreen QPA with the software backend. This
    # keeps test frames independent of desktop composition, a live shell, and
    # monitor state, and never opens a native window.
    [switch]$Offscreen,
    [switch]$NoThrow,
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
    [switch]$Hypr,
    [ValidateSet('Disabled', 'Observe', 'Dispatch')][string]$HyprMode = 'Disabled',
    [switch]$Tiling,
    [ValidateSet('Disabled', 'Observe', 'Interactive')][string]$TilingMode = 'Disabled',
    [string]$TilingIncluded = '',
    [string]$TilingExcluded = '',
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
    [switch]$Transparency,
    [switch]$Background,
    [ValidateSet('Behind', 'Replace')][string]$DesktopIcons = 'Behind',
    [switch]$RuntimeProbe,
    [switch]$Live,
    [switch]$Takeover,
    [switch]$HideTaskbar,
    [switch]$NoRestartOnCrash,
    # Skips provisioning/using the profile-local Python scheme generator.
    [switch]$SkipSchemeRuntime,
    # Optional Windows-only settings copied to the isolated windows.json.
    [string]$WindowsConfigPath,
    [ValidateSet('native', '1', '1.5', '1.75')][string]$ScaleFactor = 'native',
    [ValidateRange(0, 15)][int]$ScreenIndex = 0
)

$ErrorActionPreference = 'Stop'
# The bounded slice hosts have been retired. Keep the developer preview used
# by source runs and the native integration checks; service fixtures are separate.
if (-not $Combined) {
    throw 'Only -Combined is supported. Use Test-Smoke.ps1 for offscreen production smoke or Test-*Service.ps1 for service fixtures.'
}
if ($MonitorCycle -and (-not $Smoke -or $ScaleFactor -ne 'native')) {
    throw '-MonitorCycle requires -Smoke and native scaling.'
}
if ($Offscreen -and -not $Smoke) { throw '-Offscreen requires -Smoke.' }
if ($Offscreen -and $MonitorCycle) { throw '-Offscreen cannot cycle native monitors.' }
if ($Offscreen -and $ScreenIndex -ne 0) {
    throw '-Offscreen exposes one virtual screen; use -ScreenIndex 0.'
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
    hypr      = @{ On = $Hypr; Mode = $HyprMode; Observe = 'CAELESTIA_WINDOWS_HYPR'; Controls = 'CAELESTIA_WINDOWS_HYPR_DISPATCH'; ControlMode = 'Dispatch' }
    bluetooth = @{ On = $Bluetooth; Mode = $BluetoothMode; Observe = 'CAELESTIA_WINDOWS_BLUETOOTH'; Controls = 'CAELESTIA_WINDOWS_BLUETOOTH_CONTROLS'; ControlMode = 'Interactive' }
    apps      = @{ On = $Apps; Mode = $AppsMode; Observe = 'CAELESTIA_WINDOWS_APPS'; Controls = 'CAELESTIA_WINDOWS_APP_LAUNCH'; ControlMode = 'Interactive' }
    tray      = @{ On = $Tray; Mode = $TrayMode; Observe = 'CAELESTIA_WINDOWS_TRAY'; Controls = 'CAELESTIA_WINDOWS_TRAY_ACTIVATION'; ControlMode = 'Interactive' }
    tiling    = @{ On = $Tiling; Mode = $TilingMode; Custom = $true }
    session   = @{ On = $Session; Mode = $SessionMode; Observe = 'CAELESTIA_WINDOWS_SESSION'; Controls = 'CAELESTIA_WINDOWS_SESSION_ACTIONS'; ControlSwitch = $SessionActions; Stage = 'shell'; Marker = 'CAELESTIA_SHELL' }
    # Mirror mode adds its own opt-ins below; smoke never mirrors.
    notifications = @{ On = $Notifications; Mode = $NotificationsMode; Observe = 'CAELESTIA_WINDOWS_NOTIFICATIONS' }
}
if ($Live -and -not $Combined) { throw '-Live requires -Combined.' }
if ($Background -and -not $Combined) { throw '-Background requires -Combined.' }
if ($DesktopIcons -ne 'Behind' -and -not $Background) { throw '-DesktopIcons requires -Background.' }
# With -Combined, -Tiling adds observation/control rather than another entry point.
if ($RuntimeProbe -and (-not $Combined -or $Live -or $Smoke)) { throw '-RuntimeProbe requires read-only -Combined without -Smoke.' }
$selected = @($slices.Keys | Where-Object { $slices[$_].On -and -not ($Combined -and $_ -eq 'tiling') })
if (($Takeover -or $HideTaskbar -or $NoRestartOnCrash) -and -not $Combined) {
    throw 'Desktop supervision switches require -Combined.'
}
if ($selected.Count -gt 1) { throw 'Select one prototype entry point per run.' }
if ($Combined -and $selected.Count -gt 0) { throw '-Combined cannot be combined with a single-slice entry point.' }
if ($Combined -and $MonitorCycle) { throw 'Only the M1 shell prototype implements monitor cycling.' }
foreach ($name in $slices.Keys) {
    $label = (Get-Culture).TextInfo.ToTitleCase($name)
    if (-not $slices[$name].On -and $slices[$name].Mode -ne 'Disabled') { throw "-${label}Mode requires -$label." }
}
if ($selected.Count -gt 0 -and $MonitorCycle) { throw 'Only the M1 shell prototype implements monitor cycling.' }
if (-not $Apps -and $AppsSearchQuery) { throw '-AppsSearchQuery requires -Apps.' }
if (-not $Tiling -and ($TilingIncluded -or $TilingExcluded)) { throw '-TilingIncluded/-TilingExcluded require -Tiling.' }
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
# BuildRoot supplies binaries only. Stages, profiles and logs belong to this
# checkout, so borrowing another worktree's build never modifies that build.
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot 'windows\.local\build' }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
foreach ($required in @($exe, "$QtPrefix\bin\Qt6Core.dll", "$qmlRoot\Caelestia\Config\qmldir", "$qmlRoot\Caelestia\Windows\qmldir")) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Build prerequisite missing: $required" }
}
$m3ShapesModule = Join-Path $qmlRoot 'M3Shapes'
if ($Combined -and -not (Test-Path -LiteralPath (Join-Path $m3ShapesModule 'qmldir') -PathType Leaf)) {
    throw "The combined shell needs the M3Shapes module: build with windows/scripts/Build-Prototype.ps1 ($m3ShapesModule is missing)."
}
$kind = $(if ($selected.Count -eq 1) { $selected[0] } elseif ($Combined) { 'combined' } else { 'shell' })
$stagePrototype = $(if ($kind -ne 'shell' -and $slices[$kind].Stage) { $slices[$kind].Stage } else { $kind })
$marker = $(if ($kind -ne 'shell' -and $slices[$kind].Marker) { $slices[$kind].Marker } else { 'CAELESTIA_' + $kind.ToUpperInvariant() })
$runName = $kind + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
if (-not $ProfileRoot) { $ProfileRoot = Join-Path $RunRoot "$kind-preview-profile" }
$profileRoot = [IO.Path]::GetFullPath($ProfileRoot)
# A fresh stage avoids stale QML types from a previous implementation.
$stage = & (Join-Path $PSScriptRoot 'Stage-ShellPrototype.ps1') `
    -Destination (Join-Path $RunRoot "shell-runs\$runName") -ProfileRoot $profileRoot -Prototype $stagePrototype
foreach ($dir in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profileRoot $dir) | Out-Null
}
# This dedicated prototype profile intentionally accepts only this audited slice.
# Never read or write ordinary Caelestia configuration.
$config = Join-Path $profileRoot 'config\shell.json'
$tilingSettings = $null
if ($TilingConfigFile) {
    $tilingDocument = Get-Content -LiteralPath $TilingConfigFile -Raw | ConvertFrom-Json
    $tilingSettings = $tilingDocument.windows.tiling
    if ($tilingSettings -isnot [pscustomobject]) { throw '-TilingConfigFile requires a windows.tiling object in shell.json.' }
} elseif (Test-Path -LiteralPath $config) {
    $tilingSettings = (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).windows.tiling
}
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
# Combined enables every adapted bar entry and panel. Service writes require
# -Live; smoke suppresses them. Live also enables native workspace dispatch.
# Tiling has its own explicit switch and mode.
# Hypr-only lock, microphone and keyboard-layout status entries stay disabled.
if ($Combined) {
    $configText = @'
{
  "appearance": {
    "font": {
      "headline": {"family":"Google Sans Flex"},
      "title": {"family":"Google Sans Flex"},
      "body": {"family":"Google Sans Flex"},
      "label": {"family":"Google Sans Flex"}
    }
  },
  "bar": {
    "persistent": true,
    "showOnHover": true,
    "entries": [
      {"id":"logo","enabled":true},
      {"id":"workspaces","enabled":true},
      {"id":"spacer","enabled":true},
      {"id":"activeWindow","enabled":true},
      {"id":"spacer","enabled":true},
      {"id":"tray","enabled":true},
      {"id":"clock","enabled":true},
      {"id":"statusIcons","enabled":true},
      {"id":"power","enabled":true}
    ],
    "clock": {"showIcon":true,"showDate":true,"showSeconds":true},
    "scrollActions": {"workspaces":false,"volume":false,"brightness":false},
    "popouts": {"activeWindow":false,"tray":false,"statusIcons":true},
    "workspaces": {"shown":5,"showUnoccupied":true,"perMonitor":true,"displayType":"Text","showWindows":true},
    "activeWindow": {"showOnHover":false,"compact":false,"inverted":false},
    "statusIcons": [
      {"id":"lockStatus","enabled":false},
      {"id":"audio","enabled":true},
      {"id":"microphone","enabled":false},
      {"id":"kbLayout","enabled":true},
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
  "paths": {"sessionGif":"root:/assets/kurukuru.gif"},
  "dashboard": {"enabled":true,"showOnHover":true},
  "launcher": {"enabled":true,"showOnHover":true},
  "sidebar": {"enabled":true,"showOnHover":true},
  "osd": {"enabled":true},
  "utilities": {"enabled":true,"cards":{"keepAwake":true,"recorder":true,"quickToggles":true},"quickToggles":[{"id":"wifi","enabled":true},{"id":"bluetooth","enabled":true},{"id":"mic","enabled":true},{"id":"dnd","enabled":true},{"id":"settings","enabled":true}]}
}
'@
}
# Hypr runs stage the original bar workspace and active-window components. The
# original Text display type keeps workspace labels legible.
# Per-monitor workspace ownership stays unclaimed, so
# perMonitor keeps the upstream default while showUnoccupied keeps the five
# configured slots visible on both monitors.
if ($Hypr) {
    $configObject = $configText | ConvertFrom-Json
    $configObject.bar | Add-Member -NotePropertyName workspaces -NotePropertyValue ([pscustomobject]@{
        shown = 5
        showUnoccupied = $true
        perMonitor = $true
        displayType = 'Text'
        showWindows = $true
    }) -Force
    $configObject.bar | Add-Member -NotePropertyName activeWindow -NotePropertyValue ([pscustomobject]@{
        showOnHover = $false
        compact = $false
        inverted = $false
    }) -Force
    $configText = $configObject | ConvertTo-Json -Depth 10
}
if ($Combined -and $Live) {
    $configText = $configText.Replace(
        '"commands": {"logout":[],"shutdown":[],"hibernate":[],"reboot":[]}',
        '"commands": {"logout":["logout"],"shutdown":["shutdown"],"hibernate":["hibernate"],"reboot":["reboot"]}')
    $configText = $configText.Replace(
        '"scrollActions": {"workspaces":false,"volume":false,"brightness":false}',
        '"scrollActions": {"workspaces":true,"volume":false,"brightness":false}')
}
if ($Combined) {
    $configObject = $configText | ConvertFrom-Json
    $configObject | Add-Member -NotePropertyName background -NotePropertyValue ([pscustomobject]@{
        enabled = $Background.IsPresent
        wallpaperEnabled = $true
        desktopClock = [pscustomobject]@{ enabled = $false; position = 'bottom-right' }
        visualiser = [pscustomobject]@{ enabled = $false }
    }) -Force
    $configText = $configObject | ConvertTo-Json -Depth 10
}
if ($Combined) {
    # Supervisor-only settings stay separate from upstream's compiled Qt
    # configuration schema, including when reusing an older portable build.
    $takeoverConfig = Join-Path $profileRoot 'config\windows.json'
    $platformOptions = if ($WindowsConfigPath) {
        (Get-Content -LiteralPath $WindowsConfigPath -Raw | ConvertFrom-Json).windows
    } elseif (Test-Path -LiteralPath $takeoverConfig) {
        (Get-Content -LiteralPath $takeoverConfig -Raw | ConvertFrom-Json).windows
    } else { [pscustomobject]@{} }
    $platformOptions | Add-Member -NotePropertyName hideTaskbar -NotePropertyValue $HideTaskbar.IsPresent -Force
    $platformOptions | Add-Member -NotePropertyName restartOnCrash -NotePropertyValue (-not $NoRestartOnCrash.IsPresent) -Force
    @{ windows = $platformOptions } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $takeoverConfig -Encoding UTF8
}
if ($null -ne $tilingSettings) {
    $configObject = $configText | ConvertFrom-Json
    $configObject | Add-Member -NotePropertyName windows -NotePropertyValue ([pscustomobject]@{ tiling = $tilingSettings }) -Force
    $configText = $configObject | ConvertTo-Json -Depth 20
}
if ($Transparency) {
    $configObject = $configText | ConvertFrom-Json
    if (-not $configObject.appearance) {
        $configObject | Add-Member -NotePropertyName appearance -NotePropertyValue ([pscustomobject]@{})
    }
    $configObject.appearance | Add-Member -NotePropertyName transparency `
        -NotePropertyValue ([pscustomobject]@{ enabled = $true }) -Force
    $configText = $configObject | ConvertTo-Json -Depth 10
}
$configText | Set-Content -LiteralPath $config -Encoding UTF8
if ($Notifications) {
    # Banner policy lives in windows.json, which the real install always ships.
    # An isolated profile without it makes Notifs.qml log a load warning, and
    # the smoke rejects any runtime warning as a failure.
    $windowsConfig = Join-Path $profileRoot 'config\windows.json'
    if (-not (Test-Path -LiteralPath $windowsConfig)) {
        '{"windows":{"notifications":{}}}' | Set-Content -LiteralPath $windowsConfig -Encoding UTF8
    }
}
$logRoot = Join-Path $RunRoot 'logs'
# Dynamic colours: the combined prototype uses the real caelestia CLI scheme
# generator from a profile-local virtual environment. Provisioning is
# idempotent; a failure leaves the shell on its fixed palette.
$schemeRuntime = $null
if ($Combined -and -not $SkipSchemeRuntime) {
    try {
        $installOutput = & (Join-Path $PSScriptRoot 'Install-SchemeRuntime.ps1') -ProfileRoot $profileRoot
        $schemeRuntime = $installOutput | Select-Object -Last 1
        if ($schemeRuntime -is [string]) {
            try { $schemeRuntime = $schemeRuntime | ConvertFrom-Json } catch { $schemeRuntime = $null }
        }
    } catch {
        Write-Warning "Scheme runtime provisioning failed: $($_.Exception.Message)"
        $schemeRuntime = $null
    }
}
$schemeAvailable = $null -ne $schemeRuntime -and $schemeRuntime.available -eq $true
$logRoot = Join-Path $RunRoot 'logs'
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
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$m3ShapesModule;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $profileRoot 'cache'
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = Join-Path $profileRoot 'config'
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = Join-Path $profileRoot 'state'
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = Join-Path $profileRoot 'runtime'
# Keep the scheme bridge (and any inherited CLI call) inside the prototype
# profile. The bridge also enforces CAELESTIA_PROFILE_ROOT itself.
if ($Combined) {
    $info.EnvironmentVariables['CAELESTIA_PROFILE_ROOT'] = $profileRoot
    $info.EnvironmentVariables['XDG_CONFIG_HOME'] = Join-Path $profileRoot 'config'
    $info.EnvironmentVariables['XDG_STATE_HOME'] = Join-Path $profileRoot 'state'
    $info.EnvironmentVariables['XDG_DATA_HOME'] = Join-Path $profileRoot 'data'
    $info.EnvironmentVariables['XDG_CACHE_HOME'] = Join-Path $profileRoot 'cache'
}
$info.EnvironmentVariables['CAELESTIA_SCHEME_PYTHON'] = $(if ($schemeAvailable) { [string]$schemeRuntime.python } else { '' })
$info.EnvironmentVariables['CAELESTIA_SCHEME_HELPER'] = $(if ($schemeAvailable) { [string]$schemeRuntime.helper } else { '' })
$wePython = if ($schemeAvailable) { [string]$schemeRuntime.python } else {
    # Discovery uses only the standard library and remains available when the
    # user opts out of the Material scheme runtime.
    $pythonLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pythonLauncher) { & $pythonLauncher.Source -3 -c 'import sys; print(sys.executable)' }
}
$info.EnvironmentVariables['CAELESTIA_WE_PYTHON'] = [string]$wePython
if ($Combined) {
    $info.EnvironmentVariables['CAELESTIA_ACCOUNT_PICTURE'] = & "$PSScriptRoot\Get-AccountPicture.ps1" `
        -CacheRoot (Join-Path $profileRoot 'cache')
}
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
if ($Offscreen) {
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    # The offscreen plugin has no native swapchain; the software backend
    # presents in-process, so grabToImage completes without DWM or vsync.
    $info.EnvironmentVariables['QT_QUICK_BACKEND'] = 'software'
    $info.EnvironmentVariables['QSG_NO_VSYNC'] = '1'
    # The software scene graph is not safe to tear down while its threaded
    # render loop is rendering. The basic loop renders on the GUI thread, so a
    # panel close or popout unload cannot race an in-flight render.
    $info.EnvironmentVariables['QSG_RENDER_LOOP'] = 'basic'
}
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
    if ($slice.Custom) { continue }
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
# Explicit switches override environment, which overrides shell.json.
# The facade enforces the smoke downgrade for config and env alike.
$tilingEnvMode = $env:CAELESTIA_WINDOWS_TILING
if ($Tiling) {
    $tilingEnvMode = $(if ($TilingMode -eq 'Disabled') { 'off' } else { $TilingMode.ToLowerInvariant() })
}
if (-not $Combined -and -not $Tiling) { $tilingEnvMode = 'off' }
if ($Smoke -and $tilingEnvMode -eq 'interactive') { $tilingEnvMode = 'observe' }
$info.EnvironmentVariables['CAELESTIA_WINDOWS_TILING'] = [string]$tilingEnvMode
$info.EnvironmentVariables['CAELESTIA_WINDOWS_TILING_OVERRIDE'] = $(if ($Tiling) { '1' } else { '0' })
foreach ($field in @('Included', 'Excluded')) {
    $variable = 'CAELESTIA_WINDOWS_TILING_' + $field.ToUpperInvariant()
    $explicit = $PSBoundParameters.ContainsKey("Tiling$field")
    $value = $(if ($explicit) { Get-Variable -Name "Tiling$field" -ValueOnly } else { [Environment]::GetEnvironmentVariable($variable) })
    $info.EnvironmentVariables[$variable] = [string]$value
    $info.EnvironmentVariables[$variable + '_OVERRIDE'] = $(if ($explicit) { '1' } else { '0' })
}
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
# Combined observes every reviewed facade. Live enables service controls and
# tray interception outside smoke; notification consent remains user-initiated.
# Software gamma remains a separate unsupported route in this host.
if ($Combined) {
    foreach ($name in $slices.Keys) {
        # Tiling is a Custom slice with a mode word rather than an Observe pair;
        # the explicit tiling block above handles its separate mode.
        if ($slices[$name].Custom) { continue }
        $info.EnvironmentVariables[$slices[$name].Observe] = '1'
        if ($slices[$name].Controls) { $info.EnvironmentVariables[$slices[$name].Controls] = $(if ($Live -and -not $Smoke) { '1' } else { '0' }) }
    }
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_POWER_PROFILES'] = '1'
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE'] = '0'
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_MIRROR'] = $(if ($Live -and -not $Smoke) { '1' } else { '0' })
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_MIRROR_DISMISS'] = $(if ($Live -and -not $Smoke) { '1' } else { '0' })
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_NOTIFICATION_APP_OPEN'] = $(if ($Live -and -not $Smoke) { '1' } else { '0' })
    $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = $(if ($Live -and -not $Smoke) { '1' } else { '0' })
    $info.EnvironmentVariables['CAELESTIA_SHELL_SESSION'] = '1'
    $info.EnvironmentVariables['CAELESTIA_SHELL_SESSION_MODE'] = 'Observe'
    $info.EnvironmentVariables['CAELESTIA_COMBINED_LIVE'] = $(if ($Live) { '1' } else { '0' })
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_BACKGROUND'] = $(if ($Background) { '1' } else { '0' })
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_DESKTOP_ICONS'] = $DesktopIcons
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
if ($Smoke) {
    $emptyKeys = Join-Path $profileRoot 'runtime\smoke-keybinds.json'
    '{"binds":[]}' | Set-Content -LiteralPath $emptyKeys -Encoding UTF8
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_KEYBINDS'] = $emptyKeys
}
$info.EnvironmentVariables['CAELESTIA_RUNTIME_PROBE'] = $(if ($RuntimeProbe) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_SHELL_MONITOR_CYCLE'] = $(if ($MonitorCycle) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_SHELL_SCREENSHOT'] = ([Uri]$screenshot).AbsoluteUri
$info.RedirectStandardOutput = $Smoke.IsPresent -or $Wait.IsPresent
$info.RedirectStandardError = $Smoke.IsPresent -or $Wait.IsPresent

$elapsed = [Diagnostics.Stopwatch]::StartNew()
$supervised = $null
if ($Takeover -or $HideTaskbar) {
    $supervised = & (Join-Path $PSScriptRoot 'Start-DesktopShell.ps1') -StartInfo $info `
        -StateDirectory (Join-Path $profileRoot "runtime\$runName-takeover") -ConfigPath $takeoverConfig `
        -StdoutPath $stdoutPath -StderrPath $stderrPath
    $process = $supervised.Watchdog
} else {
    $process = [Diagnostics.Process]::Start($info)
}
if (-not $Smoke -and -not $Wait) {
    if ($supervised) {
        Write-Output "Started supervised $kind prototype. Status: $($supervised.StatusPath)"
        Write-Output "Recovery: powershell -NoProfile -File `"$PSScriptRoot\Restore-Desktop.ps1`""
        return
    }
    Write-Output "Started isolated $kind prototype (PID $($process.Id))."
    Write-Output "Staged source: $stage"
    Write-Output "Stop only this process when finished: Stop-Process -Id $($process.Id)"
    return
}
if (-not $supervised) {
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
}
$timedOut = $false
if ($Smoke) {
    $timedOut = -not $process.WaitForExit(60000)
} else {
    Write-Output "Started isolated $kind prototype (PID $($process.Id)); capturing logs until it exits."
    Write-Output "Staged source: $stage"
    $process.WaitForExit()
}
if ($timedOut) {
    if ($supervised) {
        & (Join-Path $PSScriptRoot 'Restore-Desktop.ps1') | Out-Null
    } else {
        $process.Kill()
    }
    $process.WaitForExit()
}
if ($supervised) {
    $supervisorStatus = Get-Content -LiteralPath $supervised.StatusPath -Raw | ConvertFrom-Json
    $exitCode = if ($supervisorStatus.phase -in @('clean-exit', 'recovered', 'crash-give-up', 'watchdog-error')) {
        $supervisorStatus.exitCode
    } else { 1 }
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { [IO.File]::ReadAllText($stdoutPath) } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { [IO.File]::ReadAllText($stderrPath) } else { '' }
} else {
    $exitCode = $process.ExitCode
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
}
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
$diagnosticOutput = $runOutput
if ($Offscreen) {
    # The offscreen QPA has no font directory of its own and cannot set a
    # native window mask. Both warnings come from the platform plugin, not
    # from the shell, and would otherwise reject every offscreen pass.
    $offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
    $diagnosticOutput = (@($runOutput -split "`n" | Where-Object { $_ -notmatch $offscreenOnly }) -join "`n")
}
$runtimeDiagnostics = $diagnosticOutput -match '(?m)^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})?\s*(WARN(?:ING)?|ERROR|FATAL|CRIT(?:ICAL)?)\b'
$passed = -not $timedOut -and -not $runtimeDiagnostics -and
    $exitCode -eq 0 -and $runOutput.Contains("${marker}_PASS") -and
    (Test-Path -LiteralPath $screenshot)
Copy-Item -LiteralPath (Join-Path $stage 'sources.json') -Destination (Join-Path $logRoot "$runName.sources.json")
$result = [ordered]@{
    passed = $(if ($Smoke) { $passed } else { $null }); smoke = $Smoke.IsPresent
    offscreen = $Offscreen.IsPresent
    prototype = $kind; combined = $Combined.IsPresent; live = $Live.IsPresent
    background = $Background.IsPresent; desktopIcons = $DesktopIcons
    audioMode = $AudioMode; batteryMode = $BatteryMode; mediaMode = $MediaMode; brightnessMode = $BrightnessMode
    networkMode = $NetworkMode
    hyprMode = $HyprMode
    tilingMode = $TilingMode; tilingEnvMode = $tilingEnvMode
    tilingIncluded = $(if ($Tiling) { $TilingIncluded } else { '' })
    tilingExcluded = $(if ($Tiling) { $TilingExcluded } else { '' })
    bluetoothMode = $BluetoothMode; appsMode = $AppsMode; appsSearchQuery = $(if ($Apps) { $AppsSearchQuery } else { '' })
    trayMode = $TrayMode; trayFixture = $TrayFixture.IsPresent
    trayHookMode = $(if ($Tray) { $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] } else { $null })
    sessionMode = $SessionMode; sessionActions = $SessionActions.IsPresent; notificationsMode = $NotificationsMode
    notificationsMirror = $mirrorMode
    notificationsDismiss = [bool]($mirrorMode -and $NotificationDismiss)
    notificationsAppOpen = [bool]($mirrorMode -and $NotificationAppOpen)
    mirrorSuppressedBySmoke = [bool]($Notifications -and $NotificationsMode -eq 'Mirror' -and $Smoke)
    timedOut = $timedOut; exitCode = $exitCode
    scaleFactor = $ScaleFactor; screenIndex = $ScreenIndex
    monitorCycle = $MonitorCycle.IsPresent
    traceInput = $TraceInput.IsPresent
    schemeRuntime = $schemeAvailable
    schemeRuntimeMessage = $(if ($null -ne $schemeRuntime) { [string]$schemeRuntime.message } else { '' })
    schemeCliRevision = $(if ($schemeAvailable) { [string]$schemeRuntime.revision } else { '' })
    actualScreens = @([regex]::Matches($runOutput, "${marker}_SCREEN (\{[^\r\n]+\})") | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
    captures = @([regex]::Matches($runOutput, "${marker}_CAPTURE ([^\r\n]+)") | ForEach-Object { $_.Groups[1].Value })
    elapsedMilliseconds = $elapsed.ElapsedMilliseconds
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (Get-Content -LiteralPath (Join-Path $BuildRoot 'logs\build.json') -Raw | ConvertFrom-Json).backendRevision
    buildRecordSha256 = (Get-FileHash -LiteralPath (Join-Path $BuildRoot 'logs\build.json')).Hash
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
if (-not $NoThrow -and (($Smoke -and -not $passed) -or $exitCode -ne 0)) {
    throw "$kind prototype failed. See $stdoutPath and $stderrPath."
}
