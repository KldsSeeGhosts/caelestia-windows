[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $QtPrefix 'bin\qmltestrunner.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Missing Qt test runner: $runner" }
$source = Get-Content -LiteralPath "$repoRoot\windows\quota\modules\quota\Content.qml" -Raw
$fixture = Get-Content -LiteralPath "$repoRoot\windows\tests\QuotaProviderKeyboardTest.qml" -Raw

# Run the production provider delegate's complete behavioral declaration,
# including its actual control type, sizing, focus defaults and handlers.
# Omit only the visual children; replace data services with synthetic objects.
$matches = [regex]::Matches($source, '(?ms)^                        delegate: AbstractButton \{.*?^                            background:')
if ($matches.Count -ne 1) { throw 'Expected one quota provider delegate.' }
$delegate = $matches[0].Value
$delegate = $delegate.Substring(0, $delegate.LastIndexOf('background:')).TrimEnd() + "`n                        }"
$delegate = $delegate.Replace('Quota.', 'quota.').Replace('Logic.', 'logic.')
$fixture = $fixture.Replace('// PROVIDER_DELEGATE', $delegate)

$stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-quota-keyboard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$test = Join-Path $stage 'tst_QuotaProviderKeyboard.qml'
[IO.File]::WriteAllText($test, $fixture, (New-Object Text.UTF8Encoding($false)))
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $runner
$info.Arguments = '-input "' + $test + '" -o -,txt'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
$info.EnvironmentVariables['QT_QUICK_CONTROLS_STYLE'] = 'Basic'
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $stage 'cache'
$process = [Diagnostics.Process]::Start($info)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(20000)) {
    $process.Kill()
    $process.WaitForExit()
    throw "Quota provider keyboard test timed out: $stage"
}
$output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
Write-Output $output
if ($process.ExitCode -ne 0 -or $output -notmatch '7 passed, 0 failed' -or
    $output -match 'TypeError|ReferenceError|binding loop') {
    throw "Quota provider keyboard test failed (exit $($process.ExitCode)): $stage"
}
