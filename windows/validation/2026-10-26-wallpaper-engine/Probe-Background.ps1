param(
    [string]$BuildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build',
    [string]$QtPrefix = 'C:\Users\Ermin\AppData\Local\caelestia-dev\Qt\6.11.2\msvc2022_64'
)
$ErrorActionPreference = 'Stop'
$repoRoot = (git rev-parse --show-toplevel).Trim()
$probeRoot = Join-Path $repoRoot 'windows\.local\wallpaperengine-probe'
$profileRoot = Join-Path $probeRoot 'profile'
$stage = & "$repoRoot\windows\scripts\Stage-ShellPrototype.ps1" -Prototype combined -Destination "$probeRoot\stage" -ProfileRoot $profileRoot
$backgroundRevision = '080558870e5848373fdc3f5236cea025f0b10073'
$manifest = (git show "${backgroundRevision}:windows/combined-prototype/sources.json" | Out-String) | ConvertFrom-Json
foreach ($entry in $manifest.PSObject.Properties) {
    if ($entry.Value -notmatch '^(modules/background/|imports/Caelestia/Multimedia/|components/widgets/WallpaperImpl.qml$|assets/wallpaper.webp$)') { continue }
    $target = Join-Path $stage $entry.Value
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    if ($entry.Value -eq 'modules/background/WindowsBackground.qml') {
        Copy-Item -LiteralPath (Join-Path $repoRoot $entry.Name) -Destination $target -Force
    } elseif ($entry.Value -eq 'assets/wallpaper.webp') {
        Copy-Item -LiteralPath "$repoRoot\assets\wallpaper.webp" -Destination $target -Force
    } else {
        $content = git show "${backgroundRevision}:$($entry.Name)" | Out-String
        [IO.File]::WriteAllText($target, $content, (New-Object Text.UTF8Encoding($false)))
    }
}
foreach ($name in @('config', 'state', 'cache', 'data', 'runtime')) {
    New-Item -ItemType Directory -Force -Path "$profileRoot\$name" | Out-Null
}
'{"services":{"smartScheme":true}}' |
    Set-Content -LiteralPath "$profileRoot\config\shell.json" -Encoding utf8
'{"windows":{"wallpaperEngine":{"enabled":"auto"}}}' |
    Set-Content -LiteralPath "$profileRoot\config\windows.json" -Encoding utf8
$probe = @'
import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia.Config
import qs.services
import qs.modules.background
ShellRoot {
    readonly property color primary: Colours.palette.m3primary
    WindowsBackground { id: background }
    Timer {
        running: true; repeat: true; interval: 200
        onTriggered: {
            if (!WallpaperEngine.snapshotReady || SchemeGenerator.status !== "ready" || Colours.scheme !== "dynamic")
                return;
            if (!WallpaperEngine.running || !background.checkReady(Quickshell.screens[0])) {
                console.error("CAELESTIA_WE_PROBE_FAIL"); Qt.exit(1); return;
            }
            console.log("CAELESTIA_WE_PROBE_PASS", JSON.stringify({
                count: Wallpapers.list.length, current: WallpaperEngine.current,
                primary: String(primary), backgroundScreens: background.screens.length,
                desktopActive: Native.DesktopLayer.active, clock: false
            }));
            Qt.quit();
        }
    }
    Timer { running: true; interval: 12000; onTriggered: Qt.exit(2) }
}
'@
$header = @("DataDir $profileRoot\data", "StateDir $profileRoot\state", "CacheDir $profileRoot\cache") |
    ForEach-Object { "//@ pragma $_" }
[IO.File]::WriteAllText("$stage\shell.qml", (($header -join "`n") + "`n" + $probe), (New-Object Text.UTF8Encoding($false)))
$python = Join-Path $BuildRoot 'combined-prototype-profile\scheme\venv\Scripts\python.exe'
$before = (& $python "$repoRoot\windows\services\wallpaperengine\bridge.py" snapshot | ConvertFrom-Json)
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --log-times --path "' + "$stage\shell.qml" + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['CAELESTIA_PROFILE_ROOT'] = $profileRoot
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profileRoot\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profileRoot\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profileRoot\runtime"
$info.EnvironmentVariables['CAELESTIA_WE_PYTHON'] = $python
$info.EnvironmentVariables['CAELESTIA_SCHEME_PYTHON'] = $python
$info.EnvironmentVariables['CAELESTIA_SCHEME_HELPER'] = "$repoRoot\windows\scripts\scheme\win_scheme.py"
$info.EnvironmentVariables['CAELESTIA_WINDOWS_BACKGROUND'] = '1'
$info.EnvironmentVariables['CAELESTIA_COMBINED_LIVE'] = '0'
$info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = '1'
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
$process = [Diagnostics.Process]::Start($info)
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'WE probe timed out' }
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath "$probeRoot\stdout.log" -Encoding utf8
$stderr | Set-Content -LiteralPath "$probeRoot\stderr.log" -Encoding utf8
$after = (& $python "$repoRoot\windows\services\wallpaperengine\bridge.py" snapshot | ConvertFrom-Json)
$unchanged = ($before.monitors | ConvertTo-Json -Depth 8 -Compress) -eq ($after.monitors | ConvertTo-Json -Depth 8 -Compress)
$passed = $process.ExitCode -eq 0 -and $stdout.Contains('CAELESTIA_WE_PROBE_PASS') -and $unchanged -and
    "$stdout`n$stderr" -notmatch '(?m)^\S+ \S+\s+(WARN|ERROR|FATAL)\b'
[ordered]@{
    passed = $passed; sourceRevision = (git rev-parse HEAD).Trim(); backgroundRevision = $backgroundRevision
    sourceDirty = [bool](git status --porcelain); exitCode = $process.ExitCode
    wallpaperUnchanged = $unchanged; before = $before.monitors; after = $after.monitors
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$probeRoot\result.json" -Encoding utf8
Write-Output $stdout
Write-Output $stderr
if (-not $passed) { throw "WE background probe failed: $probeRoot" }
