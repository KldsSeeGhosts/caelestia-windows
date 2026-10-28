[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot,
    # Compose the detached window on the desktop instead of the offscreen QPA
    # plugin. The window opens for a few seconds; use it only when a real
    # top-level window is the evidence you need.
    [switch]$Windowed,
    # Observation only: construct the read-only Windows service facades so the
    # Nexus pages render their real (possibly empty) device and network lists.
    # Every control/write/launch/activation opt-in stays unset.
    [switch]$Observe
)
# Light Nexus staging gate: the production graph is staged, then
# windows/nexus/NexusSmoke.qml is run inside it with an isolated profile. It
# checks the GlobalConfig write path against <profile>\config\shell.json, opens
# the detached Nexus window through modules/nexus/WindowFactory.qml, loads every
# page from PageRegistry, presses caelestia:nexus through the backend hotkey
# manager, types into search and checks filtering and navigation, and destroys
# the window again. Service facades stay disabled by
# default; -Observe constructs their read-only observers and still sets no
# control, launch or write opt-in. It does not take screenshots, drive the
# pointer, or start a tiler.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot 'windows\.local\nexus-smoke' }
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot $profile -Prototype shell-live
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}
Copy-Item -LiteralPath "$repoRoot\windows\nexus\NexusSmoke.qml" -Destination "$stage\nexus-smoke.qml"
# A minimal profile: every omitted option keeps its built-in default, which is
# what the smoke's restore step compares against. The seeded tiling keys prove
# the page's whole-map windows write keeps unrelated entries.
'{"windows":{"tiling":{"include":["exe:notepad.exe"],"gapsOut":14}}}' |
    Set-Content -LiteralPath "$profile\config\shell.json" -Encoding UTF8
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --log-times --path "' + "$stage\nexus-smoke.qml" + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
# Offscreen platform by default: the window is still a real Qt window with
# geometry, title and a screen binding, but nothing is composited onto the
# user's desktop.
if (-not $Windowed) { $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen' }
# Keep every service facade off by default: the pages must construct and render
# their disabled state without native enumeration.
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_WINDOWS_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}
if ($Observe) {
    # Observation only. No *_CONTROLS, launch, activation or write opt-in is set,
    # and the Hypr/window-tracking facade stays off so nothing constructs the
    # tiling manager.
    foreach ($variable in @('CAELESTIA_WINDOWS_AUDIO', 'CAELESTIA_WINDOWS_NETWORK', 'CAELESTIA_WINDOWS_BLUETOOTH')) {
        $info.EnvironmentVariables[$variable] = '1'
    }
}
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(60000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath "$run\stdout.log" -Encoding UTF8
$stderr | Set-Content -LiteralPath "$run\stderr.log" -Encoding UTF8
$text = "$stdout`n$stderr"
# The smoke closes every Nexus window it opened before printing PASS. Evaluate
# the whole process output, so a real error during window shutdown or a late
# page incubation fails the run instead of being hidden after the marker.
#
# The offscreen QPA plugin emits two environment warnings of its own (no Qt font
# directory, masks unsupported). They are not QML diagnostics and are the only
# lines excluded.
$offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
function Get-Diagnostics([string]$Body) {
    @($Body -split "`n" |
        Where-Object { $_ -match '^\S+ \S+\s+(WARN|ERROR|FATAL|CRITICAL)\b' } |
        Where-Object { $_ -notmatch $offscreenOnly })
}
$diagnostics = Get-Diagnostics $text
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and
    $text.Contains('CAELESTIA_NEXUS_SMOKE_PASS') -and
    $text.Contains('CAELESTIA_NEXUS_SMOKE_PAGES 12') -and
    $text.Contains('CAELESTIA_NEXUS_SEARCH_PASS') -and
    $text.Contains('CAELESTIA_SHORTCUT name=nexus') -and
    $diagnostics.Count -eq 0
$result = [ordered]@{
    passed    = $passed
    timedOut  = $timedOut
    exitCode  = $process.ExitCode
    diagnostics = $diagnostics
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).backendRevision
    executableSha256 = (Get-FileHash -LiteralPath $info.FileName).Hash
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    command   = $info.FileName
    arguments = $info.Arguments
    stage     = $stage
    profile   = $profile
    stagedSources = "$stage\sources.json"
    stdout    = "$run\stdout.log"
    stderr    = "$run\stderr.log"
}
$result | ConvertTo-Json | Set-Content -LiteralPath "$run\result.json" -Encoding UTF8
$result | ConvertTo-Json
if (-not $passed) { throw "Nexus smoke failed: $run" }
