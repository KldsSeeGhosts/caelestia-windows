[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
# The picker leaves its hand-over files in the OS temp directory. The fixture
# process gets its own temp directory, so nothing lands in the real one.
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureTemp = Join-Path $tempRoot ('caelestia-picker-temp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureTemp | Out-Null
try {
    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-picker -ShellFixture -UseQuickshell `
        -Sources @('windows/tests/CapturePickerTest.qml') -FixtureFile 'windows/tests/CapturePickerTest.qml' `
        -Marker CAELESTIA_CAPTURE_PICKER -MinimumAssertions 150 -TimeoutMs 60000 `
        -Environment @{ TEMP = $fixtureTemp; TMP = $fixtureTemp }
    # Every label and icon of the toolbar, its popover and the thumbnail cards
    # lies on a whole device pixel at 100%, 125% and 150% scaling. It places the
    # real components itself, with no picker.
    $pixels = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-pixels -ShellFixture -UseQuickshell `
        -Sources @('windows/tests/CapturePixelsTest.qml') -FixtureFile 'windows/tests/CapturePixelsTest.qml' `
        -Marker CAELESTIA_CAPTURE_PIXELS -MinimumAssertions 500 -TimeoutMs 90000 `
        -Environment @{ TEMP = $fixtureTemp; TMP = $fixtureTemp }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureTemp)
    if ($resolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'caelestia-picker-temp-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$result | ConvertTo-Json -Depth 8
$pixels | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Capture picker fixture failed. See $($result.stderr)." }
if (-not $pixels.passed) { throw "Capture device pixel fixture failed. See $($pixels.stdout) and $($pixels.stderr)." }
