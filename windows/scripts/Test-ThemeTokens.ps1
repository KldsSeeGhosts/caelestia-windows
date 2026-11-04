[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$run = Join-Path ([IO.Path]::GetTempPath()) ("caelestia-theme-test-" + [guid]::NewGuid())
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination "$run\stage" -ProfileRoot $profile -Prototype shell-live
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
}
# Keep Quickshell's isolated directory routing on the replacement entry.
$pragmas = @([regex]::Matches([IO.File]::ReadAllText("$stage\shell.qml"),
    '(?m)^//@ pragma (?:DataDir|StateDir|CacheDir) [^\r\n]+') | ForEach-Object { $_.Value })
if ($pragmas.Count -ne 3) { throw 'Expected three isolated profile-directory pragmas.' }
$fixture = [IO.File]::ReadAllText("$repoRoot\windows\tests\fixtures\ThemeTokensFixture.qml")
[IO.File]::WriteAllText("$stage\theme-fixture.qml", (($pragmas -join "`n") + "`n" + $fixture), (New-Object Text.UTF8Encoding($false)))
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --path "' + "$stage\theme-fixture.qml" + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
$info.EnvironmentVariables['THEME_TOKEN_TEST_FILE'] = "$profile\state\caelestia\theme-tokens.json"
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(15000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$output = $outTask.GetAwaiter().GetResult() + "`n" + $errTask.GetAwaiter().GetResult()
$output | Set-Content -LiteralPath "$run\result.log" -Encoding UTF8
if ($timedOut -or $process.ExitCode -ne 0 -or $output -notmatch 'THEME_TOKENS_FIXTURE_PASS' -or
    $output -match '(?i)THEME_TOKENS_FIXTURE_FAIL|TypeError|ReferenceError|binding loop|Unable to assign|Cannot assign|is not a type|Tokens.rounding accessed without a screen|Read of .*theme-tokens.json failed') {
    throw "Theme token fixture failed (artifacts: $run): $output"
}
Write-Output "Theme token fixture passed (artifacts: $run)"
