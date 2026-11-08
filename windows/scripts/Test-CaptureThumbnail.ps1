[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
# The thumbnail keeps preview files in the OS temp directory. The fixture process
# gets its own temp directory, so nothing lands in the real one, and the final
# step checks that the fixture's directory is empty again.
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureTemp = Join-Path $tempRoot ('caelestia-thumbnail-temp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureTemp | Out-Null
try {
    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-thumbnail -ShellFixture -UseQuickshell `
        -Sources @('windows/tests/CaptureThumbnailTest.qml') -FixtureFile 'windows/tests/CaptureThumbnailTest.qml' `
        -Marker CAELESTIA_CAPTURE_THUMBNAIL -MinimumAssertions 220 -TimeoutMs 120000 `
        -Environment @{ TEMP = $fixtureTemp; TMP = $fixtureTemp }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureTemp)
    if ($resolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'caelestia-thumbnail-temp-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Capture thumbnail fixture failed. See $($result.stderr)." }
