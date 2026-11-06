[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name update-manager `
    -Sources @('windows/shell/adapters/services/UpdateManager.qml',
        'windows/tests/update-manager/qmldir', 'windows/tests/UpdateManagerTest.qml') `
    -FakeDirectories @('windows/tests/fakes/shell') `
    -FixtureFile 'windows/tests/UpdateManagerTest.qml' -Marker CAELESTIA_UPDATE_MANAGER -MinimumAssertions 32
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Update manager fixture failed. See $($result.stderr)." }
