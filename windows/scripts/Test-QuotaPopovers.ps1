[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    # Optional: where to copy the fixture screenshots (breakdown, resets, menu).
    [string]$CaptureDir,
    # Optional shell.json for the fixture; the drawer is appearance-independent.
    [string]$ShellConfig
)
# Offscreen: the real quota Content with synthetic spend and reset credits.
# Drives OpenUsage's hover details and the "…" menu, and saves fixture
# screenshots. It calls no CPA, provider or reset endpoint and opens nothing on
# the desktop.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
# A fixture entry must not leave a per-run folder in the real Quickshell state
# directory: the harness routes its directory pragmas into the disposable profile.
$stateRoot = Join-Path $env:LOCALAPPDATA 'quickshell\State\by-shell'
$stateBefore = @(if (Test-Path -LiteralPath $stateRoot) {
    Get-ChildItem -LiteralPath $stateRoot -Directory | ForEach-Object Name
})
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name quota-popovers -ShellFixture -UseQuickshell `
    -FakeDirectories @('windows/tests/fakes/quota-popovers') `
    -Sources @('windows/tests/QuotaPopoverTest.qml') -FixtureFile 'windows/tests/QuotaPopoverTest.qml' `
    -Marker CAELESTIA_QUOTA_POPOVER -MinimumAssertions 28 -Keep -ShellConfig $ShellConfig
$stateAfter = @(if (Test-Path -LiteralPath $stateRoot) {
    Get-ChildItem -LiteralPath $stateRoot -Directory | ForEach-Object Name
})
$leakedState = @($stateAfter | Where-Object { $stateBefore -notcontains $_ })
$result.leakedState = $leakedState
$result.passed = $result.passed -and $leakedState.Count -eq 0
try {
    if ($CaptureDir -and $result.stage) {
        $state = Join-Path (Split-Path -Parent (Split-Path -Parent $result.stage)) 'profile\state'
        New-Item -ItemType Directory -Force -Path $CaptureDir | Out-Null
        Get-ChildItem -LiteralPath $state -Filter 'quota-*.png' | Copy-Item -Destination $CaptureDir
    }
} finally {
    if ($result.stage) {
        Remove-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $result.stage)) -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$result.stage = $null
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Quota popover fixture failed. See $($result.stderr)." }
