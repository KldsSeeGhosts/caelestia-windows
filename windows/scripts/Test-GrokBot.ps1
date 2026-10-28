[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot
)
# Synthetic files and the offscreen Qt platform only. Never use a real profile.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$run = Join-Path ([IO.Path]::GetTempPath()) ("caelestia-grok-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
foreach ($required in @($exe, "$qmlRoot\Caelestia\Config\qmldir", "$qmlRoot\M3Shapes\qmldir")) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing prerequisite: $required" }
}
$results = foreach ($mode in @('unconfigured', 'configured', 'offline')) {
    $root = Join-Path $run $mode
    $profile = Join-Path $root 'profile'
    foreach ($dir in @('config', 'state', 'runtime', 'cache', 'data')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $dir) | Out-Null
    }
    $stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $root 'stage') -ProfileRoot $profile -Prototype shell-live
    Copy-Item -LiteralPath "$repo\windows\grokbot\GrokSmoke.qml" -Destination "$stage\grok-smoke.qml"
    Copy-Item -LiteralPath "$repo\windows\grokbot\OffscreenWorkspaces.qml" -Destination "$stage\modules\bar\components\workspaces\Workspaces.qml" -Force
    $snapshot = Join-Path $root 'snapshot.json'
    if ($mode -ne 'unconfigured') {
        $config = @{enabled = $true; snapshotPath = $snapshot} | ConvertTo-Json -Compress
        [IO.File]::WriteAllText("$profile\config\grokbot.json", $config, (New-Object Text.UTF8Encoding($false)))
    }
    if ($mode -eq 'configured') {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $data = @{
            generated_ts = $now
            app = @{running = $true}
            counts = @{bots = 3; awaiting = 1; working = 1; unread = 1}
            bots = @(
                @{name = 'Research'; title = 'Analysis'; shape = 'hex'; working = $true; last_activity_ts = $now - 120},
                @{name = 'Unread'; title = 'Updates'; shape = 'gem'; unread = 3; last_text = 'Synthetic update'; last_activity_ts = $now - 720},
                @{name = 'Waiting'; title = 'Planning'; shape = 'squircle'; awaiting = $true; last_text = 'Synthetic question'; last_activity_ts = $now - 2040}
            )
        } | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText($snapshot, $data, (New-Object Text.UTF8Encoding($false)))
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '--no-color --log-times --path "' + "$stage\grok-smoke.qml" + '"'
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($key in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_*' -or $_ -like 'QS_WINDOWS_*' })) {
        $info.EnvironmentVariables.Remove($key)
    }
    $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
    $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
    $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
    $info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
    $info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
    $info.EnvironmentVariables['CAELESTIA_GROK_TEST_MODE'] = $mode
    $info.EnvironmentVariables['CAELESTIA_GROK_TEST_SCREENSHOT'] = "$root\grok.png"
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
    $info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timeout = -not $process.WaitForExit(15000)
    if ($timeout) { $process.Kill(); $process.WaitForExit() }
    $text = $stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()
    $diagnostics = @($text -split "`n" | Where-Object {
        $_ -match '^\S+ \S+\s+(WARN|ERROR|FATAL|CRITICAL)\b' -and
        $_ -notmatch 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
    })
    $passed = -not $timeout -and $process.ExitCode -eq 0 -and
        $text.Contains("CAELESTIA_GROK_SMOKE_PASS $mode") -and $diagnostics.Count -eq 0
    if ($mode -eq 'configured') { $passed = $passed -and (Test-Path -LiteralPath "$root\grok.png") }
    [pscustomobject]@{mode = $mode; passed = $passed; exitCode = $process.ExitCode; diagnostics = $diagnostics; screenshot = $(if ($mode -eq 'configured') { "$root\grok.png" } else { $null })}
}
$results | ConvertTo-Json -Depth 6
if (@($results | Where-Object { -not $_.passed }).Count) { throw "GrokBot smoke failed; isolated run: $run" }
