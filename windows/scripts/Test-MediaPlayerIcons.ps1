[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name media-player-icons -KeepRelativePaths `
    -FakeDirectories @('windows/tests/fakes/media-icons') `
    -Sources @('utils/Icons.qml',
        'windows/shell/adapters/modules/dashboard/media/PlayerIconSource.qml',
        'windows/tests/MediaPlayerIconTest.qml') `
    -FixtureFile 'windows/tests/MediaPlayerIconTest.qml' -Marker CAELESTIA_MEDIA_ICONS_FIXTURE -MinimumAssertions 6
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Media player icon fixture failed. See $($result.stdout) and $($result.stderr)." }
