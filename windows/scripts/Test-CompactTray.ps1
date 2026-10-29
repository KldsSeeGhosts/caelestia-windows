[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$QtPrefix
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $QtPrefix) {
    $QtPrefix = (Get-Content -LiteralPath (Join-Path $BuildRoot 'logs\build.json') -Raw | ConvertFrom-Json).qtPrefix
}
$run = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-compact-tray-' + [guid]::NewGuid().ToString('N'))
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination "$run\shell" -ProfileRoot $profile -Prototype combined
New-Item -ItemType Directory -Path "$profile\config" -Force | Out-Null
$config = Get-Content -LiteralPath "$repoRoot\windows\shell\shell.json" -Raw | ConvertFrom-Json
# Exercise the actual Bar hover-close route without constructing other services.
$config.bar.entries = @($config.bar.entries | Where-Object { $_.id -eq 'tray' })
$config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath "$profile\config\shell.json" -Encoding UTF8
# Keep Quickshell's isolated directory routing on the replacement entry.
$pragmas = @([regex]::Matches([IO.File]::ReadAllText("$stage\shell.qml"),
    '(?m)^//@ pragma (?:DataDir|StateDir|CacheDir) [^\r\n]+') | ForEach-Object { $_.Value })
if ($pragmas.Count -ne 3) { throw 'Expected three isolated profile-directory pragmas.' }
$fixture = [IO.File]::ReadAllText("$repoRoot\windows\tray-prototype\CompactTrayTest.qml")
[IO.File]::WriteAllText("$stage\shell.qml", (($pragmas -join "`n") + "`n" + $fixture), (New-Object Text.UTF8Encoding($false)))
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --path "' + (Join-Path $stage 'shell.qml') + '"'
$info.WorkingDirectory = $run
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$run\cache"
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['CAELESTIA_WINDOWS_TRAY'] = '0'
$info.EnvironmentVariables['CAELESTIA_WINDOWS_TRAY_ACTIVATION'] = '0'
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(15000)
if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
}
$output = $outTask.GetAwaiter().GetResult() + $errTask.GetAwaiter().GetResult()
$output | Set-Content -LiteralPath "$run\result.log" -Encoding UTF8
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and
    $output -match 'COMPACT_TRAY_PASS assertions=\d+' -and
    $output -notmatch 'COMPACT_TRAY_FAIL|ReferenceError|TypeError|SyntaxError|binding loop|Cannot assign|Unable to assign|accessed without a screen set on QQuickWheelHandler'
[ordered]@{ passed = $passed; exitCode = $process.ExitCode; log = "$run\result.log" } | ConvertTo-Json
if (-not $passed) { throw "Compact tray failed. See $run\result.log." }
