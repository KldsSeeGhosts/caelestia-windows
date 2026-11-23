[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
function Invoke-CaptureRecording([string]$StageRoot, [string]$LogSuffix) {
    Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-recording -ShellFixture -UseQuickshell `
        -Sources @('windows/tests/CaptureRecordingTest.qml') -FixtureFile 'windows/tests/CaptureRecordingTest.qml' `
        -Marker CAELESTIA_CAPTURE_RECORDING -MinimumAssertions 22 -TimeoutMs 20000 `
        -StageRoot $StageRoot -LogSuffix $LogSuffix
}

$result = Invoke-CaptureRecording
if ($result.exitCode -eq -1 -and -not $result.timedOut -and $null -eq $result.fixture -and -not $result.diagnostics.Count) {
    $startupLog = Get-Content -LiteralPath @($result.stdout, $result.stderr)
    if ($env:CAELESTIA_TEST_SHARED_STAGE -and -not ($startupLog -match 'Configuration Loaded|CAELESTIA_CAPTURE_RECORDING_')) {
        # Quickshell exited before loading the fixture. Try once with a fresh
        # private stage instead of reusing the shared overlay's hard links.
        Write-Warning "Capture recording did not start from the shared stage. Retrying with a private stage. See $($result.stdout) and $($result.stderr)."
        $startupLog | Select-Object -Last 12 | Write-Warning
        $result = Invoke-CaptureRecording -StageRoot (Join-Path $env:CAELESTIA_TEST_SHARED_STAGE ([guid]::NewGuid().ToString('N'))) `
            -LogSuffix 'private-retry'
    }
}
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) {
    Get-Content -LiteralPath @($result.stdout, $result.stderr) -Tail 12
    throw "Capture recording fixture failed. See $($result.stdout) and $($result.stderr)."
}
