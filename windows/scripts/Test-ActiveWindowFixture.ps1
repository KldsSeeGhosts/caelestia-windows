[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$run = Join-Path $BuildRoot ('active-window-fixture-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot $profile -Prototype shell-live
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
}
# Replace only the isolated stage's Hypr facade with an inert test singleton.
Copy-Item -LiteralPath "$repoRoot\windows\combined-prototype\ActiveWindowFixtureHypr.qml" -Destination "$stage\services\Hypr.qml" -Force
Copy-Item -LiteralPath "$repoRoot\windows\combined-prototype\ActiveWindowFixture.qml" -Destination "$stage\active-window-fixture.qml"
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --path "' + "$stage\active-window-fixture.qml" + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_WINDOWS_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(10000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$output = $outTask.GetAwaiter().GetResult() + "`n" + $errTask.GetAwaiter().GetResult()
$output | Set-Content -LiteralPath "$run\output.log" -Encoding UTF8
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and
    $output.Contains('ACTIVE_WINDOW_FIXTURE_PASS') -and
    $output -notmatch '(?i)ACTIVE_WINDOW_FIXTURE_FAIL|TypeError|ReferenceError|binding loop|Unable to assign|Cannot assign|is not a type|^\s*(ERROR|FATAL|CRITICAL):'
[ordered]@{
    passed = $passed
    timedOut = $timedOut
    exitCode = $process.ExitCode
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    output = "$run\output.log"
} | ConvertTo-Json
if (-not $passed) { throw "Active-window fixture failed: $run\output.log" }
