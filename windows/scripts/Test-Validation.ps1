#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Packaging', 'Services', 'Shell', 'Scheme')][string]$Suite = 'Unit',
    [string]$QtPrefix,
    [string]$BuildRoot,
    [string]$RuntimePrefix,
    [string]$Python = 'python',
    [string]$OutputRoot,
    [ValidateRange(1, 4)][int]$QmlJobs = 1,
    [ValidateSet('1/2', '2/2', '1/3', '2/3', '3/3')][string]$Shard,
    [switch]$ListTests
)

$ErrorActionPreference = 'Stop'
# One inventory for both the unsharded Unit suite and hosted shards. Hosted
# run 42705595080 measured Test-CIAcceleration at 127s, Test-PairContract and
# toolchain-modules at 91s and 34s, and all remaining checks together at about
# 139s. Keep this order for unsharded runs.
$unitTests = @(
    @{ name = 'Test-PublicDocs'; shard = 3; kind = 'script' }
    @{ name = 'Test-Toolchain'; shard = 3; kind = 'script' }
    @{ name = 'Test-Versioning'; shard = 3; kind = 'script' }
    @{ name = 'Test-PairContract'; shard = 2; kind = 'script' }
    @{ name = 'Test-NexusPipeline'; shard = 3; kind = 'script'; extra = @('-Python', $Python) }
    @{ name = 'Test-CaptureIntegration'; shard = 3; kind = 'script' }
    @{ name = 'llvm-extraction'; shard = 3; kind = 'python'; arguments = @('-I', '-B', 'windows/tests/LlvmExtract.test.py'); outputDirectory = 'llvm-extraction' }
    @{ name = 'toolchain-modules'; shard = 2; kind = 'python'; arguments = @('-B', 'windows/tests/ToolchainModules.test.py'); outputDirectory = 'toolchain-modules' }
    @{ name = 'Test-CIChanges'; shard = 3; kind = 'script' }
    @{ name = 'Test-CIAcceleration'; shard = 1; kind = 'script' }
    @{ name = 'Test-SchemeProbeGuard'; shard = 3; kind = 'script' }
    @{ name = 'Test-KsgSettingsImport'; shard = 3; kind = 'script' }
    @{ name = 'Test-ShellLifecycle'; shard = 3; kind = 'script' }
    @{ name = 'Test-ValidationCounts'; shard = 3; kind = 'script' }
    @{ name = 'Test-RepositoryPolicy'; shard = 3; kind = 'script' }
    @{ name = 'javascript'; shard = 3; kind = 'node'; testCountPattern = '(?m)^# tests ([0-9]+)\s*$' }
    @{ name = 'quota-providers'; shard = 3; kind = 'python'; arguments = @('-B', '-m', 'unittest', 'discover', '-s', 'windows/tests/quota_providers', '-v'); testCountPattern = '(?m)^Ran ([0-9]+) tests?\b' }
)
# One inventory for both the unsharded suite and hosted shards. Warm hosted
# 42421527915/2 measured VersionedInstall at 139.45s and the remainder at
# 145.90s. Colour regressions run only beside shard 1 in the workflow.
$packagingTests = @(
    @{ name = 'Test-UpdateTrust'; shard = 2 }
    @{ name = 'Test-NexusUpdate'; shard = 2 }
    @{ name = 'Test-NexusWorker'; shard = 2; outputParameter = '-OutputRoot'; directory = 'nexus-worker' }
    @{ name = 'Test-SourceAssets'; shard = 2; outputParameter = '-OutputDirectory'; directory = 'source-assets' }
    @{ name = 'Test-SupportBundle'; shard = 2; outputParameter = '-OutputDirectory'; directory = 'support-bundle' }
    @{ name = 'Test-VersionedInstall'; shard = 1 }
    @{ name = 'Test-UninstallTransaction'; shard = 2; outputParameter = '-OutputRoot'; directory = 'uninstall-transactions' }
    @{ name = 'Test-CaptureRelease'; shard = 2; outputParameter = '-OutputRoot'; directory = 'capture-release' }
)
if (($Shard -or $ListTests) -and $Suite -notin @('Unit', 'Packaging')) {
    throw 'Shard and ListTests apply only to Unit and Packaging.'
}
if ($Shard) {
    $expectedDenominator = if ($Suite -eq 'Unit') { 3 } else { 2 }
    if ([int]$Shard.Split('/')[1] -ne $expectedDenominator) {
        throw "Shard $Shard does not match the $Suite suite."
    }
}
if ($QmlJobs -ne 1 -and $Suite -ne 'Shell') { throw 'QmlJobs applies only to Shell.' }
if (@($unitTests | Where-Object { $_.shard -isnot [int] -or $_.shard -notin @(1, 2, 3) }).Count -or
    @($unitTests.name | Select-Object -Unique).Count -ne $unitTests.Count) {
    throw 'Every unit test requires exactly one valid shard assignment and a unique name.'
}
if (@($packagingTests | Where-Object { $_.shard -notin @(1, 2) }).Count -or
    @($packagingTests.name | Select-Object -Unique).Count -ne $packagingTests.Count) {
    throw 'Every packaging test requires exactly one valid shard assignment and a unique name.'
}
$selectedUnitTests = @($unitTests | Where-Object { -not $Shard -or $_.shard -eq [int]$Shard.Split('/')[0] })
$selectedPackagingTests = @($packagingTests | Where-Object { -not $Shard -or $_.shard -eq [int]$Shard.Split('/')[0] })
if ($ListTests) {
    $selectedTests = if ($Suite -eq 'Unit') { $selectedUnitTests } else { $selectedPackagingTests }
    ConvertTo-Json -InputObject @($selectedTests.name)
    return
}
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
if (-not $OutputRoot) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-validation-' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($OutputRoot -eq $repoRoot -or $OutputRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Validation output must stay outside the source checkout.'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$env:CAELESTIA_TEST_OUTPUT_ROOT = $OutputRoot
$env:PYTHONDONTWRITEBYTECODE = '1'
if ($RuntimePrefix) { $env:CAELESTIA_TEST_RUNTIME_PREFIX = [IO.Path]::GetFullPath($RuntimePrefix) }
if ($RuntimePrefix -and -not $BuildRoot) { $BuildRoot = $RuntimePrefix }
if ($Suite -in @('Services', 'Shell') -and -not $QtPrefix) { throw 'QtPrefix is required for QML fixtures.' }
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results = New-Object 'System.Collections.Generic.List[object]'
$completed = $false

function Invoke-ValidationStep([string]$Name, [string]$Executable, [string[]]$CommandArguments, [string]$TestCountPattern = '') {
    $Executable = (Get-Command $Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $logPath = Join-Path $OutputRoot ($Name + '.log')
    # Tests can emit harmless diagnostics on stderr. Only their native exit
    # code decides success; every fixture also checks its assertion floor.
    $ErrorActionPreference = 'Continue'
    & $Executable @CommandArguments 2>&1 | ForEach-Object { "$_" } |
        Set-Content -LiteralPath $logPath -Encoding UTF8
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $testCount = $null
    if ($TestCountPattern) {
        $counts = [regex]::Matches([string](Get-Content -LiteralPath $logPath -Raw -Encoding UTF8), $TestCountPattern)
        if ($counts.Count) { $testCount = [int]$counts[$counts.Count - 1].Groups[1].Value }
        if ($null -eq $testCount -or $testCount -lt 1) {
            Add-Content -LiteralPath $logPath -Value 'Validation requires a nonzero reported test count.' -Encoding UTF8
            if ($code -eq 0) { $code = 1 }
        }
    }
    $results.Add([ordered]@{ name = $Name; exitCode = $code; testCount = $testCount; seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2) })
    Write-Output ("{0} {1} ({2:N2}s)" -f $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }), $Name, $clock.Elapsed.TotalSeconds)
    # The log is not uploaded, so show the end of a failure where it ran.
    if ($code -ne 0) {
        Write-Output "--- last 80 lines of $Name ---"
        Get-Content -LiteralPath $logPath -Tail 80 -Encoding UTF8
        Write-Output "--- end of $Name ---"
    }
}

function Invoke-ScriptCheck([string]$Name, [string[]]$Extra = @()) {
    Invoke-ValidationStep $Name $powershell (@('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot "$Name.ps1")) + $Extra)
}

function Invoke-UnitValidation([hashtable]$Test) {
    switch ($Test.kind) {
        'script' {
            $extra = @()
            if ($Test.extra) { $extra = @($Test.extra) }
            Invoke-ScriptCheck $Test.name $extra
        }
        'python' {
            $arguments = @($Test.arguments)
            if ($Test.outputDirectory) {
                $arguments += @('--output-root', (Join-Path $OutputRoot $Test.outputDirectory))
            }
            Invoke-ValidationStep $Test.name $Python $arguments $Test.testCountPattern
        }
        'node' {
            $node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            $javascript = @(Get-ChildItem -LiteralPath "$repoRoot\windows\tests" -Filter '*.test.js' -File | Sort-Object Name | ForEach-Object FullName)
            if (-not $javascript.Count) { throw 'No JavaScript regressions were discovered.' }
            Invoke-ValidationStep $Test.name $node (@('--test', '--test-reporter=tap') + $javascript) $Test.testCountPattern
        }
        default { throw "Unknown Unit check kind for $($Test.name)." }
    }
}

function ConvertTo-ValidationArgument([string]$Value) {
    # ProcessStartInfo.Arguments uses Windows command-line quoting, not
    # PowerShell source quoting. Preserve embedded quotes and trailing slashes.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    return '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
}

function Invoke-ParallelScriptChecks([string[]]$Names, [string[]]$Extra) {
    if (-not $Names.Count -or @($Names | Select-Object -Unique).Count -ne $Names.Count) {
        throw 'Parallel validation requires a nonempty, unique test inventory.'
    }
    $running = New-Object 'System.Collections.Generic.List[object]'
    $initialCount = $results.Count
    $next = 0
    try {
        while ($next -lt $Names.Count -or $running.Count) {
            while ($next -lt $Names.Count -and $running.Count -lt $QmlJobs) {
                $name = $Names[$next]
                $fixtureRoot = Join-Path $OutputRoot "fixtures\$name"
                New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
                $info = New-Object Diagnostics.ProcessStartInfo
                $info.FileName = $powershell
                $arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot "$name.ps1")) + $Extra
                $info.Arguments = ($arguments | ForEach-Object { ConvertTo-ValidationArgument $_ }) -join ' '
                $info.WorkingDirectory = $repoRoot
                $info.UseShellExecute = $false
                $info.CreateNoWindow = $true
                $info.RedirectStandardOutput = $true
                $info.RedirectStandardError = $true
                $info.EnvironmentVariables['CAELESTIA_TEST_OUTPUT_ROOT'] = $fixtureRoot
                $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
                $clock = [Diagnostics.Stopwatch]::StartNew()
                $process = [Diagnostics.Process]::Start($info)
                $running.Add([pscustomobject]@{
                    name = $name; process = $process; clock = $clock
                    stdout = $process.StandardOutput.ReadToEndAsync()
                    stderr = $process.StandardError.ReadToEndAsync()
                })
                $next++
            }
            foreach ($item in @($running | Where-Object { $_.process.HasExited })) {
                $item.process.WaitForExit()
                $seconds = [Math]::Round($item.clock.Elapsed.TotalSeconds, 2)
                $code = $item.process.ExitCode
                $stdout = $item.stdout.GetAwaiter().GetResult()
                $stderr = $item.stderr.GetAwaiter().GetResult()
                $logPath = Join-Path $OutputRoot ($item.name + '.log')
                "$stdout`n$stderr" | Set-Content -LiteralPath $logPath -Encoding UTF8
                $results.Add([ordered]@{ name = $item.name; exitCode = $code; testCount = $null; seconds = $seconds })
                Write-Output ("{0} {1} ({2:N2}s)" -f $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }), $item.name, $seconds)
                if ($code -ne 0) {
                    Write-Output "--- last 80 lines of $($item.name) ---"
                    Get-Content -LiteralPath $logPath -Tail 80 -Encoding UTF8
                    Write-Output "--- end of $($item.name) ---"
                }
                $item.process.Dispose()
                $null = $running.Remove($item)
            }
            if ($running.Count) { Start-Sleep -Milliseconds 50 }
        }
        if ($results.Count - $initialCount -ne $Names.Count) {
            throw 'Parallel validation did not complete every test.'
        }
    } finally {
        foreach ($item in $running) {
            try {
                if (-not $item.process.HasExited) {
                    # Kill only this invocation's owned tree on a launcher or
                    # logging error. Ordinary test failures still run all tests.
                    & "$env:SystemRoot\System32\taskkill.exe" /PID $item.process.Id /T /F | Out-Null
                }
            } finally { $item.process.Dispose() }
        }
    }
}

Push-Location -LiteralPath $repoRoot
try {
    if ($Suite -eq 'Unit') {
        # Fail before running any test when a script cannot even parse.
        foreach ($file in @((Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) +
            (Get-ChildItem -LiteralPath "$repoRoot\windows\ci" -Filter '*.ps1' -File))) {
            $tokens = $null
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "PowerShell syntax check failed: $($file.Name)" }
        }
        $map = Get-Content -LiteralPath "$repoRoot\windows\shell\sources.json" -Raw | ConvertFrom-Json
        if (@($map.PSObject.Properties.Name | Where-Object { $_ -match '(^|/)(tests?|fixtures|validation)/|Test\.qml$' }).Count) {
            throw 'Production staging must not include test fixtures.'
        }
        foreach ($test in $selectedUnitTests) { Invoke-UnitValidation $test }
    } elseif ($Suite -eq 'Packaging') {
        foreach ($test in $selectedPackagingTests) {
            $extra = @()
            if ($test.outputParameter) { $extra = @($test.outputParameter, (Join-Path $OutputRoot $test.directory)) }
            Invoke-ScriptCheck $test.name $extra
        }
    } elseif ($Suite -eq 'Scheme') {
        Invoke-ValidationStep 'scheme-worker' $Python @('-B', 'windows/scripts/scheme/test_win_scheme.py', '-v') '(?m)^Ran ([0-9]+) tests?\b'
    } else {
        $scripts = if ($Suite -eq 'Services') {
            @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*Service.ps1' -File | Sort-Object Name | ForEach-Object BaseName)
        } else {
            @('Test-AccessibilityLauncher', 'Test-AccessibilityNotifications',
              'Test-CaptureBackendApi', 'Test-CapturePicker', 'Test-CaptureThumbnail', 'Test-DragPreview', 'Test-HotplugTeardown', 'Test-IdleInhibitStatus', 'Test-LauncherHoverClose',
              'Test-PerMonitorFullscreen', 'Test-PinnedPopoutFocus', 'Test-QuotaPopovers',
              'Test-QuotaProviderKeyboard', 'Test-SessionSwitchBack', 'Test-WallpaperColours',
              'Test-WallpaperDefaults', 'Test-WallpaperFolder', 'Test-WallpaperHandback',
              'Test-WallpaperIpc', 'Test-WallpaperPreview', 'Test-WindowsBackground',
              'Test-UpdateManager', 'Test-UpdatesPage', 'Test-FileUrls')
        }
        if (-not $scripts.Count) { throw 'No QML regressions were discovered.' }
        $fixtureArguments = @('-QtPrefix', $QtPrefix)
        if ($BuildRoot) { $fixtureArguments += @('-BuildRoot', $BuildRoot) }
        if ($Suite -eq 'Shell' -and $QmlJobs -gt 1) {
            Invoke-ParallelScriptChecks $scripts $fixtureArguments
        } else {
            foreach ($name in $scripts) { Invoke-ScriptCheck $name $fixtureArguments }
        }
        if ($Suite -eq 'Services') {
            # This check resolves pinned backend/capture source files. The
            # Services job checks out recursive sources; the fast Unit job does not.
            Invoke-ValidationStep 'provider-support' $powershell @('-NoProfile', '-NonInteractive',
                '-File', (Join-Path $repoRoot 'windows/tests/Test-ProviderSupport.ps1'))
            Invoke-ScriptCheck 'Test-StagedServiceModels' @('-QtPrefix', $QtPrefix,
                '-OutputRoot', (Join-Path $OutputRoot 'staged-models'), '-MutationControls')
        }
    }
    $completed = $true
} finally {
    Pop-Location
    # This compact summary contains no commands, machine paths, profile data
    # or raw fixture output, so it is the only automatic CI test artifact.
    [ordered]@{
        schemaVersion = 1
        suite = $Suite
        shard = $Shard
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        sourceDirty = [bool](& git -C $repoRoot status --porcelain)
        passed = $completed -and $results.Count -gt 0 -and @($results | Where-Object { $_.exitCode -ne 0 }).Count -eq 0
        results = @($results.ToArray())
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
}
if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) { throw "Validation suite failed. See $OutputRoot." }
