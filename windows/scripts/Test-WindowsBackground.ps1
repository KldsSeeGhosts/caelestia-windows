[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $QtPrefix 'bin\qml.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Missing QML runner: $runner" }
$background = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\adapters\modules\background\WindowsBackground.qml') -Raw
$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\WindowsBackgroundTest.qml') -Raw

function Get-UniqueMatch([string]$Text, [string]$Pattern) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected one production block matching: $Pattern" }
    return $matches[0].Value
}

# Splice the real state machine, not a copy. The fixture only supplies the
# backend, service and screen mocks, so drift in the adapter fails this test.
$properties = Get-UniqueMatch $background '(?ms)^    readonly property bool backgroundRequested:.*?(?=^    readonly property bool smoke:)'
$screens = Get-UniqueMatch $background '(?ms)^    screens: enabled && Native\.DesktopLayer\.active.*?^        : \[\]'
$icons = Get-UniqueMatch $background '(?m)^    readonly property string desktopIcons: [^\r\n]+'
$reconcile = Get-UniqueMatch $background '(?ms)^    function reconcileDesktop\(\): void \{.*?^    \}'
$underlay = Get-UniqueMatch $background '(?ms)^    onUnderlayActiveChanged: \{.*?^    \}'
$ready = Get-UniqueMatch $background '(?ms)^    function checkReady\(screen: ShellScreen\): bool \{.*?^    \}'

# Host discovery must re-run for every input that decides whether the backend
# embeds this window, including the first scan before any underlay exists and
# the icon embedding when an external owner starts or stops. The external
# owner handler is a block: it also releases the desktop claim when the
# process is gone, so the next process starts fail-closed.
$handlers = foreach ($trigger in @('onBackgroundRequestedChanged', 'onDesktopIconsChanged')) {
    Get-UniqueMatch $background "(?m)^    $([regex]::Escape($trigger)): reconcileDesktop\(\)\r?$"
}
$externalHandler = Get-UniqueMatch $background '(?ms)^    onExternalActiveChanged: \{.*?^    \}'
$null = Get-UniqueMatch $background '(?ms)^    Component\.onCompleted: \{.*?^    \}'

# Map production singletons onto fixture properties. `enabled` is renamed to
# avoid overriding the Item property that reads it.
$properties = $properties.Replace('Quickshell.env', 'root.environment.env')
$properties = $properties.Replace('Native.DesktopLayer', 'root.nativeLayer')
$properties = $properties.Replace('Wallpapers.externalWallpaperActive', 'root.wallpapers.externalWallpaperActive')
$properties = $properties.Replace('readonly property bool enabled:', 'readonly property bool hostEnabled:')
$screens = $screens.Replace('screens: enabled &&', 'screens: hostEnabled &&')
# Item has no `screens`; declare the production binding on the fixture root.
$screens = $screens.Replace('    screens: hostEnabled &&', '    property var screens: hostEnabled &&')
$screens = $screens.Replace('Native.DesktopLayer', 'root.nativeLayer')
$screens = $screens.Replace('Screens.screens', 'root.screensCatalog')
$screens = $screens.Replace('Quickshell.env', 'root.environment.env')
$screens = $screens.Replace('Quickshell.screens', 'root.quickshellScreens')
$icons = $icons.Replace('Quickshell.env', 'root.environment.env')
$reconcile = $reconcile.Replace('Native.DesktopLayer', 'root.nativeLayer')
$reconcile = $reconcile.Replace('Wallpapers.externalWallpaperActive', 'root.wallpapers.externalWallpaperActive')
$externalHandler = $externalHandler.Replace('Wallpapers.externalWallpaperActive', 'root.wallpapers.externalWallpaperActive')
$underlay = $underlay.Replace('WallpaperEngine', 'root.wallpaperEngine')
$underlay = $underlay.Replace('Native.DesktopLayer', 'root.nativeLayer')
$ready = $ready.Replace('screen: ShellScreen', 'screen')
$ready = $ready.Replace('Native.DesktopLayer', 'root.nativeLayer')
$ready = $ready.Replace('Wallpapers.externalWallpaperActive', 'root.wallpapers.externalWallpaperActive')
$ready = $ready.Replace('WallpaperEngine.running', 'root.wallpaperEngine.running')
$ready = $ready.Replace('CUtils.findChild', 'root.cutils.findChild')
$ready = $ready.Replace('GlobalConfig.forScreen', 'root.globalConfig.forScreen')
$ready = $ready.Replace('Wallpapers.current', 'root.wallpapers.current')

$fixture = $fixture.Replace('    // WINDOWS_BACKGROUND_PROPERTIES', (($properties.TrimEnd(), $icons.TrimEnd()) -join "`n"))
$fixture = $fixture.Replace('    // WINDOWS_BACKGROUND_SCREENS', $screens.TrimEnd())
$fixture = $fixture.Replace('    // RECONCILE_DESKTOP', (($reconcile.TrimEnd(), ($handlers -join "`n"), $externalHandler.TrimEnd()) -join "`n"))
$fixture = $fixture.Replace('    // UNDERLAY_HANDLER', $underlay.TrimEnd())
$fixture = $fixture.Replace('    // CHECK_READY', $ready.TrimEnd())

$stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-background-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $test = Join-Path $stage 'WindowsBackgroundTest.qml'
    [IO.File]::WriteAllText($test, $fixture, (New-Object Text.UTF8Encoding($false)))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $runner
    $info.Arguments = '"' + $test + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(20000)) {
        $process.Kill()
        throw 'Windows background fixture timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    Write-Output $output

    # Readiness is consumed through the logged state, including the owner
    # handoff between Wallpaper Engine and the acknowledged underlay.
    $states = @($output -split "\r?\n" | Where-Object { $_ -match 'CAELESTIA_BACKGROUND_STATE' })
    function Test-State([string[]]$Fragments) {
        foreach ($line in $states) {
            $all = $true
            foreach ($fragment in $Fragments) {
                if ($line.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
                    $all = $false
                    break
                }
            }
            if ($all) { return $true }
        }
        return $false
    }
    foreach ($case in @(
        @('"underlay":true', '"owner":"wallpaper-engine-underlay"'),
        @('"owner":"undiscovered-underlay"'),
        @('"owner":"wallpaper-engine-process"', '"externalOutputReady":null'),
        @('"underlay":false'),
        @('"underlay":false', '"screens":[]'),
        @('"underlay":false', '"screens":[0,1]', '"ready":true')
    )) {
        if (-not (Test-State $case)) { throw "Missing background state: $($case -join ' ')" }
    }

    # The handback state is explicit: the process is still alive, the backend
    # has withdrawn the underlay, and the shell's own screens and instances are
    # mounted again. This guards the #214 sequence even if assertion counts
    # later shift.
    $handback = [regex]::Match($output,
        'CAELESTIA_BACKGROUND_HANDBACK_STATE \{"external":true,"underlay":false,"host":true,"screens":2,"instances":1\}')
    if (-not $handback.Success) { throw 'Missing the restored background handback state.' }

    # The assertion count is part of the marker: a scenario silently dropped
    # from the fixture must fail the run, not just shrink the number.
    $marker = [regex]::Match($output, 'CAELESTIA_BACKGROUND_UNDERLAY_PASS 80\b')
    if ($exitCode -ne 0 -or -not $marker.Success -or
        $output -match 'CAELESTIA_BACKGROUND_UNDERLAY_FAIL|TypeError|ReferenceError|binding loop') {
        throw 'Windows background fixture failed.'
    }
    Write-Output 'PASS background underlay: 80 assertions across the acknowledged and legacy backends.'
} finally {
    $safeStage = [IO.Path]::GetFullPath($stage).TrimEnd('\')
    if ((Split-Path -Parent $safeStage) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $safeStage) -notlike 'caelestia-background-*') { throw 'Unsafe background fixture cleanup path.' }
    Remove-Item -LiteralPath $safeStage -Recurse -Force
}
