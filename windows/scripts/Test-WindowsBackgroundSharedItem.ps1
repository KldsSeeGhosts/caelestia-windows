[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot,
    [switch]$Keep
)
# Offscreen regression for #214. The fixture loads the real background window,
# then moves its content item to a second window while an effect outside the
# moved subtree still references the wallpaper image. Qt reports "Cannot use
# same item on different windows at the same time" when the wallpaper item is
# carried across, and the live shell later crashes in
# QQuickWindowPrivate::dirtyItem. The background now owns its wallpaper and
# clock per window, so the old item is destroyed instead of shared.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$qs = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
if (-not (Test-Path -LiteralPath $qs -PathType Leaf)) { throw "Missing Quickshell runtime: $qs" }
if (-not (Test-Path -LiteralPath $qmlRoot -PathType Container)) { throw "Missing installed QML modules: $qmlRoot" }

$run = if ($RunRoot) {
    Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
} else {
    Join-Path ([IO.Path]::GetTempPath()) ('caelestia-background-shared-' + [guid]::NewGuid().ToString('N'))
}
$profile = Join-Path $run 'profile'
$stage = Join-Path $run 'stage'
New-Item -ItemType Directory -Force $run, $profile | Out-Null
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}
try {
    & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination $stage -ProfileRoot $profile -Prototype shell-live | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'windows\tests\WindowsBackgroundSharedItemTest.qml') `
        -Destination (Join-Path $stage 'background-shared-item.qml')
    # Match the live profile: wallpaper and background on, clock and visualiser
    # off. The fixture only needs the real wallpaper path.
    '{"background":{"enabled":true,"wallpaperEnabled":true,"desktopClock":{"enabled":false},"visualiser":{"enabled":false}}}' |
        Set-Content -LiteralPath (Join-Path $profile 'config\shell.json') -Encoding UTF8

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $qs
    $info.Arguments = '--no-color --log-times --path "' + (Join-Path $stage 'background-shared-item.qml') + '"'
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
        throw 'Windows background shared-item fixture timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Write-Output $output

    $offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
    $sceneDiagnostics = @($output -split "\r?\n" |
        Where-Object { $_ -match 'WARN scene:' -and $_ -notmatch $offscreenOnly })
    $bad = $output -match 'CAELESTIA_BACKGROUND_SHARED_FAIL|Cannot use same item on different windows|TypeError|ReferenceError|binding loop'
    $marker = [regex]::Match($output, 'CAELESTIA_BACKGROUND_SHARED_PASS (\d+)\b')
    if ($process.ExitCode -ne 0 -or -not $marker.Success -or [int]$marker.Groups[1].Value -lt 11 -or $bad -or $sceneDiagnostics.Count -gt 0) {
        throw "Windows background shared-item fixture failed: $run"
    }
    Write-Output 'PASS background shared item: the recreated window builds its own wallpaper and releases the old one.'
} finally {
    if (-not $Keep -and -not $RunRoot) {
        $safeRun = [IO.Path]::GetFullPath($run).TrimEnd('\')
        if ((Split-Path -Parent $safeRun) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
            (Split-Path -Leaf $safeRun) -notlike 'caelestia-background-shared-*') {
            throw 'Unsafe background shared-item cleanup path.'
        }
        Remove-Item -LiteralPath $safeRun -Recurse -Force
    }
}
