[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$ownedStage = Enter-QmlSharedStage
try {
    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name toaster-ipc -ShellFixture `
        -FakeDirectories @('windows/tests/fakes/shell') `
        -Sources @('windows/shell/adapters/ipc/ToasterIpc.qml', 'windows/tests/ToasterIpcTest.qml') `
        -FixtureFile 'windows/tests/ToasterIpcTest.qml' `
        -Marker CAELESTIA_TOASTER_IPC -MinimumAssertions 11
    $result | ConvertTo-Json -Depth 8
    if (-not $result.passed) { throw "Toaster IPC fixture failed. See $($result.stderr)." }
} finally {
    Exit-QmlSharedStage $ownedStage
}
