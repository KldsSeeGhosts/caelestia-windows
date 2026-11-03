[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix)

# The keep-awake card's status line, spliced from production. A held display
# request with a PowerSetRequest or PowerClearRequest error must not say it is
# preventing sleep, and a clean release must not either.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $QtPrefix 'bin\qml.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Missing QML runner: $runner" }

function Get-UniqueMatch([string]$Text, [string]$Pattern) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected one production block matching: $Pattern" }
    return $matches[0].Value
}

$card = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\adapters\modules\utilities\cards\IdleInhibit.qml') -Raw
$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\IdleInhibitStatusTest.qml') -Raw
$status = Get-UniqueMatch $card '(?ms)^    function inhibitStatus\(permitted, smoke, held, error, requested\): string \{.*?^    \}\r?$'
if ($status -notmatch 'held && error === ""') { throw 'The success status no longer requires an error-free hold.' }
if ($card -notmatch 'preventingSleep: IdleHold\.held && IdleHold\.error === ""') { throw 'The active treatment no longer requires an error-free hold.' }
if ($card -match 'if \(IdleHold\.held\)\s*\r?\n\s*return Tr\.trCtx\("Preventing sleep mode"') { throw 'The card still treats any hold as preventing sleep.' }
$status = $status.Replace('Tr.trCtx', 'root.trCtx')
$fixture = $fixture.Replace('    // IDLE_STATUS', $status.TrimEnd())

$stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-idle-status-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $test = Join-Path $stage 'IdleInhibitStatusTest.qml'
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
        throw 'Idle status fixture timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Write-Output $output
    $marker = [regex]::Match($output, 'CAELESTIA_IDLE_STATUS_PASS 7\b')
    if ($process.ExitCode -ne 0 -or -not $marker.Success -or
        $output -match 'CAELESTIA_IDLE_STATUS_FAIL|TypeError|ReferenceError') {
        throw 'Idle status fixture failed.'
    }
    Write-Output 'PASS idle status: a display-only leftover is not preventing sleep, and a clean release is normal power management.'
} finally {
    $safeStage = [IO.Path]::GetFullPath($stage).TrimEnd('\')
    if ((Split-Path -Parent $safeStage) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $safeStage) -notlike 'caelestia-idle-status-*') {
        throw 'Unsafe idle status fixture cleanup path.'
    }
    Remove-Item -LiteralPath $safeStage -Recurse -Force
}
