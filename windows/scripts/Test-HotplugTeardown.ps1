[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot
)

# Offscreen reproduction for #215: a display hot-unplug tears an upstream
# ContentWindow down while its ScreenState lookup is already gone. The fixture
# splices the production screen-state binding, the drawer wrappers'
# `shouldBeActive` expressions and ContentWindow's keyboard-focus/scrim
# bindings, removes the screen from the model, then reads every expression
# while the window's deferred deletion is still pending. Any TypeError in the
# child output fails the run, so this would have caught the live fault before
# the fix.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $env:TEMP 'caelestia-hotplug-teardown' }
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
foreach ($required in @($exe, "$qmlRoot\Caelestia\Config\qmldir", "$qmlRoot\Caelestia\Windows\qmldir")) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing hotplug teardown prerequisite: $required" }
}
if (-not (Test-Path -LiteralPath (Join-Path $QtPrefix 'bin\Qt6Core.dll'))) {
    throw "Missing Qt runtime: $QtPrefix"
}
if (-not (Test-Path -LiteralPath (Join-Path $qmlRoot 'M3Shapes\qmldir'))) {
    throw "The staged graph needs M3Shapes: build with windows/scripts/Build-Prototype.ps1."
}

$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" `
    -Destination (Join-Path $run 'stage') -ProfileRoot $profile -Prototype shell-live
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Get-UniqueMatch([string]$Text, [string]$Pattern) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected one production block matching: $Pattern (found $($matches.Count))" }
    return $matches[0].Value
}
function Indent([string]$Text, [int]$Spaces) {
    $prefix = ' ' * $Spaces
    return (($Text -split "`r?`n") | ForEach-Object { if ($_ -eq '') { $_ } else { $prefix + $_ } }) -join "`n"
}

# The main harness screen list is mutable so the test can model a hot-unplug.
# Everything else (ShellState, ScreenState, the services) is the staged
# production graph.
Write-Utf8NoBom (Join-Path $stage 'services\Screens.qml') @'
pragma Singleton

import Quickshell

// Test-only screen list. The harness removes the screen to model a hot-unplug.
Singleton {
    property list<ShellScreen> screens: Quickshell.screens
    function isExcluded(screen: ShellScreen): bool { return false; }
}
'@

$content = Get-Content -LiteralPath (Join-Path $repoRoot 'modules\drawers\ContentWindow.qml') -Raw
# The screen-state lookup is the production line under test. The teardown
# state above it is optional: without the fix the fixture still runs and
# reports the same null reads, so this is a real regression test rather than a
# text assertion.
$screenStateLine = Get-UniqueMatch $content '(?m)^    readonly property ScreenState screenState: [^\r\n]+'
$teardownMatch = [regex]::Match($content, '(?ms)^    readonly property ScreenState teardownState: ScreenState \{.*?^    \}\r?\n')
$teardownBlock = $(if ($teardownMatch.Success) { $teardownMatch.Value } else { '' })
$keyboardFocus = Get-UniqueMatch $content '(?m)^    WlrLayershell\.keyboardFocus: [^\r\n]+'
$scrim = Get-UniqueMatch $content '(?m)^        opacity: \(root\.screenState\.session [^\r\n]+'

# Reproduce the per-window lookup and its teardown fallback exactly.
$stateBlock = (($teardownBlock + $screenStateLine).TrimEnd()).Replace('root.screen', 'win.screen')
# ContentWindow's reported line 77 binding, without the layer-shell enum.
$keyboardFocus = $keyboardFocus -replace '^    WlrLayershell\.keyboardFocus: ', '    readonly property bool keyboardFocusWanted: '
$keyboardFocus = $keyboardFocus.Replace('contentItem.Config', 'Config')
$keyboardFocus = $keyboardFocus.Replace('WlrKeyboardFocus.OnDemand', 'true').Replace('WlrKeyboardFocus.None', 'false')
# ContentWindow's reported line 163 binding.
$scrim = $scrim -replace '^        opacity: ', '            readonly property real scrimOpacity: '
$scrim = $scrim.Replace('root.screenState', 'screenState')

# The wrappers named in the live fault.
$wrapperSources = [ordered]@{
    sidebar = 'modules\sidebar\Wrapper.qml'
    utilities = 'modules\utilities\Wrapper.qml'
    dashboard = 'modules\dashboard\Wrapper.qml'
    launcher = 'modules\launcher\Wrapper.qml'
    session = 'modules\session\Wrapper.qml'
    osd = 'modules\osd\Wrapper.qml'
    quota = 'windows\quota\modules\quota\Wrapper.qml'
}
$wrapperLines = foreach ($entry in $wrapperSources.GetEnumerator()) {
    $text = Get-Content -LiteralPath (Join-Path $repoRoot $entry.Value) -Raw
    $line = Get-UniqueMatch $text '(?m)^    readonly property bool shouldBeActive: [^\r\n]+'
    $line -replace '^    readonly property bool shouldBeActive: ', "    readonly property bool $($entry.Key)Active: "
}

$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\HotplugTeardownTest.qml') -Raw
$fixture = $fixture.Replace('            // CONTENT_WINDOW_STATE', (Indent $stateBlock 12))
$fixture = $fixture.Replace('            // CONTENT_WINDOW_EXPRESSIONS', ((Indent $keyboardFocus 12) + "`n" + (Indent $scrim 12)))
$fixture = $fixture.Replace('            // WRAPPER_BINDINGS', (Indent ($wrapperLines -join "`n") 12))
$entry = Join-Path $stage 'hotplug-teardown.qml'
Write-Utf8NoBom $entry $fixture

$offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks|Setting `width` is deprecated|Setting `height` is deprecated'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '--no-color --log-times --path "' + $entry + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = $info.EnvironmentVariables['QML_IMPORT_PATH']
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
$info.EnvironmentVariables['XDG_CONFIG_HOME'] = "$profile\config"
$info.EnvironmentVariables['XDG_STATE_HOME'] = "$profile\state"
$info.EnvironmentVariables['XDG_CACHE_HOME'] = "$profile\cache"
$info.EnvironmentVariables['XDG_DATA_HOME'] = "$profile\data"
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['QS_DISABLE_FILE_WATCHER'] = '1'
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_WINDOWS_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}

$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(60000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$output = $outTask.GetAwaiter().GetResult() + $errTask.GetAwaiter().GetResult()
Write-Output $output

$diagnostics = @($output -split "`r?`n" | Where-Object {
    $_ -match 'TypeError|ReferenceError|binding loop|CAELESTIA_HOTPLUG_TEARDOWN_FAIL' -and $_ -notmatch $offscreenOnly
})
$passed = -not $timedOut -and $process.ExitCode -eq 0 `
    -and $output -match 'CAELESTIA_HOTPLUG_TEARDOWN_PASS 14' `
    -and $diagnostics.Count -eq 0
$result = [ordered]@{
    passed = $passed
    timedOut = $timedOut
    exitCode = $process.ExitCode
    diagnostics = $diagnostics
    stage = $stage
    profile = $profile
    output = $output
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
if (-not $passed) {
    throw "Hotplug teardown fixture failed (exit $($process.ExitCode), timedOut=$timedOut).`n$($diagnostics -join "`n")"
}
Write-Output "CAELESTIA_HOTPLUG_TEARDOWN_RUN_PASS"

