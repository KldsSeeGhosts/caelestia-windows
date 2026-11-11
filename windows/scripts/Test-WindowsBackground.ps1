[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
foreach ($case in @(
    @{ Name = 'underlay'; File = 'WindowsBackgroundTest.qml'; Marker = 'CAELESTIA_BACKGROUND_UNDERLAY'; Floor = 100; Fakes = @() },
    @{ Name = 'legacy'; File = 'WindowsBackgroundLegacyTest.qml'; Marker = 'CAELESTIA_BACKGROUND_LEGACY'; Floor = 10; Fakes = @('windows/tests/fakes/background-legacy') },
    @{ Name = 'disabled-engine'; File = 'WindowsBackgroundDisabledEngineTest.qml'; Marker = 'CAELESTIA_BACKGROUND_DISABLED_ENGINE'; Floor = 28; Fakes = @() },
    @{ Name = 'we-restart'; File = 'WindowsBackgroundWeRestartTest.qml'; Marker = 'CAELESTIA_BACKGROUND_WE_RESTART'; Floor = 11; Fakes = @() }
)) {
    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name "background-$($case.Name)" -ShellFixture `
        -FakeDirectories (@('windows/tests/fakes/shell', 'windows/tests/fakes/native', 'windows/tests/fakes/wallpaper', 'windows/tests/fakes/background') + $case.Fakes) `
        -Sources @("windows/tests/$($case.File)") -FixtureFile "windows/tests/$($case.File)" `
        -Marker $case.Marker -MinimumAssertions $case.Floor
    $result | ConvertTo-Json -Depth 8
    if (-not $result.passed) { throw "Background $($case.Name) fixture failed. See $($result.stderr)." }
}
