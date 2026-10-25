[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$exe = Join-Path $QtPrefix 'bin\qml.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing Qt QML runner: $exe" }
$runName = 'battery-fixture-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$stage = Join-Path $BuildRoot "battery-tests\$runName"
$logRoot = Join-Path $BuildRoot 'logs'
New-Item -ItemType Directory -Force -Path $stage, $logRoot | Out-Null
# Copy only the state object and its fixtures. No native backend or singleton is
# present in this stage, and qml.exe does not load Quickshell or shell services.
$sources = foreach ($name in @('BatteryService.qml', 'BatteryServiceTest.qml')) {
    $source = Join-Path $repoRoot "windows\services\battery\$name"
    $target = Join-Path $stage $name
    Copy-Item -LiteralPath $source -Destination $target
    [ordered]@{
        source = "windows/services/battery/$name"
        sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        stagedSha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '"' + (Join-Path $stage 'BatteryServiceTest.qml') + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $stage 'cache'
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(15000)
if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
}
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$stdoutPath = Join-Path $logRoot "$runName.stdout.log"
$stderrPath = Join-Path $logRoot "$runName.stderr.log"
$stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
$stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8
$combined = "$stdout`n$stderr"
$match = [regex]::Match($combined, 'CAELESTIA_BATTERY_FIXTURE_PASS (\{[^\r\n]+\})')
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and $match.Success -and
    $combined -notmatch '(?i)(CAELESTIA_BATTERY_FIXTURE_FAIL|ReferenceError|TypeError|binding loop|Unable to assign|not available|is not a type)'
$result = [ordered]@{
    passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode
    fixture = $(if ($match.Success) { $match.Groups[1].Value | ConvertFrom-Json } else { $null })
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    runnerSha256 = (Get-FileHash -LiteralPath $exe).Hash
    command = $exe; arguments = $info.Arguments; sources = @($sources)
    stage = $stage; stdout = $stdoutPath; stderr = $stderrPath
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logRoot "$runName.json") -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $passed) { throw "Battery fixture failed. See $stdoutPath and $stderrPath." }
