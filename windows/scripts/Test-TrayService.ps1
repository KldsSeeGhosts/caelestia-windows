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
$runName = 'tray-fixture-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$stage = Join-Path $BuildRoot "tray-tests\$runName"
$logRoot = Join-Path $BuildRoot 'logs'
New-Item -ItemType Directory -Force -Path $stage, $logRoot | Out-Null
# Copy only the state object and its fixture. No native backend, singleton or
# shell service is present in this stage, and qml.exe does not load Quickshell.
$sources = foreach ($name in @('TrayService.qml', 'TrayServiceTest.qml')) {
    $source = Join-Path $repoRoot "windows\services\tray\$name"
    $target = Join-Path $stage $name
    Copy-Item -LiteralPath $source -Destination $target
    [ordered]@{
        source = "windows/services/tray/$name"
        sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        stagedSha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}
# The state object must stay importable without Quickshell or the native
# SystemTray singleton. The fixture is the only other staged file and never
# constructs Tray.qml, so no tray host or timer can start in this process.
$serviceSource = Join-Path $repoRoot 'windows\services\tray\TrayService.qml'
$nativeImports = @(Select-String -LiteralPath $serviceSource -Pattern '^\s*import\s+Quickshell')
# Comments may name the backend; only code-level singleton/type usage counts.
$nativeReferences = @(Select-String -LiteralPath $serviceSource -Pattern '\bSystemTray\.|\bproperty\s+SystemTrayItem\b')
$hashMismatch = @($sources | Where-Object { $_.sourceSha256 -ne $_.stagedSha256 })
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '"' + (Join-Path $stage 'TrayServiceTest.qml') + '"'
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
$match = [regex]::Match($combined, 'CAELESTIA_TRAY_FIXTURE_PASS (\{[^\r\n]+\})')
$fixture = $(if ($match.Success) { $match.Groups[1].Value | ConvertFrom-Json } else { $null })
$diagnostics = @([regex]::Matches(
    $combined,
    '(?im)^.*(?:CAELESTIA_TRAY_FIXTURE_FAIL|ReferenceError|TypeError|SyntaxError|binding loop|Unable to assign|Cannot assign|is not a type|Cannot read property|is not defined|qml:.*is not).*$'
))
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and $match.Success -and
    $null -ne $fixture -and [int]$fixture.assertions -ge 70 -and
    $hashMismatch.Count -eq 0 -and $nativeImports.Count -eq 0 -and
    $nativeReferences.Count -eq 0 -and $diagnostics.Count -eq 0
$result = [ordered]@{
    passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode
    fixture = $fixture
    nativeImports = $nativeImports.Count
    nativeReferences = @($nativeReferences | ForEach-Object { $_.Line.Trim() })
    hashMismatch = @($hashMismatch)
    diagnostics = @($diagnostics | ForEach-Object { $_.Value })
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    runnerSha256 = (Get-FileHash -LiteralPath $exe).Hash
    command = $exe; arguments = $info.Arguments; sources = @($sources)
    stage = $stage; stdout = $stdoutPath; stderr = $stderrPath
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logRoot "$runName.json") -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $passed) { throw "Tray fixture failed. See $stdoutPath and $stderrPath." }
