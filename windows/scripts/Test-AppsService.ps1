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
$runName = 'apps-fixture-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$stage = Join-Path $BuildRoot "apps-tests\$runName"
$logRoot = Join-Path $BuildRoot 'logs'
New-Item -ItemType Directory -Force -Path $stage, $logRoot | Out-Null

# Stage the pure state object, the frequency store, its path policy, the search
# libraries and the fixture. No native backend, Quickshell module, singleton or
# shell component is present; qml.exe cannot load Quickshell in this stage.
$sources = foreach ($entry in @(
        @('windows/services/apps/AppsService.qml', 'windows/services/apps/AppsService.qml'),
        @('windows/services/apps/AppFrequencyStore.qml', 'windows/services/apps/AppFrequencyStore.qml'),
        @('windows/services/apps/AppStoragePath.js', 'windows/services/apps/AppStoragePath.js'),
        @('windows/services/apps/AppsServiceTest.qml', 'windows/services/apps/AppsServiceTest.qml'),
        @('utils/scripts/fzf.js', 'utils/scripts/fzf.js'),
        @('utils/scripts/fuzzysort.js', 'utils/scripts/fuzzysort.js'))) {
    $source = Join-Path $repoRoot $entry[0]
    $target = Join-Path $stage $entry[1]
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
    [ordered]@{
        source = $entry[0]; staged = $entry[1]
        sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        stagedSha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}

# The state object and frequency store must stay importable without Quickshell
# or a native singleton, and the fixture is the only entry point.
$nativeImports = @(
    foreach ($name in @('AppsService.qml', 'AppFrequencyStore.qml')) {
        Select-String -LiteralPath (Join-Path $repoRoot "windows\services\apps\$name") `
            -Pattern '^\s*import\s+Quickshell'
    }
)
$hashMismatch = @($sources | Where-Object { $_.sourceSha256 -ne $_.stagedSha256 })
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '"' + (Join-Path $stage 'windows\services\apps\AppsServiceTest.qml') + '"'
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
$match = [regex]::Match($combined, 'CAELESTIA_APPS_FIXTURE_PASS (\{[^\r\n]+\})')
$fixture = $(if ($match.Success) { $match.Groups[1].Value | ConvertFrom-Json } else { $null })
$diagnostics = @([regex]::Matches(
    $combined,
    '(?im)^.*(?:CAELESTIA_APPS_FIXTURE_FAIL|ReferenceError|TypeError|SyntaxError|binding loop|Unable to assign|Cannot assign|is not a type|Cannot read property|is not defined).*$'
))
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and $match.Success -and
    $null -ne $fixture -and [int]$fixture.assertions -ge 100 -and
    $hashMismatch.Count -eq 0 -and $nativeImports.Count -eq 0 -and $diagnostics.Count -eq 0
$result = [ordered]@{
    passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode
    fixture = $fixture
    nativeImports = $nativeImports.Count
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
if (-not $passed) { throw "Apps fixture failed. See $stdoutPath and $stderrPath." }
