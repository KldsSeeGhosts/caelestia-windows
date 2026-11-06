[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name drag-preview -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/DragPreviewTest.qml') -FixtureFile 'windows/tests/DragPreviewTest.qml' `
    -Marker CAELESTIA_DRAG_PREVIEW -MinimumAssertions 18 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Drag preview fixture failed. See $($result.stderr)." }
