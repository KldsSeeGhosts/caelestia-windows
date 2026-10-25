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

# Copy only the pure state objects and their fixtures. No native backend or
# singleton is present in this stage, and qml.exe does not load Quickshell or
# shell services.
$fixtures = @(
    [ordered]@{
        name = 'battery'; file = 'BatteryServiceTest.qml'
        passMarker = 'CAELESTIA_BATTERY_FIXTURE_PASS'
        failMarker = 'CAELESTIA_BATTERY_FIXTURE_FAIL'
        minimumAssertions = 128
        sources = @('BatteryService.qml', 'BatteryServiceTest.qml')
    },
    [ordered]@{
        name = 'profiles'; file = 'PowerProfilesServiceTest.qml'
        passMarker = 'CAELESTIA_POWER_PROFILES_FIXTURE_PASS'
        failMarker = 'CAELESTIA_POWER_PROFILES_FIXTURE_FAIL'
        minimumAssertions = 132
        sources = @('PowerProfilesService.qml', 'PowerProfilesServiceTest.qml', 'PowerProfilesBackend.qml')
    }
)

$stagedNames = @($fixtures | ForEach-Object { $_.sources } | Select-Object -Unique)
$sources = foreach ($name in $stagedNames) {
    $source = Join-Path $repoRoot "windows\services\battery\$name"
    $target = Join-Path $stage $name
    Copy-Item -LiteralPath $source -Destination $target
    [ordered]@{
        source = "windows/services/battery/$name"
        sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        stagedSha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}
# The state objects must stay importable without Quickshell or a native UPower
# singleton. The fixtures are the only other staged files and never construct
# Battery.qml, so no native backend can start in this process.
$nativeImports = @($stagedNames | ForEach-Object {
    @(Select-String -LiteralPath (Join-Path $repoRoot "windows\services\battery\$_") `
        -Pattern '^\s*import\s+Quickshell')
})
$hashMismatch = @($sources | Where-Object { $_.sourceSha256 -ne $_.stagedSha256 })

function Invoke-BatteryFixture($fixture) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '"' + (Join-Path $stage $fixture.file) + '"'
    $info.WorkingDirectory = $stage
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
    $info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $stage ("cache-" + $fixture.name)
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
    $stdoutPath = Join-Path $logRoot "$runName.$($fixture.name).stdout.log"
    $stderrPath = Join-Path $logRoot "$runName.$($fixture.name).stderr.log"
    $stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
    $stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8
    $combined = "$stdout`n$stderr"
    $match = [regex]::Match($combined, [regex]::Escape($fixture.passMarker) + ' (\{[^\r\n]+\})')
    $diagnosticPattern = '(?i)(' + [regex]::Escape($fixture.failMarker) + '|ReferenceError|TypeError|SyntaxError|binding loop|Unable to assign|Cannot assign|is not a type|Cannot read property|is not defined)'
    $passed = -not $timedOut -and $process.ExitCode -eq 0 -and $match.Success -and
        $combined -notmatch $diagnosticPattern
    [ordered]@{
        name = $fixture.name
        passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode
        fixture = $(if ($match.Success) { $match.Groups[1].Value | ConvertFrom-Json } else { $null })
        minimumAssertions = $fixture.minimumAssertions
        command = $exe; arguments = $info.Arguments
        stdout = $stdoutPath; stderr = $stderrPath
    }
}

$results = @($fixtures | ForEach-Object { Invoke-BatteryFixture $_ })
$batteryResult = $results | Where-Object { $_.name -eq 'battery' } | Select-Object -First 1
$profilesResult = $results | Where-Object { $_.name -eq 'profiles' } | Select-Object -First 1
$passed = ($results | Where-Object { -not $_.passed }).Count -eq 0 -and
    $hashMismatch.Count -eq 0 -and $nativeImports.Count -eq 0 -and
    [int]$batteryResult.fixture.assertions -ge 128 -and
    [int]$profilesResult.fixture.assertions -ge 132
$result = [ordered]@{
    passed = $passed
    timedOut = [bool]($results | Where-Object { $_.timedOut })
    exitCode = $batteryResult.exitCode
    battery = $batteryResult
    profiles = $profilesResult
    fixture = $batteryResult.fixture
    nativeImports = $nativeImports.Count
    hashMismatch = $hashMismatch
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    runnerSha256 = (Get-FileHash -LiteralPath $exe).Hash
    command = $exe; stage = $stage; sources = @($sources)
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logRoot "$runName.json") -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $passed) {
    $bad = @($results | Where-Object { -not $_.passed } | ForEach-Object {
        "Battery fixture '$($_.name)' failed. See $($_.stdout) and $($_.stderr)."
    })
    throw (($bad + 'Battery fixture validation failed.') -join "`n")
}
