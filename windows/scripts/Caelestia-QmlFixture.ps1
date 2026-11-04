# Stage only pure services and recording fakes, never the shell/native wrappers.
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
        [string]$RunName,
        [string]$LogSuffix
    )

    $ErrorActionPreference = 'Stop'
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
    $BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
    $exe = Join-Path $QtPrefix 'bin\qml.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing Qt QML runner: $exe" }
    if (-not $RunName) { $RunName = "$Name-fixture-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') }
    $stage = Join-Path $BuildRoot "$Name-tests\$runName"
    $logRoot = Join-Path $BuildRoot 'logs'
    New-Item -ItemType Directory -Force -Path $stage, $logRoot | Out-Null
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
    $info.WorkingDirectory = $stage
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
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
    $match = [regex]::Match($combined, [regex]::Escape("${Marker}_PASS") + ' (\{[^\r\n]+\})')
    $fixture = $null
    $diagnostics = @([regex]::Matches(
        $combined,
        '(?im)^.*(?:' + [regex]::Escape("${Marker}_FAIL") +
        '|ReferenceError|TypeError|SyntaxError|binding loop|Unable to assign|Cannot assign|Cannot read property|is not a type|is not a function|is not defined|Cannot call method).*$'
    ) | ForEach-Object { $_.Value })
    if ($match.Success) {
        try {
            $fixture = $match.Groups[1].Value | ConvertFrom-Json
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
        stage = $stage; stdout = $stdoutPath; stderr = $stderrPath
    }
}
