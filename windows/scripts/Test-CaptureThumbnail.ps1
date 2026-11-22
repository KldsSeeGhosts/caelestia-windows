[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
. "$PSScriptRoot\Caelestia-InstallCommon.ps1"
$fixturePowerShell = Get-CaelestiaPowerShellPath
# The thumbnail keeps preview files in the OS temp directory. The fixture process
# gets its own temp directory, so nothing lands in the real one, and the final
# step checks that the fixture's directory is empty again.
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureTemp = Join-Path $tempRoot ('caelestia-thumbnail-temp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureTemp | Out-Null
$ownedStage = Enter-QmlSharedStage
try {
    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-thumbnail -ShellFixture -UseQuickshell `
        -Sources @('windows/tests/CaptureThumbnailTest.qml') -FixtureFile 'windows/tests/CaptureThumbnailTest.qml' `
        -Marker CAELESTIA_CAPTURE_THUMBNAIL -MinimumAssertions 250 -TimeoutMs 120000 `
        -Environment @{ TEMP = $fixtureTemp; TMP = $fixtureTemp; CAELESTIA_POWERSHELL = $fixturePowerShell }
    $scratchOld = New-Item -ItemType File -Path (Join-Path $fixtureTemp 'caelestia-clipboard-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png')
    $scratchFresh = New-Item -ItemType File -Path (Join-Path $fixtureTemp 'caelestia-clipboard-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png')
    $scratchForeign = New-Item -ItemType File -Path (Join-Path $fixtureTemp 'caelestia-clipboard-someone-elses.png')
    $scratchDrag = New-Item -ItemType Directory -Path (Join-Path $fixtureTemp 'caelestia-drag-cccccccccccccccccccccccccccccccc')
    $null = New-Item -ItemType File -Path (Join-Path $scratchDrag.FullName 'annotate-test.png')
    $scratchOld.LastWriteTime = (Get-Date).AddDays(-2)
    $scratchForeign.LastWriteTime = $scratchOld.LastWriteTime
    $scratchDrag.LastWriteTime = $scratchOld.LastWriteTime
    $history = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name screenshot-history -ShellFixture -UseQuickshell `
        -Sources @('windows/tests/ScreenshotHistoryTest.qml') -FixtureFile 'windows/tests/ScreenshotHistoryTest.qml' `
        -Marker CAELESTIA_SCREENSHOT_HISTORY -MinimumAssertions 41 -TimeoutMs 30000 `
        -Environment @{ TEMP = $fixtureTemp; TMP = $fixtureTemp; CAELESTIA_SCRATCH_FIXTURE = '1' }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureTemp)
    if ($resolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'caelestia-thumbnail-temp-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
    Exit-QmlSharedStage $ownedStage
}
$result | ConvertTo-Json -Depth 8
$history | ConvertTo-Json -Depth 8
foreach ($fixture in @($result, $history)) {
    if ($fixture.passed) { continue }
    $reason = if ($fixture.diagnostics.Count) { $fixture.diagnostics | Select-Object -First 4 }
        else { 'No failure marker. The last fixture messages follow.' }
    Write-Output $reason
    if (-not $fixture.diagnostics.Count) {
        foreach ($log in @($fixture.stdout, $fixture.stderr)) {
            Get-Content -LiteralPath $log -Tail 4
        }
    }
    throw "Capture fixture failed (exit=$($fixture.exitCode), timedOut=$($fixture.timedOut)). See $($fixture.stdout) and $($fixture.stderr)."
}
