[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot,
    [ValidateSet('configured', 'states', 'offline', 'unconfigured', 'disabled', 'keepalive')]
    [string[]]$Modes = @('configured', 'states', 'offline', 'unconfigured', 'disabled', 'keepalive'),
    # Drawer sizes as "<width>x<height>". configured runs every size, states
    # runs the sizes at least 400 high, offline, unconfigured and disabled use the first.
    [ValidatePattern('^\d+x\d+$')]
    [string[]]$Geometries = @('384x520', '280x520', '280x300'),
    # Optional guard: refuse to run unless qs.exe has this SHA-256.
    [string]$ExpectedQsSha256
)
# Offscreen CPA quota smoke. Stages the production graph, then runs
# windows/quota/QuotaSmoke.qml in isolated profiles:
#
#   configured    a synthetic local CPA Manager stub serves the pre-aggregated
#                 quota summary; the drawer opens on All Usage with a Priority |
#                 All Usage switch, one section per provider on a shared column
#                 grid (bars, % and resets line up), per-provider spend rows and
#                 a floating footer; it then switches to Priority (least left
#                 first), opens the footer menu and saves dark, light, Priority
#                 and menu screenshots. It runs at the 384x520 default, the 280
#                 minimum width and a short 280x300 drawer;
#   states        a second synthetic scenario: a very long account name, 0% left
#                 (error colour), stale, reconnect, disabled and unreported
#                 accounts, Cursor API/Auto windows and a monthly-only provider.
#                 Each section is checked for reported windows only (no invented
#                 5-hour or weekly limit) and for overflow, and screenshotted;
#   offline       the CPA endpoint refuses connections; with the configured
#                 run's cached summary the saved reading stays visible behind
#                 one friendly error, and the run must settle without hanging;
#   unconfigured  no cpa-agents.json exists; no request is made and the drawer
#                 stays disabled;
#   disabled      a valid CPA config with "Agent usage panel" off
#                 (windows.quota.enabled in shell.json): the drawer never opens,
#                 its input region is empty and the service makes no request.
#                 Switching it on, off and on again at runtime opens, closes and
#                 quiets the drawer live and keeps the cache;
#   keepalive     a fake Keepalive helper (a real Python process, swapped in for
#                 the staged script) reports progress, then would write a marker
#                 file after a delay. The panel is switched off meanwhile: the
#                 helper process must be gone and the marker never written.
## It never contacts a real CPA or upstream provider, uses no credentials, takes
# no pointer input and never touches the live desktop.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $env:TEMP 'caelestia-quota-smoke' }
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot (Join-Path $run 'stage-profile') -Prototype shell-live
Copy-Item -LiteralPath "$repoRoot\windows\quota\fixtures\light-scheme.json" -Destination "$stage\quota-light-scheme.json"

$python = (& py -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1)
if (-not $python -or -not (Test-Path -LiteralPath $python)) {
    $python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
}
if (-not $python) { throw 'Python is required for the synthetic quota stub.' }
$python = [IO.Path]::GetFullPath($python)
$stubScript = Join-Path $repoRoot 'windows\quota\fixtures\stub_cpa.py'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
foreach ($required in @($exe, "$qmlRoot\Caelestia\Config\qmldir", "$qmlRoot\Caelestia\Windows\qmldir", $stubScript, "$stage\quota-light-scheme.json")) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing quota smoke prerequisite: $required" }
}

# Check the Qt bootstrap before anything starts: no qt.conf beside qs.exe, and
# the offscreen platform plugin and QtCore from the same 6.11.2 prefix. A
# mismatch stops here; nothing retries with guessed plugin paths.
if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $exe) 'qt.conf')) {
    throw 'qt.conf sits beside qs.exe and would redirect the Qt plugins.'
}
foreach ($binary in @("$QtPrefix\plugins\platforms\qoffscreen.dll", "$QtPrefix\bin\Qt6Core.dll")) {
    if (-not (Test-Path -LiteralPath $binary)) { throw "Missing Qt binary: $binary" }
    $version = (Get-Item -LiteralPath $binary).VersionInfo.FileVersion
    if ($version -notlike '6.11.2*') { throw "Unexpected Qt version $version for $binary" }
}
if ($ExpectedQsSha256 -and (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $ExpectedQsSha256) {
    throw "qs.exe does not match the expected SHA-256 ($exe)."
}
# The staged entry carries the isolated profile-directory pragmas; the smoke
# host copy below must keep all three.
$stageShell = [IO.File]::ReadAllText("$stage\shell.qml")
$pragmaPattern = '(?m)^//@ pragma (?:DataDir|StateDir|CacheDir) [^\r\n]+'
if ([regex]::Matches($stageShell, $pragmaPattern).Count -ne 3) { throw 'Expected three isolated profile-directory pragmas in the staged entry.' }

$offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
# The banner helper belongs to the host install, not this isolated stage. Its
# missing-settings warning is unrelated to the quota graph.
$hostOnly = 'Caelestia banner settings could not be read'
function Get-Diagnostics([string]$Body) {
    @($Body -split "`n" |
        Where-Object { $_ -match '^\S+ \S+\s+(WARN|ERROR|FATAL|CRITICAL)\b' } |
        Where-Object { $_ -notmatch $offscreenOnly -and $_ -notmatch $hostOnly })
}

# Windows PowerShell 5.1's -Encoding UTF8 writes a BOM, which Python's JSON
# reader rejects. Write the profile files without one.
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Start-Stub([string]$Root, [string]$Scenario = 'default') {
    $portFile = Join-Path $Root 'stub-port.txt'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $python
    # Windows PowerShell 5.1 has no ProcessStartInfo.ArgumentList; quote the
    # two paths explicitly instead.
    $info.Arguments = '"{0}" --port 0 --port-file "{1}" --scenario {2}' -f $stubScript, $portFile, $Scenario
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $null = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $portFile); $i++) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $portFile)) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        throw "CPA stub did not start: $($errTask.GetAwaiter().GetResult())"
    }
    $port = (Get-Content -LiteralPath $portFile -Raw).Trim()
    return [pscustomobject]@{
        Process = $process; Port = $port; BaseUrl = "http://127.0.0.1:$port"
    }
}

$script:configuredCache = $null

function Invoke-QuotaSmoke([string]$Mode, [string]$Geometry) {
    $modeRoot = Join-Path $run "$Mode-$Geometry"
    $profile = Join-Path $modeRoot 'profile'
    foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data', 'tmp', 'home\AppData\Roaming', 'home\AppData\Local')) {
        New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
    }
    $width, $height = $Geometry -split 'x'
    # Keep the bar wrapper's Loader inactive; the quota drawer is the subject.
    # The disabled mode also switches the Nexus "Agent usage panel" setting off.
    $shellJson = if ($Mode -eq 'disabled') { '{"bar":{"persistent":false},"windows":{"quota":{"enabled":false}}}' } else { '{"bar":{"persistent":false}}' }
    Write-Utf8NoBom "$profile\config\shell.json" $shellJson
    # The replacement entry keeps all three directory pragmas, pointed at this
    # run's own profile, so Quickshell's data, state and cache dirs stay inside it.
    $header = @("DataDir $profile\data", "StateDir $profile\state", "CacheDir $profile\cache") |
        ForEach-Object { "//@ pragma $_" }
    $entry = Join-Path $stage "quota-smoke-$Mode-$Geometry.qml"
    [IO.File]::WriteAllText($entry, (($header -join "`n") + "`n" + [IO.File]::ReadAllText("$repoRoot\windows\quota\QuotaSmoke.qml")),
        (New-Object Text.UTF8Encoding($false)))
    if ([regex]::Matches([IO.File]::ReadAllText($entry), $pragmaPattern).Count -ne 3) { throw 'Smoke entry lost a profile-directory pragma.' }

    $stub = $null
    $baseUrl = ''
    $savedCache = $false
    $cachePath = Join-Path $profile 'cache\quota-summary.json'
    try {
        if ($Mode -eq 'configured' -or $Mode -eq 'states' -or $Mode -eq 'disabled' -or $Mode -eq 'keepalive') {
            $stub = Start-Stub $modeRoot $(if ($Mode -eq 'states') { 'states' } else { 'default' })
            $baseUrl = $stub.BaseUrl
        } elseif ($Mode -eq 'offline') {
            # Port 9 is discard; a local connection is refused immediately.
            $baseUrl = 'http://127.0.0.1:9'
            # Reuse the configured run's last good summary when it exists, so
            # this mode exercises both the error line and the saved reading.
            if ($script:configuredCache -and (Test-Path -LiteralPath $script:configuredCache)) {
                Copy-Item -LiteralPath $script:configuredCache -Destination $cachePath
                $savedCache = $true
            }
        }
        if ($Mode -ne 'unconfigured') {
            Write-Utf8NoBom "$profile\config\quota.json" ('{{"enabled":true,"refreshIntervalMs":600000,"geometry":{{"width":{0},"height":{1}}}}}' -f $width, $height)
            $configJson = [ordered]@{ baseUrl = $baseUrl; adminKey = 'smoke-placeholder' } | ConvertTo-Json
            Write-Utf8NoBom "$profile\config\cpa-agents.json" $configJson
        }

        $fakeDir = Join-Path $modeRoot 'fake-helper'
        if ($Mode -eq 'keepalive') {
            New-Item -ItemType Directory -Force $fakeDir | Out-Null
            $fakeScript = Join-Path $stage 'scripts\cpa_keepalive.py'
            if (-not (Test-Path -LiteralPath $fakeScript)) { throw "Staged keepalive helper not found: $fakeScript" }
            # Stand-in for the helper: one progress line, then a marker file after
            # three seconds. It sends no request and reads no credentials.
            $fakeBody = @(
                'import json, os, time',
                ('d = r"{0}"' -f $fakeDir),
                'open(os.path.join(d, "pid.txt"), "w").write(str(os.getpid()))',
                'print(json.dumps({"type": "progress", "done": 1, "total": 7}), flush=True)',
                'time.sleep(3)',
                'open(os.path.join(d, "late.txt"), "w").write("late")'
            ) -join "`n"
            Write-Utf8NoBom $fakeScript $fakeBody
        }
        $screenshot = Join-Path $modeRoot 'quota.png'
        $lightScreenshot = Join-Path $modeRoot 'quota-light.png'
        $priorityScreenshot = Join-Path $modeRoot 'quota-priority.png'
        $menuScreenshot = Join-Path $modeRoot 'quota-menu.png'
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $exe
        $info.Arguments = '--no-color --log-times --path "' + $entry + '"'
        $info.WorkingDirectory = $stage
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # Start from nothing inherited that could steer the shell: drop every
        # CAELESTIA_* and QS_WINDOWS_* value, then set only what this run owns.
        # Path overrides are removed, not set to 0; the gates below are switched off.
        foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_*' -or $_ -like 'QS_WINDOWS_*' })) {
            $info.EnvironmentVariables.Remove($variable)
        }
        $system32 = Join-Path $env:SystemRoot 'System32'
        $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$system32;$env:SystemRoot"
        $info.EnvironmentVariables['QT_PLUGIN_PATH'] = "$QtPrefix\plugins"
        $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
        $info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
        # Temp and user-profile locations stay inside this run's profile.
        foreach ($name in @('TEMP', 'TMP')) { $info.EnvironmentVariables[$name] = "$profile\tmp" }
        $info.EnvironmentVariables['USERPROFILE'] = "$profile\home"
        $info.EnvironmentVariables['HOME'] = "$profile\home"
        $info.EnvironmentVariables['APPDATA'] = "$profile\home\AppData\Roaming"
        $info.EnvironmentVariables['LOCALAPPDATA'] = "$profile\home\AppData\Local"
        $info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
        $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
        $info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
        $info.EnvironmentVariables['CAELESTIA_CACHE_DIR'] = "$profile\cache"
        $info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
        $info.EnvironmentVariables['CAELESTIA_PROFILE_ROOT'] = $profile
        $info.EnvironmentVariables['XDG_CONFIG_HOME'] = "$profile\config"
        $info.EnvironmentVariables['XDG_STATE_HOME'] = "$profile\state"
        $info.EnvironmentVariables['XDG_CACHE_HOME'] = "$profile\cache"
        $info.EnvironmentVariables['XDG_DATA_HOME'] = "$profile\data"
        if ($Mode -eq 'keepalive') { $info.EnvironmentVariables['CAELESTIA_QUOTA_PYTHON'] = $python }
        $info.EnvironmentVariables['CAELESTIA_QUOTA_SMOKE_MODE'] = $Mode
        $info.EnvironmentVariables['CAELESTIA_QUOTA_SMOKE_GEOMETRY'] = $Geometry
        $info.EnvironmentVariables['CAELESTIA_QUOTA_PRIORITY_SCREENSHOT'] = ([Uri]$priorityScreenshot).AbsoluteUri
        $info.EnvironmentVariables['CAELESTIA_QUOTA_MENU_SCREENSHOT'] = ([Uri]$menuScreenshot).AbsoluteUri
        $info.EnvironmentVariables['CAELESTIA_QUOTA_SMOKE_SAVED'] = $(if ($savedCache) { '1' } else { '0' })
        $info.EnvironmentVariables['CAELESTIA_QUOTA_LIGHT_SCHEME'] = "$stage\quota-light-scheme.json"
        $info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = '1'
        $info.EnvironmentVariables['CAELESTIA_SHELL_SCREEN'] = '0'
        $info.EnvironmentVariables['CAELESTIA_SHELL_SCALE'] = 'native'
        $info.EnvironmentVariables['CAELESTIA_SHELL_SCREENSHOT'] = ([Uri]$screenshot).AbsoluteUri
        $info.EnvironmentVariables['CAELESTIA_QUOTA_LIGHT_SCREENSHOT'] = ([Uri]$lightScreenshot).AbsoluteUri
        $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
        $info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
        $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
        $info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'

        $process = [Diagnostics.Process]::Start($info)
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit(90000)
        if ($timedOut) { $process.Kill(); $process.WaitForExit() }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $stdoutPath = Join-Path $modeRoot 'stdout.log'
        $stderrPath = Join-Path $modeRoot 'stderr.log'
        $stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
        $stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8
        $text = "$stdout`n$stderr"
        $diagnostics = Get-Diagnostics $text
        $passed = -not $timedOut -and $process.ExitCode -eq 0 -and
            $text.Contains("CAELESTIA_QUOTA_SMOKE_PASS $Mode") -and
            $diagnostics.Count -eq 0

        $cacheProviders = 0
        $cacheText = ''
        if (Test-Path -LiteralPath $cachePath) {
            $cacheText = Get-Content -LiteralPath $cachePath -Raw
            try { $cacheProviders = @((ConvertFrom-Json $cacheText).providers).Count } catch { $cacheProviders = -1 }
        }
        $cacheLeaks = $cacheText -match 'adminKey|baseUrl|smoke-placeholder|@'

        $helperGone = $true
        if ($Mode -eq 'keepalive') {
            # The smoke stayed alive past the helper's delay, so a helper that kept
            # running after the panel went off has written its marker by now.
            $helperPid = 0
            $pidFile = Join-Path $fakeDir 'pid.txt'
            if (Test-Path -LiteralPath $pidFile) { $helperPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim() }
            if ($helperPid -gt 0) {
                $helper = Get-Process -Id $helperPid -ErrorAction SilentlyContinue
                if ($helper) { $helper.Kill(); $helper.WaitForExit() }
            }
            $helperGone = $helperPid -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $fakeDir 'late.txt'))
        }

        if ($Mode -eq 'configured') {
            if (Test-Path -LiteralPath $cachePath) { $script:configuredCache = $cachePath }
            $passed = $passed -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_SUMMARY .*"status":"ok"' -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_SUMMARY .*"providers":5' -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_SUMMARY .*"groups":3' -and
                $text -match '"claudeLimits":3' -and $text -match '"scoped":1' -and
                $text -match '"todayCostUsd":3.71' -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_OPEN .*"mode":"configured"' -and
                # OpenUsage's rule: the windows at 30% left or less (7, 12, 29), least left first.
                $text -match 'CAELESTIA_QUOTA_SMOKE_PRIORITY .*"rows":3,"left":"7,12,29"' -and
                (Test-Path -LiteralPath $screenshot) -and (Get-Item -LiteralPath $screenshot).Length -gt 0 -and
                (Test-Path -LiteralPath $priorityScreenshot) -and (Get-Item -LiteralPath $priorityScreenshot).Length -gt 0 -and
                (Test-Path -LiteralPath $menuScreenshot) -and (Get-Item -LiteralPath $menuScreenshot).Length -gt 0 -and
                (Test-Path -LiteralPath $lightScreenshot) -and (Get-Item -LiteralPath $lightScreenshot).Length -gt 0 -and                $cacheProviders -eq 5 -and -not $cacheLeaks
        } elseif ($Mode -eq 'states') {
            $stateShots = @('codex', 'claude', 'cursor', 'zai') | ForEach-Object { Join-Path $modeRoot "quota-$_.png" }
            $passed = $passed -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_STATES_SUMMARY .*"status":"partial"' -and
                ([regex]::Matches($text, 'CAELESTIA_QUOTA_SMOKE_STATE ')).Count -eq 4 -and
                -not ($stateShots | Where-Object { -not (Test-Path -LiteralPath $_) -or (Get-Item -LiteralPath $_).Length -le 0 }) -and
                $cacheProviders -eq 7 -and -not $cacheLeaks
        } elseif ($Mode -eq 'offline') {
            $meterPattern = if ($savedCache) { '"meters":([2-9]|[1-9][0-9])' } else { '"meters":0' }
            $passed = $passed -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_OFFLINE .*"status":"error"' -and
                $text -match ('CAELESTIA_QUOTA_SMOKE_OFFLINE .*"saved":' + $(if ($savedCache) { 'true' } else { 'false' })) -and
                $text -match ('CAELESTIA_QUOTA_SMOKE_OPEN .*' + $meterPattern) -and
                (Test-Path -LiteralPath $screenshot) -and (Get-Item -LiteralPath $screenshot).Length -gt 0 -and
                $cacheProviders -eq $(if ($savedCache) { 5 } else { 0 }) -and -not $cacheLeaks
        } elseif ($Mode -eq 'disabled') {
            $passed = $passed -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_DISABLED .*"enabled":false' -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_DISABLED .*"regionWidth":0' -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_DISABLED .*"requests":0'
        } elseif ($Mode -eq 'keepalive') {
            $passed = $passed -and $helperGone -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_KEEPALIVE .*"running":false'
        } elseif ($Mode -eq 'unconfigured') {
            $passed = $passed -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_UNCONFIGURED .*"configured":false' -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_UNCONFIGURED .*"enabled":false' -and
                $cacheProviders -eq 0
        }

        return [ordered]@{
            mode = $Mode
            geometry = $Geometry
            passed = $passed
            timedOut = $timedOut
            exitCode = $process.ExitCode
            diagnostics = $diagnostics
            profile = $profile
            cache = $cachePath
            cacheProviders = $cacheProviders
            cacheLeaks = [bool]$cacheLeaks
            savedCache = $savedCache
            screenshot = $screenshot
            lightScreenshot = $lightScreenshot
            priorityScreenshot = $priorityScreenshot
            menuScreenshot = $menuScreenshot
            stdout = $stdoutPath
            stderr = $stderrPath
            baseUrl = $baseUrl
        }
    } finally {
        if ($stub -and -not $stub.Process.HasExited) {
            $stub.Process.Kill()
            $stub.Process.WaitForExit()
        }
    }
}

$results = @()
foreach ($mode in $Modes) {
    $sizes = switch ($mode) {
        'configured' { $Geometries }
        'states' { @($Geometries | Where-Object { [int]($_ -split 'x')[1] -ge 400 }) }
        default { @($Geometries | Select-Object -First 1) }
    }
    foreach ($geometry in $sizes) {
        $result = Invoke-QuotaSmoke $mode $geometry
        $results += $result
        $result | ConvertTo-Json -Depth 6
        if (-not $result.passed) {
            Write-Host "Quota smoke failed: $mode $geometry ($($result.stdout))" -ForegroundColor Red
            break
        }
    }
    # A failed run stops the rest; nothing retries with other settings.
    if ($results.Count -and -not $results[-1].passed) { break }
}

$passed = ($results | Where-Object { -not $_.passed }).Count -eq 0
$summary = [ordered]@{
    passed = $passed
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).backendRevision
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    python = $python
    stage = $stage
    run = $run
    modes = $results
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$run\result.json" -Encoding UTF8
$summary | ConvertTo-Json -Depth 8
if (-not $passed) { throw "Quota smoke failed: $run" }
