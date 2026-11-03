<#
.SYNOPSIS
Runs the pinned Windows backend's native regression fixtures and writes a JSON manifest.

.DESCRIPTION
The backend's Windows fixtures are a separate CMake project under
windows/deps/quickshell/src/windows/test. Build them first:

    windows\scripts\Build-Prototype.ps1 -Tests -BuildRoot C:\b-backend-tests ...

This script runs the fixtures that register with CTest from
<BuildRoot>\quickshell-tests, then runs any built fixture that the backend does
not register, so no compiled regression is left silently unexecuted. A fixture
that did not compile or link is a failure in the manifest. It is never skipped.
The manifest records the shell HEAD, the backend gitlink, the checked-out
backend revision and windows/sources.lock.json, the Qt and clang toolchain from
the test build's CMake cache, and each test's result, duration and skip reason.

Desktop-dependent fixtures are labelled under dependsOn and skipped only when
the process has no interactive desktop session. A fixture that cannot start is
a failure, not a skip.

The script exits non-zero when the shell's backend gitlink, the checked-out
backend and sources.lock.json disagree, when the backend has local changes, or
when any fixture fails to build or fails.

.PARAMETER BuildRoot
The build root passed to Build-Prototype.ps1. Defaults to
windows\.local\build, matching Build-Prototype.ps1. The test build must be at
<BuildRoot>\quickshell-tests.

.PARAMETER TestTimeoutSeconds
Per-test timeout for CTest and for each directly run fixture. Defaults to 120.

.EXAMPLE
windows\scripts\Test-BackendNative.ps1 -BuildRoot C:\b-backend-tests

Runs every fixture the build produced and writes
<BuildRoot>\backend-native-tests\manifest.json.

.EXAMPLE
windows\scripts\Test-BackendNative.ps1 -BuildRoot C:\b-backend-tests -TestTimeoutSeconds 300

Gives the slower fixtures five minutes each.
#>
[CmdletBinding()]
param(
    [string]$BuildRoot,
    [ValidateRange(1, 3600)][int]$TestTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$backend = Join-Path $repoRoot 'windows\deps\quickshell'
$testBuild = Join-Path $BuildRoot 'quickshell-tests'
$runRoot = Join-Path $BuildRoot ('backend-native-tests\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$ManifestPath = [IO.Path]::GetFullPath((Join-Path $BuildRoot 'backend-native-tests\manifest.json'))
$cachePath = Join-Path $testBuild 'CMakeCache.txt'
$buildLog = Join-Path $BuildRoot 'logs\build-backend-tests.log'

if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
    throw "The backend test build is missing: $testBuild. Run windows\scripts\Build-Prototype.ps1 -Tests -BuildRoot $BuildRoot first."
}
New-Item -ItemType Directory -Force -Path $runRoot, (Split-Path -Parent $ManifestPath) | Out-Null

$cache = Get-Content -LiteralPath $cachePath
function Get-CacheValue([string]$Name) {
    $prefix = $Name + ':'
    $line = $cache | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '=', 2)[1]
}

# A reconfigure can store a bare compiler name instead of its resolved path,
# so accept either and fall back to the build record for the version.
function Resolve-Executable([string]$Value) {
    if (-not $Value) { return $null }
    if (Test-Path -LiteralPath $Value -PathType Leaf) { return (Resolve-Path -LiteralPath $Value).Path }
    $command = Get-Command $Value -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

$qt6Dir = Get-CacheValue 'Qt6_DIR'
$qtPrefix = if ($qt6Dir) { ($qt6Dir -replace '/', '\') -replace '\\lib\\cmake\\Qt6$', '' } else { $null }
$qtPaths = if ($qtPrefix) { Resolve-Executable (Join-Path $qtPrefix 'bin\qtpaths.exe') } else { $null }
$compilerCommand = Resolve-Executable (Get-CacheValue 'CMAKE_CXX_COMPILER')
$cmakeCommand = Resolve-Executable (Get-CacheValue 'CMAKE_COMMAND')
$ninjaCommand = Resolve-Executable (Get-CacheValue 'CMAKE_MAKE_PROGRAM')
foreach ($required in @($qtPaths, $cmakeCommand, $ninjaCommand)) {
    if (-not $required) { throw "The test build cache does not name a usable Qt, CMake or Ninja toolchain." }
}

$buildRecordPath = Join-Path $BuildRoot 'logs\build.json'
$record = $null
if (Test-Path -LiteralPath $buildRecordPath -PathType Leaf) {
    $record = Get-Content -LiteralPath $buildRecordPath -Raw | ConvertFrom-Json
}
$qtVersion = (& $qtPaths --qt-version).Trim()
$clangVersion = if ($compilerCommand) { (@(& $compilerCommand --version))[0] }
    elseif ($record -and $record.compiler) { $record.compiler }
    else { 'clang version not recorded' }
$cmakeVersion = (@(& $cmakeCommand --version))[0]
$ninjaVersion = (@(& $ninjaCommand --version))[0]

$buildRecord = $null
if ($record) {
    $buildRecord = [ordered]@{
        path = $buildRecordPath
        builtAtUtc = $record.builtAtUtc
        sourceRevision = $record.sourceRevision
        backendRevision = $record.backendRevision
    }
}

# Fixtures that need the live shell or a real interactive window station.
# Everything else runs headless through the offscreen QPA, fakes and injected
# seams. A fixture with no entry is treated as headless.
$testTraits = @{
    panel_hidden_reembed = @{
        dependsOn = @('desktop')
        unavailableReason = 'needs an interactive desktop for the Windows QPA panel HWND regression'
    }
    mpris_app_identity = @{
        dependsOn = @('desktop')
        unavailableReason = 'needs an interactive desktop to resolve real shell app entries'
    }
}

function Get-TestTraits([string]$Name) {
    if ($testTraits.ContainsKey($Name)) { return $testTraits[$Name] }
    return @{ dependsOn = @(); unavailableReason = $null }
}

function Get-Totals([string]$Text) {
    if (-not $Text) { return $null }
    $match = [regex]::Match($Text, 'Totals: (\d+) passed, (\d+) failed(?:, (\d+) skipped)?')
    if (-not $match.Success) { return $null }
    return [ordered]@{
        passed = [int]$match.Groups[1].Value
        failed = [int]$match.Groups[2].Value
        skipped = if ($match.Groups[3].Success) { [int]$match.Groups[3].Value } else { 0 }
    }
}

function Get-FirstSkipReason([string]$Text) {
    if (-not $Text) { return $null }
    $match = [regex]::Match($Text, 'SKIP\s*:\s*([^\r\n]+)')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

# Map each missing target to the compiler or linker error that stopped it.
function Get-BuildFailureOutput([string]$LogPath, [string[]]$Targets) {
    $output = @{}
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return $output }
    $current = $null
    $collected = @{}
    foreach ($line in Get-Content -LiteralPath $LogPath) {
        if ($line -match '^FAILED:\s+\[code=\d+\]\s+(\S+)') {
            $artifact = $Matches[1]
            $current = $null
            foreach ($target in $Targets) {
                if ($artifact -match [regex]::Escape($target)) { $current = $target; break }
            }
            continue
        }
        if ($line -match '^\[\d+/\d+\]') { $current = $null; continue }
        if (-not $current) { continue }
        if ($line -match 'error LNK\d+|fatal error LNK\d+|error C\d+|fatal error C\d+|: error:') {
            if (-not $collected.ContainsKey($current)) {
                $collected[$current] = New-Object 'System.Collections.Generic.List[string]'
            }
            if (-not $collected[$current].Contains($line.Trim())) {
                $collected[$current].Add($line.Trim())
            }
        }
    }
    foreach ($target in $collected.Keys) { $output[$target] = ($collected[$target] -join "`n") }
    return $output
}

function Invoke-DirectFixture([string]$Executable, [string]$Name) {
    $log = Join-Path $runRoot "$Name.qt.txt"
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.Arguments = '-o "' + $log + '",txt'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $runRoot
    $started = [DateTime]::UtcNow
    $process = [Diagnostics.Process]::Start($info)
    $timedOut = -not $process.WaitForExit($TestTimeoutSeconds * 1000)
    if ($timedOut) {
        $process.Kill()
        $process.WaitForExit()
    }
    $exitCode = $process.ExitCode
    $process.Dispose()
    $duration = ([DateTime]::UtcNow - $started).TotalSeconds
    $text = ''
    if (Test-Path -LiteralPath $log) { $text = [string](Get-Content -LiteralPath $log -Raw) }
    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        Duration = $duration
        Output = $text
        Log = $log
    }
}

$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\sources.lock.json') -Raw | ConvertFrom-Json
$shellHead = (& git -C $repoRoot rev-parse HEAD).Trim()
$shellDirty = [bool]@(& git -C $repoRoot status --porcelain)
$gitlinkLine = & git -C $repoRoot ls-tree HEAD -- $lock.quickshell.path
if ($LASTEXITCODE -ne 0 -or -not $gitlinkLine) { throw "Could not read the backend gitlink from $repoRoot." }
$gitlink = ($gitlinkLine -split '\s+')[2]
$backendHead = (& git -C $backend rev-parse HEAD).Trim()
$backendDirty = [bool]@(& git -C $backend status --porcelain)
$lockRevision = $lock.quickshell.revision
$revisionMatches = ($gitlink -eq $backendHead) -and ($gitlink -eq $lockRevision)
$sessionId = (Get-Process -Id $PID).SessionId
$interactiveDesktop = [Environment]::UserInteractive -and $sessionId -ne 0

$manifest = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    passed = $false
    error = $null
    shell = [ordered]@{ head = $shellHead; dirty = $shellDirty }
    backend = [ordered]@{
        gitlink = $gitlink
        checkedOut = $backendHead
        sourcesLock = $lockRevision
        matches = $revisionMatches
        dirty = $backendDirty
    }
    toolchain = [ordered]@{
        qt = $qtVersion
        qtPrefix = $qtPrefix
        clang = $clangVersion
        cmake = $cmakeVersion
        ninja = $ninjaVersion
        windows = [Environment]::OSVersion.VersionString
        source = $cachePath
    }
    buildRecord = $buildRecord
    environment = [ordered]@{
        interactiveDesktop = $interactiveDesktop
        sessionId = $sessionId
        testBuildDir = $testBuild
        runDir = $runRoot
        testTimeoutSeconds = $TestTimeoutSeconds
    }
    commands = [ordered]@{ ctest = $null; direct = @(); buildLog = $buildLog }
    totals = [ordered]@{
        fixtures = 0; passed = 0; failed = 0; skipped = 0
        ctestRegistered = 0; ctestUnregistered = 0; wallSeconds = 0
    }
    tests = @()
}

function Write-Manifest {
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}

if (-not $revisionMatches) {
    $manifest.error = "Backend revision mismatch: gitlink $gitlink, checked-out $backendHead, sources.lock $lockRevision."
} elseif ($backendDirty) {
    $manifest.error = "The backend has local changes at $backend. The fixtures would not test the pinned revision."
}
if ($manifest.error) {
    Write-Manifest
    throw "$($manifest.error) Manifest: $ManifestPath"
}

# The tests need the Qt runtime. CTest ships beside the cmake that configured
# the test build.
$env:PATH = "$qtPrefix\bin;$(Split-Path -Parent $cmakeCommand);$env:PATH"
$started = [DateTime]::UtcNow

# CTest is the registration of record. Parse its listing to pair each test name
# with its executable, then run every built fixture the backend did not
# register directly.
$listLog = Join-Path $runRoot 'ctest-list.log'
$ErrorActionPreference = 'Continue'
& ctest --test-dir $testBuild -N -V *>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath $listLog -Encoding UTF8
$listExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($listExit -ne 0) { throw "ctest -N failed. See $listLog." }

$commands = @{}
$names = @{}
foreach ($line in Get-Content -LiteralPath $listLog) {
    if ($line -match '^\s*(\d+): Test command:\s*(.*)$') {
        $commands[[int]$Matches[1]] = $Matches[2].Trim()
        continue
    }
    if ($line -match '^\s*Test\s+#(\d+):\s+(.+)$') {
        $names[[int]$Matches[1]] = $Matches[2].Trim()
    }
}
$registered = New-Object 'System.Collections.Generic.List[object]'
foreach ($id in ($names.Keys | Sort-Object)) {
    $executable = $null
    $command = $commands[$id]
    if ($command) {
        if ($command -match '^"([^"]+)"') { $executable = $Matches[1] }
        else { $executable = ($command -split '\s+')[0] }
    }
    $registered.Add([pscustomobject]@{ name = $names[$id]; executable = $executable })
}
if ($registered.Count -eq 0) { throw "CTest registered no tests in $testBuild. See $listLog." }

# Every qs_add_test_executable target must produce an executable. A missing one
# is a build failure with the build log as its evidence, never a silent gap.
$testCmake = Join-Path $backend 'src\windows\test\CMakeLists.txt'
$declaredTargets = @([regex]::Matches((Get-Content -LiteralPath $testCmake -Raw), 'qs_add_test_executable\((\w+)') |
    ForEach-Object { $_.Groups[1].Value })
if ($declaredTargets.Count -eq 0) { throw "No test targets were declared in $testCmake." }
$buildFailures = @{}
foreach ($target in $declaredTargets) {
    $executable = Join-Path $testBuild "$target.exe"
    if (Test-Path -LiteralPath $executable -PathType Leaf) { continue }
    $registeredEntry = $registered | Where-Object {
        ($_.executable -and ([IO.Path]::GetFileName($_.executable) -ieq "$target.exe")) -or
        ($_.name -eq ($target -replace '_test$', ''))
    } | Select-Object -First 1
    $name = if ($registeredEntry) { $registeredEntry.name } else { $target -replace '_test$', '' }
    $buildFailures[$name] = [pscustomobject]@{
        target = $target; executable = $executable; registered = [bool]$registeredEntry
    }
}
$buildErrors = Get-BuildFailureOutput $buildLog $declaredTargets

$registeredExes = @{}
foreach ($entry in $registered) {
    if (-not $entry.executable) { continue }
    $registeredExes[([IO.Path]::GetFullPath($entry.executable)).ToLowerInvariant()] = $true
}
$built = @(Get-ChildItem -LiteralPath $testBuild -Filter '*_test.exe' -File -Recurse | Sort-Object Name)
$unregistered = @($built | Where-Object {
    -not $registeredExes.ContainsKey($_.FullName.ToLowerInvariant())
})

$skipped = @{}
if (-not $interactiveDesktop) {
    foreach ($entry in $registered) {
        $traits = Get-TestTraits $entry.name
        if ($traits.dependsOn -contains 'desktop') {
            $skipped[$entry.name] = $traits.unavailableReason
        }
    }
}

$excluded = @{}
foreach ($name in $buildFailures.Keys) { $excluded[$name] = $true }
foreach ($name in $skipped.Keys) { $excluded[$name] = $true }

$junitPath = Join-Path $runRoot 'ctest-junit.xml'
$ctestLog = Join-Path $runRoot 'ctest.log'
$ctestArguments = @('--test-dir', $testBuild, '--output-on-failure', '--timeout', "$TestTimeoutSeconds",
    '--output-junit', $junitPath, '--no-tests=error')
if ($excluded.Count -gt 0) {
    $pattern = '^(' + (($excluded.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
    $ctestArguments += @('--exclude-regex', $pattern)
}
$manifest.commands.ctest = 'ctest ' + ($ctestArguments -join ' ')
# Run from the disposable run directory. CTest still executes each fixture in
# its own build directory, never the repository or a home directory.
Push-Location -LiteralPath $runRoot
try {
    $ErrorActionPreference = 'Continue'
    & ctest @ctestArguments *>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $ctestLog
    $ctestExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath $junitPath -PathType Leaf)) {
    throw "CTest produced no JUnit result at $junitPath. See $ctestLog."
}

[xml]$junit = Get-Content -LiteralPath $junitPath -Raw
$cases = @{}
foreach ($case in $junit.SelectNodes('//testcase')) { $cases[$case.GetAttribute('name')] = $case }

$results = New-Object 'System.Collections.Generic.List[object]'
foreach ($entry in $registered) {
    $traits = Get-TestTraits $entry.name
    $result = 'failed'
    $duration = 0.0
    $skipReason = $null
    $failure = $null
    $skippedCases = $null
    $buildFailure = $null
    if ($buildFailures.ContainsKey($entry.name)) {
        $failed = $buildFailures[$entry.name]
        $errorText = $buildErrors[$failed.target]
        $failure = if ($errorText) { "Fixture $($failed.target) did not compile or link.`n$errorText" }
            else { "Fixture $($failed.target) did not compile or link. See $buildLog." }
        $buildFailure = [ordered]@{ target = $failed.target; output = $errorText; log = $buildLog }
    } elseif ($skipped.ContainsKey($entry.name)) {
        $result = 'skipped'
        $skipReason = $skipped[$entry.name]
    } elseif (-not $cases.ContainsKey($entry.name)) {
        $failure = "CTest produced no result for this test. See $ctestLog."
    } else {
        $case = $cases[$entry.name]
        $duration = [double]$case.GetAttribute('time')
        $failureNode = $case.SelectSingleNode('failure')
        $skippedNode = $case.SelectSingleNode('skipped')
        $totals = $null
        $systemOut = $case.SelectSingleNode('system-out')
        if ($systemOut) { $totals = Get-Totals $systemOut.InnerText }
        if ($failureNode) {
            $result = 'failed'
            $failure = $failureNode.InnerText.Trim()
        } elseif ($skippedNode) {
            $result = 'skipped'
            $skipReason = $skippedNode.GetAttribute('message')
            if (-not $skipReason) { $skipReason = 'CTest reported the test as skipped.' }
        } elseif ($totals -and $totals.passed -eq 0 -and $totals.failed -eq 0 -and $totals.skipped -gt 0) {
            $result = 'skipped'
            $skipReason = Get-FirstSkipReason $systemOut.InnerText
            if (-not $skipReason) { $skipReason = "Qt Test reported $($totals.skipped) skipped cases and no passes." }
        } else {
            $result = 'passed'
            if ($totals) { $skippedCases = $totals.skipped }
        }
    }
    $command = if ($entry.executable) { $entry.executable }
        elseif ($buildFailures.ContainsKey($entry.name)) { $buildFailures[$entry.name].executable }
        else { $null }
    $results.Add([ordered]@{
        name = $entry.name
        result = $result
        durationSeconds = [Math]::Round($duration, 3)
        skipReason = $skipReason
        skippedCases = $skippedCases
        ctestRegistered = $true
        dependsOn = @($traits.dependsOn)
        command = $command
        failure = $failure
        buildFailure = $buildFailure
    })
}

$directEnvironment = $env:QT_QPA_PLATFORM
$env:QT_QPA_PLATFORM = 'offscreen'
try {
    foreach ($exe in $unregistered) {
        $name = $exe.BaseName -replace '_test$', ''
        $traits = Get-TestTraits $name
        $result = 'failed'
        $duration = 0.0
        $skipReason = $null
        $failure = $null
        $skippedCases = $null
        if (-not $interactiveDesktop -and ($traits.dependsOn -contains 'desktop')) {
            $result = 'skipped'
            $skipReason = $traits.unavailableReason
        } else {
            $run = Invoke-DirectFixture $exe.FullName $name
            $duration = $run.Duration
            $manifest.commands.direct += "$($exe.FullName) -o $($run.Log),txt"
            $totals = Get-Totals $run.Output
            if ($run.TimedOut) {
                $failure = "Timed out after $TestTimeoutSeconds seconds. See $($run.Log)."
            } elseif ($run.ExitCode -ne 0) {
                $failure = "Exited with code $($run.ExitCode). See $($run.Log)."
            } elseif (-not $totals) {
                $failure = "Qt Test printed no Totals line. See $($run.Log)."
            } elseif ($totals.failed -gt 0) {
                $failure = "Qt Test reported $($totals.failed) failed cases. See $($run.Log)."
            } elseif ($totals.passed -eq 0 -and $totals.skipped -gt 0) {
                $result = 'skipped'
                $skipReason = Get-FirstSkipReason $run.Output
                if (-not $skipReason) { $skipReason = "Qt Test reported $($totals.skipped) skipped cases and no passes." }
            } else {
                $result = 'passed'
                $skippedCases = $totals.skipped
            }
        }
        $results.Add([ordered]@{
            name = $name
            result = $result
            durationSeconds = [Math]::Round($duration, 3)
            skipReason = $skipReason
            skippedCases = $skippedCases
            ctestRegistered = $false
            dependsOn = @($traits.dependsOn)
            command = $exe.FullName
            failure = $failure
            buildFailure = $null
        })
    }
} finally {
    if ($null -eq $directEnvironment) { Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue }
    else { $env:QT_QPA_PLATFORM = $directEnvironment }
}

foreach ($name in ($buildFailures.Keys | Sort-Object)) {
    $failed = $buildFailures[$name]
    if ($failed.registered) { continue }
    $errorText = $buildErrors[$failed.target]
    $failure = if ($errorText) { "Fixture $($failed.target) did not compile or link.`n$errorText" }
        else { "Fixture $($failed.target) did not compile or link. See $buildLog." }
    $results.Add([ordered]@{
        name = $name
        result = 'failed'
        durationSeconds = 0
        skipReason = $null
        skippedCases = $null
        ctestRegistered = $false
        dependsOn = @((Get-TestTraits $name).dependsOn)
        command = $failed.executable
        failure = $failure
        buildFailure = [ordered]@{ target = $failed.target; output = $errorText; log = $buildLog }
    })
}

$manifest.tests = $results.ToArray()
$manifest.totals.fixtures = $results.Count
$manifest.totals.passed = @($results | Where-Object { $_.result -eq 'passed' }).Count
$manifest.totals.failed = @($results | Where-Object { $_.result -eq 'failed' }).Count
$manifest.totals.skipped = @($results | Where-Object { $_.result -eq 'skipped' }).Count
$manifest.totals.ctestRegistered = $registered.Count
$manifest.totals.ctestUnregistered = $unregistered.Count
$manifest.totals.wallSeconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
$manifest.passed = $manifest.totals.failed -eq 0 -and $ctestExit -eq 0
Write-Manifest

$summary = "$($manifest.totals.passed) passed, $($manifest.totals.failed) failed, $($manifest.totals.skipped) skipped, " +
    "$($manifest.totals.fixtures) fixtures ($($manifest.totals.ctestRegistered) CTest, $($manifest.totals.ctestUnregistered) direct), " +
    "$($manifest.totals.wallSeconds) s. Manifest: $ManifestPath"
if (-not $manifest.passed) {
    foreach ($test in $results) {
        if ($test.result -eq 'failed') { Write-Output "FAIL $($test.name): $($test.failure)" }
    }
    throw "Backend native tests failed: $summary"
}
Write-Output "PASS backend native tests: $summary"
