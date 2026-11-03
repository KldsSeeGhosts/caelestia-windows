[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot,
    [switch]$Keep
)
# Offscreen regression for #214. The fixture moves a real background window's
# item tree between two windows, the same two-step reparent Quickshell performs
# when the Windows desktop host is recreated on Wallpaper Engine handback. The
# old inline DesktopClock blur capture emitted "Cannot use same item on
# different windows at the same time." and left the wallpaper on the dead
# window; the fixed child capture is clean.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$qs = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
if (-not (Test-Path -LiteralPath $qs -PathType Leaf)) { throw "Missing Quickshell runtime: $qs" }
if (-not (Test-Path -LiteralPath $qmlRoot -PathType Container)) { throw "Missing installed QML modules: $qmlRoot" }

function Get-UniqueMatch([string]$Text, [string]$Pattern) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected one production block matching: $Pattern" }
    return $matches[0].Value
}

# Splice the real ownership guard, not a copy. The fixture's fake desktop layer
# drives the backend signals; the block decides whether the process still owns
# the desktop, so a handback that keeps the external claim fails here (#214).
$engine = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\services\wallpaperengine\WallpaperEngine.qml') -Raw
$ownership = Get-UniqueMatch $engine '(?ms)^    // WINDOWS_DESKTOP_OWNERSHIP_BEGIN.*?^    // WINDOWS_DESKTOP_OWNERSHIP_END'
$ownership = $ownership -replace '(?m)^    // WINDOWS_DESKTOP_OWNERSHIP_(?:BEGIN|END)\r?\n?', ''
$ownership = $ownership.Replace('Native.DesktopLayer', 'root.desktopLayer')
$ownership = ($ownership -split "\r?\n" | ForEach-Object {
    if ($_ -eq '') { $_ } else { '    ' + $_ }
}) -join "`n"
$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\WindowsBackgroundHandbackTest.qml') -Raw
$fixture = $fixture.Replace('        // WINDOWS_BACKGROUND_OWNERSHIP', $ownership.TrimEnd())

$run = if ($RunRoot) {
    Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
} else {
    Join-Path ([IO.Path]::GetTempPath()) ('caelestia-background-handback-' + [guid]::NewGuid().ToString('N'))
}
$profile = Join-Path $run 'profile'
$stage = Join-Path $run 'stage'
New-Item -ItemType Directory -Force $run, $profile | Out-Null
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}
try {
    & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination $stage -ProfileRoot $profile -Prototype shell-live | Out-Null
    [IO.File]::WriteAllText((Join-Path $stage 'background-handback.qml'), $fixture, (New-Object Text.UTF8Encoding($false)))
    # The fixture only exercises the clock blur path; keep the isolated profile
    # minimal and leave every native Windows facade off.
    '{"background":{"desktopClock":{"enabled":true,"background":{"enabled":true,"blur":true}}}}' |
        Set-Content -LiteralPath (Join-Path $profile 'config\shell.json') -Encoding UTF8

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $qs
    $info.Arguments = '--no-color --log-times --path "' + (Join-Path $stage 'background-handback.qml') + '"'
    $info.WorkingDirectory = $stage
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
    $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QML2_IMPORT_PATH'] = $info.EnvironmentVariables['QML_IMPORT_PATH']
    $info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
    $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
    $info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
    $info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
    $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
    $info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
    $info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'

    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        $process.WaitForExit()
        throw 'Windows background handback fixture timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Write-Output $output

    $offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
    $sceneDiagnostics = @($output -split "\r?\n" |
        Where-Object { $_ -match 'WARN scene:' -and $_ -notmatch $offscreenOnly })
    $bad = $output -match 'CAELESTIA_BACKGROUND_HANDBACK_FAIL|Cannot use same item on different windows|TypeError|ReferenceError|binding loop'
    $marker = [regex]::Match($output, 'CAELESTIA_BACKGROUND_HANDBACK_PASS 16\b')
    if ($process.ExitCode -ne 0 -or -not $marker.Success -or $bad -or $sceneDiagnostics.Count -gt 0) {
        throw "Windows background handback fixture failed: $run"
    }
    Write-Output 'PASS background handback: the external claim is released while the process runs, the wallpaper and clock follow the recreated window, and a refusal still fails closed.'
} finally {
    if (-not $Keep -and -not $RunRoot) {
        $safeRun = [IO.Path]::GetFullPath($run).TrimEnd('\')
        if ((Split-Path -Parent $safeRun) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
            (Split-Path -Leaf $safeRun) -notlike 'caelestia-background-handback-*') {
            throw 'Unsafe background handback cleanup path.'
        }
        Remove-Item -LiteralPath $safeRun -Recurse -Force
    }
}
