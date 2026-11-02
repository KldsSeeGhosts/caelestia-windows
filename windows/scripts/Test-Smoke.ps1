[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$QtPrefix,
    # Advanced: run an already staged production tree instead of staging again.
    # The negative import check uses it; normal runs must omit it.
    [string]$StageRoot,
    [string]$RunRoot,
    [ValidateRange(15, 600)][int]$TimeoutSeconds = 90,
    # Keep the isolated run directory after a pass too.
    [switch]$Keep
)
# Public smoke gate (#228).
#
# Stages the production graph from windows/shell/sources.json with
# Stage-ShellPrototype.ps1 -Prototype shell-live, then starts the built
# quickshell/qs.exe against that stage under an isolated temporary profile:
# config, state, runtime, cache, data, local app data and temp all live under
# the run directory. The shell runs on the offscreen QPA with the Qt Quick
# software backend, every Windows service/control opt-in is off, and smoke mode
# (CAELESTIA_SHELL_SMOKE + CAELESTIA_SHELL_SMOKE_CI) makes it exit itself once
# the drawers have presented their first frame.
#
# It does not install, start the live shell, reserve work area, register
# autostart or hotkeys, read the live profile, or read notification content.
# It fails on a runtime/QML diagnostic, a missing PASS marker or ready state, a
# MAC-like address or quickshell.windows.bluetooth activity in the captured
# logs, or a timeout. Failure output redacts MAC addresses and device paths.
# A pass removes the run directory; a failure keeps it and prints its path.
# Exit code is 0 on pass and 1 on failure.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$QtPrefix = [IO.Path]::GetFullPath($QtPrefix)
if (-not $RunRoot) { $RunRoot = [IO.Path]::GetTempPath() }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
$run = Join-Path $RunRoot ('caelestia-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID)
$profile = Join-Path $run 'profile'
$logRoot = Join-Path $run 'logs'
$passed = $false
$failure = ''
$diagnostics = @()
$state = $null
$exitCode = $null
$timedOut = $false
$elapsed = [Diagnostics.Stopwatch]::StartNew()
$text = ''

try {
    New-Item -ItemType Directory -Force -Path $run, $profile, $logRoot,
        (Join-Path $run 'temp'), (Join-Path $run 'appdata'), (Join-Path $run 'localappdata') | Out-Null
    foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
    }

    $exe = Join-Path $BuildRoot 'quickshell\qs.exe'
    $qmlRoot = Join-Path $BuildRoot 'install\qml'
    $required = @(
        $exe,
        (Join-Path $QtPrefix 'bin\qtpaths.exe'),
        (Join-Path $QtPrefix 'bin\Qt6Core.dll'),
        (Join-Path $qmlRoot 'Caelestia\Config\qmldir'),
        (Join-Path $qmlRoot 'Caelestia\Windows\qmldir'),
        (Join-Path $qmlRoot 'M3Shapes\qmldir'),
        (Join-Path $qmlRoot 'Caelestia\caelestia-coreplugin.dll'),
        (Join-Path $qmlRoot 'Caelestia\Config\caelestia-configplugin.dll'),
        (Join-Path $qmlRoot 'Caelestia\Windows\caelestia-windowsplugin.dll'),
        (Join-Path $qmlRoot 'M3Shapes\m3shapesplugin.dll')
    )
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Build prerequisite missing: $path"
        }
    }
    $lockPath = Join-Path $repoRoot 'windows\sources.lock.json'
    $buildRecordPath = Join-Path $BuildRoot 'logs\build.json'
    if (-not (Test-Path -LiteralPath $buildRecordPath -PathType Leaf)) {
        throw "Build record missing: $buildRecordPath (build with windows/scripts/Build-Prototype.ps1)"
    }
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $buildRecord = Get-Content -LiteralPath $buildRecordPath -Raw | ConvertFrom-Json
    if ([string]$buildRecord.backendRevision -ne [string]$lock.quickshell.revision) {
        throw "Backend pin mismatch: build has $($buildRecord.backendRevision), windows/sources.lock.json pins $($lock.quickshell.revision)."
    }
    if ([string]$buildRecord.m3shapesRevision -ne [string]$lock.m3shapes.revision) {
        throw "M3Shapes pin mismatch: build has $($buildRecord.m3shapesRevision), windows/sources.lock.json pins $($lock.m3shapes.revision)."
    }

    if ($StageRoot) {
        $stage = [IO.Path]::GetFullPath($StageRoot)
        foreach ($name in @('shell.qml', 'sources.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $stage $name) -PathType Leaf)) {
                throw "Staged production tree is incomplete: $(Join-Path $stage $name)"
            }
        }
    } else {
        $stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') `
            -ProfileRoot $profile -Prototype shell-live
        $stage = [IO.Path]::GetFullPath($stage)
        foreach ($name in @('shell.qml', 'sources.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $stage $name) -PathType Leaf)) {
                throw "Staged production tree is incomplete: $(Join-Path $stage $name)"
            }
        }
    }

    # Seed only the profile files these services read. An empty keybind list
    # means the backend registers no global hotkey; false banner replacement
    # keeps the notification helper out of the run.
    '{"binds":[]}' | Set-Content -LiteralPath (Join-Path $profile 'runtime\smoke-keybinds.json') -Encoding UTF8
    '{"windows":{"notifications":{"replaceSystemBanners":false}}}' |
        Set-Content -LiteralPath (Join-Path $profile 'config\windows.json') -Encoding UTF8
    '{"enabled":false}' | Set-Content -LiteralPath (Join-Path $profile 'config\quota.json') -Encoding UTF8

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '--no-color --log-times --path "' + (Join-Path $stage 'shell.qml') + '"'
    $info.WorkingDirectory = $stage
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $environment = $info.EnvironmentVariables
    # Start from a fixed environment: an inherited CAELESTIA_* or QS_* value
    # must never enable a service in the smoke.
    foreach ($name in @($environment.Keys)) {
        if ($name -like 'CAELESTIA_*' -or $name -like 'QS_*' -or
            $name -in @('QT_QPA_PLATFORM', 'QT_QUICK_BACKEND', 'QSG_RHI_BACKEND', 'QML_IMPORT_PATH',
                'QML2_IMPORT_PATH', 'QML_DISK_CACHE_PATH', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME',
                'XDG_DATA_HOME', 'XDG_CACHE_HOME')) {
            $environment.Remove($name)
        }
    }
    $values = [ordered]@{
        'PATH' = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
        'QML_IMPORT_PATH' = "$stage\imports;$qmlRoot;$QtPrefix\qml"
        'QML2_IMPORT_PATH' = "$stage\imports;$qmlRoot;$QtPrefix\qml"
        'QML_DISK_CACHE_PATH' = "$profile\cache"
        'CAELESTIA_CONFIG_DIR' = "$profile\config"
        'CAELESTIA_STATE_DIR' = "$profile\state"
        'CAELESTIA_RUNTIME_DIR' = "$profile\runtime"
        # Quickshell's own run/log bookkeeping otherwise uses the Windows known
        # folder, which ignores LOCALAPPDATA.
        'QS_RUNTIME_DIR' = "$profile\runtime"
        'CAELESTIA_PROFILE_ROOT' = $profile
        'CAELESTIA_WINDOWS_KEYBINDS' = "$profile\runtime\smoke-keybinds.json"
        'XDG_CONFIG_HOME' = "$profile\config"
        'XDG_STATE_HOME' = "$profile\state"
        'XDG_DATA_HOME' = "$profile\data"
        'XDG_CACHE_HOME' = "$profile\cache"
        'LOCALAPPDATA' = "$run\localappdata"
        'APPDATA' = "$run\appdata"
        'TEMP' = "$run\temp"
        'TMP' = "$run\temp"
        'QS_DISABLE_CRASH_HANDLER' = '1'
        'QS_WINDOWS_TRAY_HOOK' = '0'
        'QS_WINDOWS_BLUR' = '0'
        'QT_QPA_PLATFORM' = 'offscreen'
        # The offscreen plugin has no native swapchain; the software backend
        # presents in-process and keeps the run GPU-free.
        'QT_QUICK_BACKEND' = 'software'
        'QT_LOGGING_RULES' = 'quickshell.windows.tracker.debug=false;quickshell.windows.inputmask.debug=false'
        'CAELESTIA_SHELL_SMOKE' = '1'
        'CAELESTIA_SHELL_SMOKE_CI' = '1'
        'CAELESTIA_SHELL_LIVE' = '0'
        'CAELESTIA_COMBINED_LIVE' = '0'
        'CAELESTIA_SHELL_SESSION' = '0'
        'CAELESTIA_SHELL_SESSION_MODE' = 'Disabled'
        'CAELESTIA_SHELL_SCREEN' = '-1'
        'CAELESTIA_SHELL_SCALE' = 'native'
        'CAELESTIA_SHELL_TRACE_INPUT' = '0'
        'CAELESTIA_SHELL_MONITOR_CYCLE' = '0'
        'CAELESTIA_SHELL_SCREENSHOT' = ''
        'CAELESTIA_RUNTIME_PROBE' = '0'
        'CAELESTIA_APPS_SMOKE_QUERY' = ''
        'CAELESTIA_TRAY_FIXTURE' = '0'
        'CAELESTIA_WE_PYTHON' = ''
        'CAELESTIA_WE_DEBUG' = ''
        'CAELESTIA_SCHEME_PYTHON' = ''
        'CAELESTIA_SCHEME_HELPER' = ''
        'CAELESTIA_ACCOUNT_PICTURE' = ''
        'CAELESTIA_WINDOWS_AUDIO' = '0'
        'CAELESTIA_WINDOWS_AUDIO_CONTROLS' = '0'
        'CAELESTIA_WINDOWS_BATTERY' = '0'
        'CAELESTIA_WINDOWS_POWER_PROFILES' = '0'
        'CAELESTIA_WINDOWS_POWER_PROFILE_WRITES' = '0'
        'CAELESTIA_WINDOWS_MEDIA' = '0'
        'CAELESTIA_WINDOWS_MEDIA_CONTROLS' = '0'
        'CAELESTIA_WINDOWS_BRIGHTNESS' = '0'
        'CAELESTIA_WINDOWS_BRIGHTNESS_CONTROLS' = '0'
        'CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE' = '0'
        'CAELESTIA_WINDOWS_NETWORK' = '0'
        'CAELESTIA_WINDOWS_NETWORK_CONTROLS' = '0'
        'CAELESTIA_WINDOWS_HYPR' = '0'
        'CAELESTIA_WINDOWS_HYPR_DISPATCH' = '0'
        'CAELESTIA_WINDOWS_BLUETOOTH' = '0'
        'CAELESTIA_WINDOWS_BLUETOOTH_CONTROLS' = '0'
        'CAELESTIA_WINDOWS_APPS' = '0'
        'CAELESTIA_WINDOWS_APP_LAUNCH' = '0'
        'CAELESTIA_WINDOWS_TRAY' = '0'
        'CAELESTIA_WINDOWS_TRAY_ACTIVATION' = '0'
        'CAELESTIA_WINDOWS_SESSION' = '0'
        'CAELESTIA_WINDOWS_SESSION_ACTIONS' = '0'
        'CAELESTIA_WINDOWS_NOTIFICATIONS' = '0'
        'CAELESTIA_WINDOWS_NOTIFICATION_MIRROR' = '0'
        'CAELESTIA_WINDOWS_NOTIFICATION_MIRROR_DISMISS' = '0'
        'CAELESTIA_WINDOWS_NOTIFICATION_APP_OPEN' = '0'
        'CAELESTIA_WINDOWS_BACKGROUND' = '0'
        'CAELESTIA_WINDOWS_DESKTOP_ICONS' = 'Behind'
        'CAELESTIA_WINDOWS_TILING' = 'off'
        'CAELESTIA_WINDOWS_TILING_OVERRIDE' = '1'
        'CAELESTIA_WINDOWS_TILING_INCLUDED' = ''
        'CAELESTIA_WINDOWS_TILING_EXCLUDED' = ''
        'CAELESTIA_WINDOWS_TILING_INCLUDED_OVERRIDE' = '0'
        'CAELESTIA_WINDOWS_TILING_EXCLUDED_OVERRIDE' = '0'
    }
    foreach ($name in $values.Keys) { $environment[$name] = [string]$values[$name] }

    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try { $process.Kill() } catch { }
        $process.WaitForExit()
    }
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $logRoot 'stdout.log'), $stdout)
    [IO.File]::WriteAllText((Join-Path $logRoot 'stderr.log'), $stderr)

    # Quickshell writes its own text log under QS_RUNTIME_DIR. Include it in the
    # privacy/diagnostic scan and keep a copy with the run artifacts.
    $quickshellLog = ''
    $runtimeRun = Join-Path $profile 'runtime\run'
    if (Test-Path -LiteralPath $runtimeRun) {
        $quickshellLog = (@(Get-ChildItem -LiteralPath $runtimeRun -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object FullName | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
        [IO.File]::WriteAllText((Join-Path $logRoot 'quickshell.log'), $quickshellLog)
    }
    $exitCode = $process.ExitCode
    $text = "$stdout`n$stderr`n$quickshellLog"

    # A public smoke log must never carry a Bluetooth adapter address or device
    # activity. These patterns also redact the failure output below.
    # QS_RUNTIME_DIR is an isolation path, not a containment boundary: it
    # accepts relative, traversal and UNC paths by design.
    $macPattern = '(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])'
    $devicePathPattern = '(?i)\\\\\?\\[^\s"''<>]*'
    $bluetoothPattern = 'quickshell\.windows\.bluetooth'
    $privacyFailure = ''
    if ([regex]::IsMatch($text, $macPattern)) {
        $privacyFailure = 'a MAC-like address appeared in the smoke logs'
    } elseif (@($text -split "`n" | Where-Object { $_ -match $bluetoothPattern }).Count -gt 0) {
        $privacyFailure = 'native Bluetooth adapter/device activity appeared in the smoke logs'
    }
    function Get-SafeLine([string]$line) {
        $line = [regex]::Replace($line, $macPattern, '<redacted-mac>')
        $line = [regex]::Replace($line, $devicePathPattern, '<redacted-device-path>')
        return $line
    }

    # Offscreen QPA emits these two environment warnings of its own. They are
    # not QML diagnostics and are the only lines excluded by name.
    $offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
    function Get-Diagnostics([string]$body) {
        @($body -split "`n" |
            Where-Object { $_ -notmatch $offscreenOnly } |
            Where-Object { $_ -notmatch 'CAELESTIA_SHELL_(SMOKE|LIVE)_(PASS|FAIL)' } |
            Where-Object {
                $_ -match '^\S+ \S+\s+(ERROR|FATAL|CRITICAL)\b' -or
                $_ -match '^\S+ \S+\s+WARN\s+qml:' -or
                $_ -match '\b(TypeError|ReferenceError|SyntaxError|RangeError)\b' -or
                $_ -match 'is not defined|Cannot read property|Unable to assign|Cannot assign to|is not installed|Failed to load component|No such file or directory'
            })
    }
    $diagnostics = @(Get-Diagnostics $text | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim() } | Select-Object -Unique)

    $stateMatch = [regex]::Match($text, 'CAELESTIA_SHELL_LIVE_STATE (\{[^\r\n]+\})')
    if ($stateMatch.Success) {
        try { $state = $stateMatch.Groups[1].Value | ConvertFrom-Json } catch { $state = $null }
    }
    $stateOk = $false
    if ($null -ne $state) {
        $controlsOff = $null -ne $state.controls -and
            @($state.controls.PSObject.Properties | Where-Object { $_.Value -ne $false }).Count -eq 0
        $stateOk = $state.smoke -eq $true -and $state.lifecycle.ready -eq $true -and
            [int]$state.screens -ge 1 -and @($state.windows).Count -eq [int]$state.screens -and
            @($state.backgroundWindows).Count -eq 0 -and $state.tilingMode -eq 'off' -and
            $state.notifications.mirrorActive -eq $false -and
            $state.wallpaperEngine.running -eq $false -and
            -not $state.statisticsActive -and -not $state.networkStatisticsActive -and $controlsOff
    }

    if ($privacyFailure) {
        $failure = $privacyFailure
    } elseif ($timedOut) {
        $failure = "timed out after $TimeoutSeconds s waiting for the smoke to exit"
    } elseif ($exitCode -ne 0) {
        $failure = "qs.exe exited with code $exitCode"
    } elseif (-not $text.Contains('CAELESTIA_SHELL_SMOKE_PASS')) {
        $failure = 'the shell did not report CAELESTIA_SHELL_SMOKE_PASS'
    } elseif ($null -eq $state) {
        $failure = 'the shell did not report its ready state'
    } elseif (-not $stateOk) {
        $failure = 'the shell did not reach a clean ready state'
    } elseif ($diagnostics.Count -gt 0) {
        $failure = "$($diagnostics.Count) runtime/QML diagnostic(s)"
    } else {
        $passed = $true
    }
} catch {
    $failure = $_.Exception.Message
}

$elapsed.Stop()
if ($passed) {
    $screens = [int]$state.screens
    $drawers = @($state.windows).Count
    Write-Output ("PASS Test-Smoke: production graph loaded on $screens screen(s) with $drawers drawer(s), first frame presented, exit 0 in {0:N1} s." -f $elapsed.Elapsed.TotalSeconds)
    if (-not $Keep) {
        Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

Write-Output "FAIL Test-Smoke: $failure"
if ($diagnostics.Count -gt 0) {
    Write-Output 'Relevant diagnostics:'
    $diagnostics | Select-Object -First 25 | ForEach-Object { Write-Output ('  ' + (Get-SafeLine $_)) }
} else {
    Write-Output 'No matched diagnostics; inspect the kept run directory.'
}
Write-Output "Run directory kept: $run"
exit 1
