# Pure services use explicit source lists; shell fixtures stage the real graph
# with dependency fakes. Both run offscreen from disposable temporary profiles.
# Apps keeps the repository layout for its cross-directory JS imports.
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
        # Keep the temporary stage and profile for debugging; logs always stay
        # under the build root.
        [switch]$Keep
    )

    $ErrorActionPreference = 'Stop'
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
    $BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
    $exe = Join-Path $QtPrefix 'bin\qml.exe'
    if ($UseQuickshell) { $exe = Join-Path $BuildRoot 'quickshell\qs.exe' }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing Qt QML runner: $exe" }
    if (-not $RunName) { $RunName = "$Name-fixture-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') }
    $run = Join-Path ([IO.Path]::GetTempPath()) ("caelestia-$RunName-" + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $run 'imports\qs'
    $logRoot = Join-Path $BuildRoot 'logs'
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
        $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$BuildRoot\install\qml\Caelestia\lib;$BuildRoot\install\qml\M3Shapes;$env:PATH"
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
    $info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
    if ($ShellFixture) {
        $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$run\imports;$stage\imports;$BuildRoot\install\qml;$QtPrefix\qml"
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
        if (-not $Keep) { Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
