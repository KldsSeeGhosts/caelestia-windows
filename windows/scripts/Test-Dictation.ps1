[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot = (Join-Path $env:TEMP 'caelestia-dictation-smoke')
)
# Synthetic/offscreen only. No microphone, clipboard, native service observers,
# shortcuts, taskbar/tiler controllers, installed profile or desktop input.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
foreach ($required in @($exe, "$QtPrefix\bin\qtpaths.exe", "$QtPrefix\bin\qmlformat.exe",
    "$qmlRoot\Caelestia\Config\qmldir", "$BuildRoot\logs\build.json")) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing prerequisite: $required" }
}
# Syntax-only check for the production native wrapper, which cannot be loaded
# by offscreen QPA. No -i flag: qmlformat parses but does not modify the source.
& "$QtPrefix\bin\qmlformat.exe" --ignore-settings "$repoRoot\windows\combined-prototype\adapters\modules\dictation\DictationWindow.qml" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Native dictation wrapper syntax check failed.' }
$results = foreach ($mode in @('disabled', 'enabled')) {
    $modeRoot = Join-Path $run $mode
    $profile = Join-Path $modeRoot 'profile'
    $stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $modeRoot 'stage') -ProfileRoot $profile -Prototype shell-live
    foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
    }
    Copy-Item -LiteralPath "$repoRoot\windows\dictation\DictationSmoke.qml" -Destination "$stage\dictation-smoke.qml"
    Copy-Item -LiteralPath "$repoRoot\windows\dictation\OffscreenDictationWindow.qml" -Destination "$stage\OffscreenDictationWindow.qml"
    # Also exercise the producer helper, including replacement and no-BOM JSON.
    & "$PSScriptRoot\Set-DictationState.ps1" -RuntimeRoot "$profile\runtime" -State processing -StartedAt 1
    & "$PSScriptRoot\Set-DictationState.ps1" -RuntimeRoot "$profile\runtime" -State listening -Screen 'fixture-screen'
    $stateFile = Join-Path $profile 'runtime\dictation-state.json'
    $published = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
    if ($published.state -ne 'listening' -or $published.screen -ne 'fixture-screen' -or
        $published.startedAt -le 0 -or $published.updatedAt -lt $published.startedAt -or
        ([IO.File]::ReadAllBytes($stateFile))[0] -ne 123 -or
        @(Get-ChildItem "$profile\runtime" -Filter '*.tmp').Count -ne 0) {
        throw 'Dictation publisher contract failed.'
    }
    # Enabled starts missing, then the QML fixture creates/replaces this file.
    if ($mode -eq 'enabled') { Remove-Item -LiteralPath $stateFile }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '--no-color --log-times --path "' + "$stage\dictation-smoke.qml" + '"'
    $info.WorkingDirectory = $modeRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($variable in @($info.EnvironmentVariables.Keys |
        Where-Object { $_ -like 'CAELESTIA_*' -or $_ -like 'QS_WINDOWS_*' })) {
        $info.EnvironmentVariables.Remove($variable)
    }
    $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
    $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
    $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
    $info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
    $info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
    $info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_DICTATION'] = $(if ($mode -eq 'enabled') { '1' } else { '0' })
    $info.EnvironmentVariables['CAELESTIA_DICTATION_SCREENSHOT'] = "$modeRoot\pill.png"
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit(30000)
    if ($timedOut) { $process.Kill(); $process.WaitForExit() }
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    $stdout | Set-Content -LiteralPath "$modeRoot\stdout.log" -Encoding UTF8
    $stderr | Set-Content -LiteralPath "$modeRoot\stderr.log" -Encoding UTF8
    $text = "$stdout`n$stderr"
    $diagnostics = @($text -split "`n" |
        Where-Object { $_ -match '^\S+ \S+\s+(WARN|ERROR|FATAL|CRITICAL)\b' } |
        Where-Object { $_ -notmatch 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks' })
    $passed = -not $timedOut -and $process.ExitCode -eq 0 -and
        $text.Contains('CAELESTIA_DICTATION_SMOKE_PASS') -and $diagnostics.Count -eq 0 -and
        $text -notmatch 'SYNTHETIC_PRIVATE_SPEECH|SYNTHETIC_PRIVATE_ERROR|CAELESTIA_DICTATION_SMOKE_FAIL'
    if ($mode -eq 'enabled') {
        $passed = $passed -and (Test-Path -LiteralPath "$modeRoot\pill.png" -PathType Leaf)
    }
    [ordered]@{
        mode = $mode; passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode
        diagnostics = $diagnostics; stage = $stage; profile = $profile
        stdout = "$modeRoot\stdout.log"; stderr = "$modeRoot\stderr.log"
        screenshot = $(if ($mode -eq 'enabled') { "$modeRoot\pill.png" } else { $null })
    }
}
$result = [ordered]@{
    passed = @($results | Where-Object { -not $_.passed }).Count -eq 0
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    buildRecord = "$BuildRoot\logs\build.json"
    buildBackendRevision = (Get-Content -LiteralPath "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).backendRevision
    pinnedBackendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    nativeWrapperSyntaxPassed = $true
    executableSha256 = (Get-FileHash -LiteralPath $exe).Hash
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    modes = @($results)
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$run\result.json" -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Dictation smoke failed: $run" }
