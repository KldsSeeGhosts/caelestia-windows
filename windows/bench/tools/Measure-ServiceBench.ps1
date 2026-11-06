[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateSet('providers', 'audio', 'media', 'tray', 'notifications', 'quota')][string]$Area = 'providers',
    [string]$Plant = 'None',
    [ValidateRange(0, 100)][double]$PlantPercent = 25
)
$ErrorActionPreference = 'Stop'
Add-Type -Name ServiceBenchErrorMode -Namespace W -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint m);'
[W.ServiceBenchErrorMode]::SetErrorMode(0x8003) | Out-Null
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$profile = Join-Path $RunRoot 'profile'
& "$SourceRoot\windows\scripts\Stage-ShellPrototype.ps1" -Destination "$RunRoot\stage" -ProfileRoot $profile -Prototype shell-live | Out-Null
New-Item -ItemType Directory -Path "$RunRoot\stage\pure" | Out-Null
$pureSources = @('audio/AudioService.qml', 'media/PlayersService.qml', 'tray/TrayService.qml',
    'notifications/NotificationsService.qml', 'notifications/NotifData.qml')
$pureTypes = foreach ($source in $pureSources) {
    Copy-Item -LiteralPath "$SourceRoot\windows\services\$source" -Destination "$RunRoot\stage\pure"
    $file = [IO.Path]::GetFileName($source)
    [IO.Path]::GetFileNameWithoutExtension($file) + ' 1.0 ' + $file
}
$pureTypes | Set-Content "$RunRoot\stage\pure\qmldir" -Encoding ASCII
# QuotaLogic was added after some base revisions. A missing implementation is
# an unavailable workload, not a made-up zero cost or a different fixture.
$logic = Join-Path $SourceRoot 'windows\quota\modules\quota\QuotaLogic.js'
if ($Area -in @('providers', 'quota') -and -not (Test-Path -LiteralPath $logic)) {
    throw 'This revision has no QuotaLogic implementation to compare.'
}
New-Item -ItemType Directory -Force -Path "$RunRoot\stage\quota\modules\quota" | Out-Null
if (Test-Path -LiteralPath $logic) { Copy-Item -LiteralPath $logic -Destination "$RunRoot\stage\quota\modules\quota\QuotaLogic.js" }
else { '.pragma library' | Set-Content "$RunRoot\stage\quota\modules\quota\QuotaLogic.js" -Encoding UTF8 }
Copy-Item "$PSScriptRoot\..\Services.qml" "$RunRoot\shell.qml"
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --path "' + "$RunRoot\shell.qml" + '"'
$info.WorkingDirectory = $RunRoot
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
foreach ($name in @($info.EnvironmentVariables.Keys | Where-Object { $_ -match '^(CAELESTIA_|QS_|QSG_|QT_|QML_|XDG_)' })) {
    $info.EnvironmentVariables.Remove($name)
}
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$env:PATH"
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QT_QUICK_BACKEND'] = 'software'
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$RunRoot\cache"
$info.EnvironmentVariables['QS_RUNTIME_DIR'] = "$RunRoot\runtime"
$info.EnvironmentVariables['CAELESTIA_BENCH_AREA'] = $Area
$info.EnvironmentVariables['CAELESTIA_BENCH_PLANT'] = $Plant
$info.EnvironmentVariables['CAELESTIA_BENCH_PLANT_PERCENT'] = "$PlantPercent"
$process = [Diagnostics.Process]::Start($info)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit(20000)
    if ($timedOut) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
    $text = $stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText("$RunRoot\output.log", $text)
    if ($timedOut) { throw 'Adapter benchmark exceeded 20 seconds.' }
    if ($process.ExitCode -ne 0 -or $text -match 'CAELESTIA_SERVICE_BENCH_FAILED') { throw 'Adapter benchmark failed.' }
    $match = [regex]::Match($text, 'CAELESTIA_SERVICE_BENCH (\[[^\r\n]+\])')
    if (-not $match.Success) { throw 'No adapter work marker.' }
    [IO.File]::WriteAllText("$RunRoot\trial.json", $match.Groups[1].Value)
} finally { $process.Dispose() }
