# Pure services use explicit source lists; shell fixtures stage the real graph
# with dependency fakes. Both run offscreen from disposable temporary profiles.
# Apps keeps the repository layout for its cross-directory JS imports.
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules

function Invoke-QmlFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$QtPrefix,
        [string]$BuildRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Sources,
        [Parameter(Mandatory)][string]$FixtureFile,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][int]$MinimumAssertions,
        [int]$TimeoutMs = 15000,
        [switch]$KeepRelativePaths,
        # Stage the unmodified production graph, then replace only dependencies
        # with recording fakes. Never extract or rewrite the component under test.
        [switch]$ShellFixture,
        [switch]$UseQuickshell,
        [switch]$Render,
        [string]$ShellConfig,
        [string[]]$FakeDirectories = @(),
        [string]$RunName,
        [string]$LogSuffix,
        # Explicit per-fixture flags, after the inherited live environment is
        # cleared. Control tests must replace native I/O with recording fakes.
        [hashtable]$Environment = @{},
        # Keep the temporary stage and profile for debugging.
        [switch]$Keep
    )

    $ErrorActionPreference = 'Stop'
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
    $BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
    # A verified installed release can supply the native runner for local
    # regression work. All staging, profiles and writes remain disposable.
    $nativeQml = Join-Path $BuildRoot 'install\qml'
    $nativeLibraries = Join-Path $nativeQml 'Caelestia\lib'
    $nativeRunner = Join-Path $BuildRoot 'quickshell\qs.exe'
    if ($env:CAELESTIA_TEST_RUNTIME_PREFIX) {
        $runtimePrefix = [IO.Path]::GetFullPath($env:CAELESTIA_TEST_RUNTIME_PREFIX)
        $nativeQml = Join-Path $runtimePrefix 'qml'
        $nativeLibraries = $runtimePrefix
        $nativeRunner = Join-Path $runtimePrefix 'qs.exe'
    }
    $exe = Join-Path $QtPrefix 'bin\qml.exe'
    if ($UseQuickshell) { $exe = $nativeRunner }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing Qt QML runner: $exe" }
    $platformPlugins = Join-Path $QtPrefix 'plugins\platforms'
    if (-not (Test-Path -LiteralPath (Join-Path $platformPlugins 'qoffscreen.dll') -PathType Leaf)) {
        throw 'The matching developer Qt offscreen platform plugin is required; no fixture was launched.'
    }
    if ($env:CAELESTIA_TEST_RUNTIME_PREFIX -and
        (Get-FileHash -LiteralPath (Join-Path $runtimePrefix 'Qt6Core.dll')).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $QtPrefix 'bin\Qt6Core.dll')).Hash) {
        throw 'The developer Qt and installed runtime differ; refusing to mix platform plugins.'
    }
    if (-not $RunName) { $RunName = "$Name-fixture-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') }
    $run = Join-Path ([IO.Path]::GetTempPath()) ("caelestia-$RunName-" + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $run 'imports\qs'
    # Binaries may belong to a different implementer. Never write into a shared
    # build root during a review; candidate gates supply one external log root.
    $logRoot = if ($env:CAELESTIA_TEST_OUTPUT_ROOT) { $env:CAELESTIA_TEST_OUTPUT_ROOT }
        else { Join-Path ([IO.Path]::GetTempPath()) ('caelestia-test-results\' + [guid]::NewGuid().ToString('N')) }
    New-Item -ItemType Directory -Force -Path $stage, $logRoot | Out-Null
    try {
    if ($ShellFixture) {
        & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination $stage -ProfileRoot (Join-Path $run 'profile') -Prototype shell-live | Out-Null
    }
    if ($FakeDirectories.Count -gt 0) {
        # Shell fakes overlay the staged prototype at its root. A pure-service
        # fixture has no staged graph, so its fakes are QML modules and are
        # staged beside the run directory instead.
        $fakeRoot = if ($ShellFixture) { $stage } else { $run }
        foreach ($directory in $FakeDirectories) {
            Copy-Item -Path (Join-Path $repoRoot "$directory\*") -Destination $fakeRoot -Recurse -Force
        }
    }
    $profile = Join-Path $run 'profile'
    foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
    }
    if ($ShellConfig) {
        $ShellConfig | Set-Content -LiteralPath (Join-Path $profile 'config\shell.json') -Encoding UTF8
    }
    $stagedSources = foreach ($source in $Sources) {
        $relative = if ($KeepRelativePaths) { $source } else { Split-Path -Leaf $source }
        $target = Join-Path $stage $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot $source) -Destination $target
        [ordered]@{ source = $source; staged = $relative }
    }

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $entryPoint = if ($KeepRelativePaths) { $FixtureFile } else { Split-Path -Leaf $FixtureFile }
    if ($ShellFixture -and $UseQuickshell) {
        # A fixture entry carries no directory pragmas of its own, so Quickshell
        # would sweep a per-run folder into the real user state/cache dirs.
        # Route them into the disposable profile, as the production entry does.
        $entryPath = Join-Path $stage $entryPoint
        $entryText = [IO.File]::ReadAllText($entryPath)
        if ($entryText -notmatch '(?m)^//@ pragma (DataDir|StateDir|CacheDir) ') {
            $header = @("DataDir $profile\data", "StateDir $profile\state", "CacheDir $profile\cache") |
                ForEach-Object { "//@ pragma $_" }
            [IO.File]::WriteAllText($entryPath, (($header -join "`n") + "`n" + $entryText),
                (New-Object Text.UTF8Encoding($false)))
        }
    }
    $info.Arguments = '"' + (Join-Path $stage $entryPoint) + '"'
    if ($UseQuickshell) { $info.Arguments = '--no-color --log-times --path ' + $info.Arguments }
    $info.WorkingDirectory = $stage
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($ShellFixture) {
        foreach ($variable in @($info.EnvironmentVariables.Keys)) {
            if ($variable -like 'CAELESTIA_*' -or $variable -like 'QS_*' -or $variable -like 'QML*') {
                $info.EnvironmentVariables.Remove($variable)
            }
        }
        $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$nativeLibraries;$nativeQml\M3Shapes;$env:PATH"
        $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
        $info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
        $info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
        $info.EnvironmentVariables['CAELESTIA_CACHE_DIR'] = "$profile\cache"
        $info.EnvironmentVariables['QS_RUNTIME_DIR'] = "$profile\runtime"
        $info.EnvironmentVariables['XDG_CONFIG_HOME'] = "$profile\config"
        $info.EnvironmentVariables['XDG_STATE_HOME'] = "$profile\state"
        $info.EnvironmentVariables['XDG_DATA_HOME'] = "$profile\data"
        $info.EnvironmentVariables['XDG_CACHE_HOME'] = "$profile\cache"
        $info.EnvironmentVariables['QS_DISABLE_CRASH_HANDLER'] = '1'
        $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
        $info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
    }
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    # Deployed products intentionally carry only qwindows.dll. Never let
    # qs.exe's qt.conf hide the matching SDK offscreen plugin from a fixture.
    $info.EnvironmentVariables['QT_PLUGIN_PATH'] = Join-Path $QtPrefix 'plugins'
    $info.EnvironmentVariables['QT_QPA_PLATFORM_PLUGIN_PATH'] = $platformPlugins
    foreach ($key in $Environment.Keys) {
        $info.EnvironmentVariables[$key] = [string]$Environment[$key]
    }
    $info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
    if ($ShellFixture) {
        $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$run\imports;$stage\imports;$nativeQml;$QtPrefix\qml"
        $info.EnvironmentVariables['QML2_IMPORT_PATH'] = $info.EnvironmentVariables['QML_IMPORT_PATH']
    } elseif ($FakeDirectories.Count -gt 0) {
        $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$run\imports"
        $info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$run\imports"
    }
    if ($Render) {
        $info.EnvironmentVariables.Remove('QT_QUICK_BACKEND')
        $info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
    } else {
        $info.EnvironmentVariables['QT_QUICK_BACKEND'] = 'software'
    }
    $cacheName = if ($LogSuffix) { "cache-$LogSuffix" } else { 'cache' }
    $info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $stage $cacheName
    $process = [Diagnostics.Process]::Start($info)
    try {
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMs)
        if ($timedOut) {
            $process.Kill()
            $process.WaitForExit()
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    $logName = if ($LogSuffix) { "$RunName.$LogSuffix" } else { $RunName }
    $stdoutPath = Join-Path $logRoot "$logName.stdout.log"
    $stderrPath = Join-Path $logRoot "$logName.stderr.log"
    $stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
    $stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8
    $combined = "$stdout`n$stderr"
    $match = [regex]::Match($combined, [regex]::Escape("${Marker}_PASS") + ' (\{[^\r\n]+\}|\d+)(?=\s|$)')
    $fixture = $null
    $diagnostics = @([regex]::Matches(
        $combined,
        '(?im)^.*(?:' + [regex]::Escape("${Marker}_FAIL") +
        '|ReferenceError|TypeError|SyntaxError|binding loop|Unable to assign|Cannot assign|Cannot read property|is not a type|is not a function|is not defined|Cannot call method|failed to load component|is not installed|Cannot use same item on different windows).*$'
    ) | ForEach-Object { $_.Value })
    if ($Render) {
        # Scene ownership warnings are regressions even when Qt exits cleanly.
        $diagnostics += @($combined -split '\r?\n' | Where-Object {
            $_ -match 'WARN scene:' -and
            $_ -notmatch 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
        })
    }
    if ($match.Success) {
        try {
            $payload = $match.Groups[1].Value
            $fixture = if ($payload.StartsWith('{')) { $payload | ConvertFrom-Json } else { [pscustomobject]@{ assertions = [int]$payload } }
        } catch {
            $diagnostics += "Invalid fixture result JSON: $($_.Exception.Message)"
        }
    }
    $passed = -not $timedOut -and $exitCode -eq 0 -and
        $null -ne $fixture -and [int]$fixture.assertions -ge $MinimumAssertions -and
        $diagnostics.Count -eq 0
    [ordered]@{
        passed = $passed; timedOut = $timedOut; exitCode = $exitCode
        fixture = $fixture; diagnostics = @($diagnostics)
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        sourceDirty = [bool](& git -C $repoRoot status --porcelain)
        qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
        runnerSha256 = (Get-FileHash -LiteralPath $exe).Hash
        command = $exe; arguments = $info.Arguments; sources = @($stagedSources)
        fakeDirectories = @($FakeDirectories)
        stage = if ($Keep) { $stage } else { $null }; stdout = $stdoutPath; stderr = $stderrPath
    }
    } finally {
        if (-not $Keep) {
            $resolvedRun = [IO.Path]::GetFullPath($run)
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if (-not $resolvedRun.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
                (Split-Path -Leaf $resolvedRun) -notlike 'caelestia-*') {
                throw 'Refusing fixture cleanup outside its owned temporary directory.'
            }
            Remove-Item -LiteralPath $resolvedRun -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
