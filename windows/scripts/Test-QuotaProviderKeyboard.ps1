[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name quota-provider-keyboard -ShellFixture -UseQuickshell `
    -FakeDirectories @('windows/tests/fakes/quota') `
    -Sources @('windows/tests/QuotaProviderKeyboardTest.qml') -FixtureFile 'windows/tests/QuotaProviderKeyboardTest.qml' `
    -Marker CAELESTIA_QUOTA_PROVIDER_KEYBOARD -MinimumAssertions 28
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Quota provider keyboard fixture failed. See $($result.stderr)." }
