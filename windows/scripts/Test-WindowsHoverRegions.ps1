[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$run = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-hover-regions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot $profile -Prototype shell-live
Copy-Item -LiteralPath "$repoRoot\windows\tests\WindowsHoverRegionsTest.qml" -Destination "$stage\hover-test.qml"
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
}
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --log-times --path "' + "$stage\hover-test.qml" + '"'
$info.WorkingDirectory = $run
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_*' -or $_ -like 'QS_WINDOWS_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$process = [Diagnostics.Process]::Start($info)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(20000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
Write-Output $output
$marker = [regex]::Match($output, 'CAELESTIA_WINDOWS_HOVER_REGIONS_PASS (\d+)\b')
if ($timedOut -or $process.ExitCode -ne 0 -or -not $marker.Success -or [int]$marker.Groups[1].Value -lt 13 -or
    $output -match 'CAELESTIA_WINDOWS_HOVER_REGIONS_FAIL|TypeError|ReferenceError|binding loop') {
    throw 'Hover region fixture failed.'
}
