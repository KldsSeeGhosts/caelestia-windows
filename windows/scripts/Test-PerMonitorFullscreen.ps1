[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $QtPrefix 'bin\qml.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Missing QML runner: $runner" }
$content = Get-Content -LiteralPath (Join-Path $repoRoot 'modules\drawers\ContentWindow.qml') -Raw
$notifs = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\services\notifications\Notifs.qml') -Raw
$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\PerMonitorFullscreenTest.qml') -Raw

function Get-UniqueMatch([string]$Text, [string]$Pattern) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected one production binding/function matching: $Pattern" }
    return $matches[0].Value
}
$special = Get-UniqueMatch $content '(?m)^\s*readonly property bool hasSpecialWorkspace: [^\r\n]+'
$normal = Get-UniqueMatch $content '(?m)^\s*readonly property bool hasFullscreenOnNormalWs: [^\r\n]+'
$fullscreen = Get-UniqueMatch $content '(?ms)^    readonly property bool hasFullscreen: \{.*?^    \}'
$toast = Get-UniqueMatch $notifs '(?ms)^    function hasFullscreen\(\): bool \{.*?^    \}'
$fixture = $fixture.Replace('// CONTENT_BINDINGS', (($special, $normal, $fullscreen) -join "`n").Replace('Hypr.', 'hypr.'))
$fixture = $fixture.Replace('// TOAST_FUNCTION', $toast.Replace('Hypr.', 'hypr.'))
$stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-fullscreen-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$test = Join-Path $stage 'PerMonitorFullscreenTest.qml'
[IO.File]::WriteAllText($test, $fixture, (New-Object Text.UTF8Encoding($false)))
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $runner
$info.Arguments = '"' + $test + '"'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
$process = [Diagnostics.Process]::Start($info)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(20000)) {
    $process.Kill()
    throw 'Per-monitor fullscreen fixture timed out.'
}
$output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
$exitCode = $process.ExitCode
Write-Output $output
if ($exitCode -ne 0 -or $output -notmatch 'CAELESTIA_PER_MONITOR_FULLSCREEN_PASS 13' -or
    $output -match 'CAELESTIA_PER_MONITOR_FULLSCREEN_FAIL|TypeError|ReferenceError|binding loop') {
    throw 'Per-monitor fullscreen fixture failed.'
}
