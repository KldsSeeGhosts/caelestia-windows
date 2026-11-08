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
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureTemp)
    if ($resolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'caelestia-picker-temp-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Capture picker fixture failed. See $($result.stderr)." }
