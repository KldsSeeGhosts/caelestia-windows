# Test-only external boundaries, loaded AFTER the unchanged common/version
# helpers by instrumented copies of the three production entrypoints.
# No registry, COM shortcut, task, native payload or desktop process is used.
function Assert-FixturePrefix([string]$Path) {
    if ((Resolve-CaelestiaDirectory $Path) -ne $env:CAELESTIA_FIXTURE_PREFIX) { throw 'Unexpected process boundary prefix.' }
}
function Invoke-FixtureBoundary([string]$Name) {
    Add-Content -LiteralPath (Join-Path $env:CAELESTIA_FIXTURE_CONTROL 'boundaries.txt') -Value $Name
    if ($Name -ne $env:CAELESTIA_FIXTURE_PAUSE) { return }
    if ($script:fixturePaused) { return }
    $script:fixturePaused = $true
    [IO.File]::WriteAllText((Join-Path $env:CAELESTIA_FIXTURE_CONTROL 'ready'), $Name)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists((Join-Path $env:CAELESTIA_FIXTURE_CONTROL 'release'))) {
        if ($clock.Elapsed.TotalSeconds -gt 45) { throw 'Fixture boundary release timed out.' }
        Start-Sleep -Milliseconds 20
    }
    if ($env:CAELESTIA_FIXTURE_THROW -eq '1') { throw 'Injected external boundary exception.' }
}
function Get-CaelestiaProcesses([string]$Prefix) {
    Assert-FixturePrefix $Prefix
    Invoke-FixtureBoundary 'processes'
    return @()
}
function Get-CaelestiaSupervisors([string]$ProfileRoot) {
    if ($ProfileRoot -ne $env:CAELESTIA_FIXTURE_PROFILE) { throw 'Unexpected supervisor boundary profile.' }
    return @()
}
function Stop-CaelestiaHosts([string]$Prefix, [string]$VersionRoot = '', [int]$TimeoutSeconds = 10) {
    Assert-FixturePrefix $Prefix
    Invoke-FixtureBoundary 'hosts'
}
function Get-CaelestiaIntegration([string]$Prefix) {
    Assert-FixturePrefix $Prefix
    Invoke-FixtureBoundary 'integration'
    return @{ RunName = 'fixture-run'; Shortcut = Join-Path $env:CAELESTIA_FIXTURE_CASE 'integration\shortcut.lnk' }
}
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    if ($LiteralPath -ne (Join-Path $env:CAELESTIA_FIXTURE_CASE 'integration') -or $Name -ne 'fixture-run') {
        throw 'Blocked access outside fixture integration.'
    }
    if (Test-Path -LiteralPath (Join-Path $LiteralPath $Name)) { return @{ 'fixture-run' = 'owned' } }
}
function Remove-ItemProperty {
    param([string]$LiteralPath, [string]$Name)
    if ($LiteralPath -ne (Join-Path $env:CAELESTIA_FIXTURE_CASE 'integration') -or $Name -ne 'fixture-run') {
        throw 'Blocked removal outside fixture integration.'
    }
    Remove-Item -LiteralPath (Join-Path $LiteralPath $Name)
}
# Scheme provisioning/probes and task-backed launches are external boundaries,
# not the version publication/selection/rollback transaction under test.
function Select-CaelestiaSchemeGeneration {
    Invoke-FixtureBoundary 'scheme'
    return $null
}
function Select-CaelestiaRestoreScheme { return $null }
function Set-CaelestiaSchemeRuntimeForRevision { return $null }
function Remove-CaelestiaSchemeGenerations { }
function New-CaelestiaLaunchTask { return 'fixture-no-task' }
function Unregister-ScheduledTask { }
function Start-CaelestiaDetached {
    param([string]$Prefix, [switch]$LegacyReady, [string]$TaskName, [switch]$PreparedSchemeRuntime)
    Assert-FixturePrefix $Prefix
    if (-not $PreparedSchemeRuntime) { throw 'Unexpected unprepared launch.' }
    Invoke-FixtureBoundary 'launch'
}
