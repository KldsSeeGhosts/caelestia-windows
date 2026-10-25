[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [switch]$Smoke,
    [ValidateSet('native', '1', '1.5', '1.75')][string]$ScaleFactor = 'native'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
foreach ($required in @($exe, "$QtPrefix\bin\Qt6Core.dll", "$qmlRoot\Caelestia\Config\qmldir")) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Build prerequisite missing: $required" }
}
$profileRoot = Join-Path $BuildRoot 'probe-profile'
$stage = & (Join-Path $PSScriptRoot 'Stage-Prototype.ps1') -Destination (Join-Path $BuildRoot 'probe') -ProfileRoot $profileRoot
foreach ($dir in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profileRoot $dir) | Out-Null
}
$config = Join-Path $profileRoot 'config\shell.json'
if (-not (Test-Path -LiteralPath $config)) {
    '{"bar":{"clock":{"showIcon":false,"showDate":true,"showSeconds":true}}}' |
        Set-Content -LiteralPath $config -Encoding UTF8
}
$logRoot = Join-Path $BuildRoot 'logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$runName = 'probe-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$screenshot = Join-Path $logRoot "$runName.png"
$info = New-Object System.Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '--no-color --path "' + (Join-Path $stage 'shell.qml') + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $profileRoot 'cache'
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = Join-Path $profileRoot 'config'
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = Join-Path $profileRoot 'state'
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = Join-Path $profileRoot 'runtime'
if ($ScaleFactor -ne 'native') {
    # Qt's global factor normally multiplies native DPI. For deterministic
    # rendering tests, disable that native factor only in this child process.
    $info.EnvironmentVariables['QT_ENABLE_HIGHDPI_SCALING'] = '0'
    $info.EnvironmentVariables['QT_SCALE_FACTOR'] = $ScaleFactor
    $info.EnvironmentVariables['QT_FONT_DPI'] = '96'
    $info.EnvironmentVariables.Remove('QT_SCREEN_SCALE_FACTORS')
    $info.EnvironmentVariables['QT_SCALE_FACTOR_ROUNDING_POLICY'] = 'PassThrough'
}
$info.EnvironmentVariables['CAELESTIA_PROBE_SCALE'] = $ScaleFactor
$info.EnvironmentVariables['CAELESTIA_PROBE_SMOKE'] = $(if ($Smoke) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_PROBE_SCREENSHOT'] = ([Uri]$screenshot).AbsoluteUri
$info.RedirectStandardOutput = $Smoke.IsPresent
$info.RedirectStandardError = $Smoke.IsPresent

$process = [Diagnostics.Process]::Start($info)
if (-not $Smoke) {
    Write-Output "Started component probe (PID $($process.Id)). Close its window when finished."
    return
}
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(20000)
if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
}
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath (Join-Path $logRoot "$runName.stdout.log") -Encoding UTF8
$stderr | Set-Content -LiteralPath (Join-Path $logRoot "$runName.stderr.log") -Encoding UTF8
$combined = "$stdout`n$stderr"
$runtimeDiagnostics = $combined -match '(?m)^\s*(WARN(?:ING)?|ERROR|FATAL|CRIT(?:ICAL)?)\b'
$passed = -not $timedOut -and -not $runtimeDiagnostics -and
    $process.ExitCode -eq 0 -and $combined.Contains('CAELESTIA_PROBE_PASS') -and
    (Test-Path -LiteralPath $screenshot)
Copy-Item -LiteralPath (Join-Path $stage 'sources.json') -Destination (Join-Path $logRoot "$runName.sources.json")
$result = [ordered]@{
    passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode; scaleFactor = $ScaleFactor
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    buildRecordSha256 = (Get-FileHash -LiteralPath (Join-Path $logRoot 'build.json')).Hash
    sources = "$logRoot\$runName.sources.json"
    screenshot = $screenshot; stdout = "$logRoot\$runName.stdout.log"; stderr = "$logRoot\$runName.stderr.log"
} | ConvertTo-Json
$result | Set-Content -LiteralPath (Join-Path $logRoot "$runName.json") -Encoding UTF8
Write-Output $result
if (-not $passed) { throw "Component probe failed. See $logRoot\$runName.stdout.log and $runName.stderr.log." }
