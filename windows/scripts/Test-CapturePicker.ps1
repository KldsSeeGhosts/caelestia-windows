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
    # lies on a whole device pixel of the window they are shown in. It places the
    # real components itself, with no picker. Each run gives the window a real
    # device pixel ratio with QT_SCALE_FACTOR, and the fixture measures it from the
    # window. The last runs show a capture made at one ratio in a window that has
    # another, as when a monitor's scaling changes after the capture.
    $pixelRuns = @(
        @{ Window = '1';    Capture = '1' },
        @{ Window = '1.25'; Capture = '1.25' },
        @{ Window = '1.5';  Capture = '1.5' },
        @{ Window = '1.5';  Capture = '1.25' },
        @{ Window = '1.25'; Capture = '1.5' },
        @{ Window = '1';    Capture = '1.25' }
    )
    $pixels = foreach ($run in $pixelRuns) {
        $suffix = "window-$($run.Window)-capture-$($run.Capture)"
        Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-pixels -ShellFixture -UseQuickshell `
            -Sources @('windows/tests/CapturePixelsTest.qml') -FixtureFile 'windows/tests/CapturePixelsTest.qml' `
            -Marker CAELESTIA_CAPTURE_PIXELS -MinimumAssertions 250 -TimeoutMs 90000 -LogSuffix $suffix `
            -Environment @{
                TEMP = $fixtureTemp; TMP = $fixtureTemp
                QT_SCALE_FACTOR = $run.Window
                CAELESTIA_PIXELS_WINDOW_DPR = $run.Window
                CAELESTIA_PIXELS_CAPTURE_DPR = $run.Capture
            }
    }
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
if (@($pixels).Count -ne $pixelRuns.Count) { throw "Expected $($pixelRuns.Count) device pixel runs, got $(@($pixels).Count)." }
foreach ($pixel in $pixels) {
    if (-not $pixel.passed) { throw "Capture device pixel fixture failed. See $($pixel.stdout) and $($pixel.stderr)." }
}
# The runs together keep the earlier minimum of 500 assertions.
$pixelAssertions = ($pixels | ForEach-Object { [int]$_.fixture.assertions } | Measure-Object -Sum).Sum
if ($pixelAssertions -lt 500) { throw "Capture device pixel fixtures made only $pixelAssertions assertions in total." }
