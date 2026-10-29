[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateRange(3, 10000)][int]$Switches = 600
)

# Read-only observers, isolated profile, no shell entry point, tiler, global
# shortcuts or controls. The small native tool window does not accept focus.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) ([guid]::NewGuid().ToString())
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot $profile -Prototype shell-live
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}
$entry = Join-Path $stage 'nexus-audio-stress.qml'
$header = @("DataDir $profile\data", "StateDir $profile\state", "CacheDir $profile\cache") |
    ForEach-Object { "//@ pragma $_" }
$shell = [IO.File]::ReadAllText("$repoRoot\windows\nexus\NexusAudioStress.qml")
[IO.File]::WriteAllText($entry, (($header -join "`n") + "`n" + $shell), (New-Object Text.UTF8Encoding($false)))
# Quickshell's backend runtime bookkeeping still uses its own runtime location,
# outside RunRoot. The shell's data, state and cache directories are isolated.
'{}' | Set-Content -LiteralPath "$profile\config\shell.json" -Encoding UTF8
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --no-detailed-logs --log-times --log-rules "*.debug=false;*.info=false" --path "' + "$stage\nexus-audio-stress.qml" + '"'
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
$info.EnvironmentVariables['NEXUS_AUDIO_STRESS_SWITCHES'] = "$Switches"
$info.EnvironmentVariables.Remove('QT_QPA_PLATFORM')
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_WINDOWS_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_WE_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}
foreach ($variable in @('CAELESTIA_WINDOWS_AUDIO', 'CAELESTIA_WINDOWS_NETWORK', 'CAELESTIA_WINDOWS_BLUETOOTH')) {
    $info.EnvironmentVariables[$variable] = '1'
}
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(600000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$text = "$stdout`n$stderr"
$diagnostics = @($text -split "`n" | Where-Object {
    $_ -match '^\S+ \S+\s+(WARN|ERROR|FATAL|CRITICAL)\b' -and $_ -notmatch 'NEXUS_AUDIO_STRESS_PASS'
})
$errors = @($diagnostics | Where-Object { $_ -match '^\S+ \S+\s+(ERROR|FATAL|CRITICAL)\b' })
$result = [ordered]@{
    passed = -not $timedOut -and $process.ExitCode -eq 0 -and $text.Contains("NEXUS_AUDIO_STRESS_PASS $Switches") -and $errors.Count -eq 0
    timedOut = $timedOut
    exitCode = $process.ExitCode
    diagnosticCount = $diagnostics.Count
    errorCount = $errors.Count
    run = $run
}
$result | ConvertTo-Json
if (-not $result.passed) { throw "Nexus audio stress failed: $run" }
