[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot 'windows\.local\tiling-config-smoke' }
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot $profile -Prototype tiling
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}
Copy-Item -LiteralPath "$repoRoot\windows\services\tiling\TilingConfigSmoke.qml" -Destination "$stage\config-smoke.qml"
@'
{"windows":{"tiling":{"enabled":true,"mode":"observe","gapsIn":10,"gapsOut":10,"include":["exe:fixture.exe"],"float":["title:Dialog*"],"monitors":{"FixtureScreen":false}}}}
'@ | Set-Content -LiteralPath "$profile\config\shell.json" -Encoding UTF8
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --log-times --path "' + "$stage\config-smoke.qml" + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
# Test the profile without any env override. Native Interactive is never
# requested, and the smoke guard remains on independently.
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_WINDOWS_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}
$info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = '1'
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(10000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath "$run\stdout.log" -Encoding UTF8
$stderr | Set-Content -LiteralPath "$run\stderr.log" -Encoding UTF8
$text = "$stdout`n$stderr"
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and
    $text.Contains('CAELESTIA_TILING_CONFIG_SMOKE_PASS') -and
    $text.Contains('CAELESTIA_TILING_OPTIONS gapsIn=10 gapsOut=10') -and
    $text.Contains('CAELESTIA_TILING_OPTIONS gapsIn=12 gapsOut=14') -and
    $text -notmatch '(?m)^\S+ \S+\s+(WARN|ERROR|FATAL|CRITICAL)\b'
$result = [ordered]@{
    passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).backendRevision
    executableSha256 = (Get-FileHash -LiteralPath $info.FileName).Hash
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    command = $info.FileName; arguments = $info.Arguments
    stage = $stage; profile = $profile; stdout = "$run\stdout.log"; stderr = "$run\stderr.log"
}
$result | ConvertTo-Json | Set-Content -LiteralPath "$run\result.json" -Encoding UTF8
$result | ConvertTo-Json
if (-not $passed) { throw "Tiling config smoke failed: $run" }
