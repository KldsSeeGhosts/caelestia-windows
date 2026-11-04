[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot,
    [switch]$Keep
)
# Offscreen regression for #214: the background window is mounted, its QML tree
# is live and the handback source is a real local file, yet the desktop stayed
# black. WallpaperImpl waited for a ShaderEffectSource capture before it moved
# live to the new source; while Wallpaper Engine covered the window that capture
# can be black, and a capture started just before the handback can land after
# it and paint over the verified wallpaper. The fixture runs the production
# WallpaperImpl from the staged shell, so the handback-direct source, the stale
# capture guard and the resize re-decode are exercised without Wallpaper Engine.
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
    Join-Path ([IO.Path]::GetTempPath()) ('caelestia-wallpaper-impl-' + [guid]::NewGuid().ToString('N'))
}
$profile = Join-Path $run 'profile'
$stage = Join-Path $run 'stage'
New-Item -ItemType Directory -Force $run, $profile | Out-Null
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}
try {
    & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination $stage -ProfileRoot $profile -Prototype shell-live | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'windows\tests\WallpaperImplHandbackTest.qml') `
        -Destination (Join-Path $stage 'wallpaper-impl-handback.qml')
    # A second decodeable file with a different path, so a handback source that
    # happens to name the previous file cannot pass the immediate-apply check.
    Copy-Item -LiteralPath (Join-Path $stage 'assets\wallpaper.webp') `
        -Destination (Join-Path $stage 'assets\wallpaper-handback.webp')
    # The fixture drives the transition directly; keep the isolated profile
    # minimal and leave every native Windows facade off.
    '{}' | Set-Content -LiteralPath (Join-Path $profile 'config\shell.json') -Encoding UTF8

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $qs
    $info.Arguments = '--no-color --log-times --path "' + (Join-Path $stage 'wallpaper-impl-handback.qml') + '"'
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
    if (-not $process.WaitForExit(45000)) {
        $process.Kill()
        $process.WaitForExit()
        throw 'WallpaperImpl handback fixture timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Write-Output $output

    $offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
    $sceneDiagnostics = @($output -split "\r?\n" |
        Where-Object { $_ -match 'WARN scene:' -and $_ -notmatch $offscreenOnly })
    $bad = $output -match 'CAELESTIA_WALLPAPER_IMPL_FAIL|TypeError|ReferenceError|binding loop'
    $marker = [regex]::Match($output, 'CAELESTIA_WALLPAPER_IMPL_PASS (\d+)\b')
    if ($process.ExitCode -ne 0 -or -not $marker.Success -or [int]$marker.Groups[1].Value -lt 17 -or $bad -or $sceneDiagnostics.Count -gt 0) {
        throw "WallpaperImpl handback fixture failed: $run"
    }
    Write-Output 'PASS wallpaper implementation handback: the handback source reaches live immediately with the transition at 1, a capture scheduled before the handback cannot cover it, a covered window keeps the handback source, and a resize reloads the same local file.'
} finally {
    if (-not $Keep -and -not $RunRoot) {
        $safeRun = [IO.Path]::GetFullPath($run).TrimEnd('\')
        if ((Split-Path -Parent $safeRun) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
            (Split-Path -Leaf $safeRun) -notlike 'caelestia-wallpaper-impl-*') {
            throw 'Unsafe WallpaperImpl handback cleanup path.'
        }
        Remove-Item -LiteralPath $safeRun -Recurse -Force
    }
}
