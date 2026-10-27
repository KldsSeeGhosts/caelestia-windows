[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $QtPrefix 'bin\qml.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Missing QML runner: $runner" }
$interactions = Get-Content -LiteralPath (Join-Path $repoRoot 'modules\drawers\Interactions.qml') -Raw
$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\LauncherHoverCloseTest.qml') -Raw

function Get-UniqueMatch([string]$Text, [string]$Pattern) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected one production block matching: $Pattern" }
    return $matches[0].Value
}

# Exercise the real launcher hover policy and the real pointer-leave tail.
$policy = Get-UniqueMatch $interactions '(?ms)^    // Upstream b6b2adf0.*?^    \}\r?\n'
$leave = Get-UniqueMatch $interactions '(?ms)^            // Only close a launcher.*?updateLauncherHover\(false\);'
$leave = $leave.Replace('Config.', 'root.config.')

# The fixture cannot exercise these call sites, so require them statically.
$null = Get-UniqueMatch $interactions '(?m)^        if \(Config\.launcher\.enabled && Config\.launcher\.showOnHover\)\r?\n            updateLauncherHover\(inBottomPanel\(panels\.launcher, x, y\)\);\r?$'
$null = Get-UniqueMatch $interactions '(?m)^                root\.launcherHoverEntered = false;\r?$'
$null = Get-UniqueMatch $interactions '(?m)^        launcherResizeGuard = false;\r?$'
$null = Get-UniqueMatch $interactions '(?m)^                root\.launcherResizeGuard = true;\r?$'

$fixture = $fixture.Replace('    // LAUNCHER_HOVER_FUNCTION', $policy.TrimEnd())
$fixture = $fixture.Replace('        // LAUNCHER_LEAVE_BODY', $leave.TrimEnd())

$stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-launcher-hover-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$test = Join-Path $stage 'LauncherHoverCloseTest.qml'
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
    throw 'Launcher hover fixture timed out.'
}
$output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
$exitCode = $process.ExitCode
Write-Output $output
if ($exitCode -ne 0 -or $output -notmatch 'CAELESTIA_LAUNCHER_HOVER_PASS 13' -or
    $output -match 'CAELESTIA_LAUNCHER_HOVER_FAIL|TypeError|ReferenceError|binding loop') {
    throw 'Launcher hover fixture failed.'
}
