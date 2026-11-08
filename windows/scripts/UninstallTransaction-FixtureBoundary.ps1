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
    # Fail closed even if a busy-lock regression unexpectedly lets this
    # source-install contender through. Never reach native assembly/deployment.
    if ($env:CAELESTIA_FIXTURE_OPERATION -eq 'SourceInstall') { throw 'Injected external boundary exception.' }
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
    $directory = Join-Path $env:CAELESTIA_FIXTURE_CASE 'integration'
    if ($env:CAELESTIA_FIXTURE_INTEGRATION_MODE -eq 'real') {
        # The real cleanup runs against these disposable paths and the
        # worker-generated HKCU test root. No live shortcut or registry root.
        return @{
            RunName = 'fixture-run'
            UninstallKey = 'fixture-apps'
            Shortcut = Join-Path $directory 'shortcut.lnk'
            SwitchBackShortcut = Join-Path $directory 'switch-back.lnk'
            DesktopShortcut = Join-Path $directory 'desktop.lnk'
            Launcher = Join-Path $env:CAELESTIA_FIXTURE_PREFIX 'Caelestia-Launcher.ps1'
        }
    }
    Invoke-FixtureBoundary 'integration'
    return @{ RunName = 'fixture-run'; Shortcut = Join-Path $directory 'shortcut.lnk' }
}
if ($env:CAELESTIA_FIXTURE_INTEGRATION_MODE -eq 'real') {
    # Real cleanup needs the production Run/Uninstall roots, redirected to a
    # disposable HKCU test key that the controller creates and removes.
    function Get-CaelestiaAutostartKey { return $env:CAELESTIA_FIXTURE_REGISTRY + '\Run' }
    function Get-CaelestiaUninstallKeyRoot { return $env:CAELESTIA_FIXTURE_REGISTRY + '\Uninstall' }
    if ($env:CAELESTIA_FIXTURE_INTEGRATION_FAILURE -eq 'registry-denial') {
        function Remove-Item {
            param([string]$LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction)
            if ($LiteralPath -eq (Get-CaelestiaUninstallKeyPath $env:CAELESTIA_FIXTURE_PREFIX)) {
                throw 'Injected Apps & features registry denial.'
            }
            $params = @{ LiteralPath = $LiteralPath; Recurse = $Recurse; Force = $Force }
            if ($ErrorAction) { $params.ErrorAction = $ErrorAction }
            Microsoft.PowerShell.Management\Remove-Item @params
        }
    }
} else {
# The simulated cleanup below replaces the real one, so it needs no real
# snapshot. The dedicated real-integration cases exercise that path against
# disposable files and registry keys.
function Get-CaelestiaUserIntegrationSnapshot {
    param([string]$Prefix, $Integration = $null)
    return @{ Files = @(); Run = $null; Key = $null }
}
function Restore-CaelestiaUserIntegrationSnapshot { param($Snapshot) return @() }
function Remove-CaelestiaUserIntegrationSnapshot { param($Snapshot) }
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    if ($LiteralPath -ne (Join-Path $env:CAELESTIA_FIXTURE_CASE 'integration') -or $Name -ne 'fixture-run') {
        throw 'Blocked access outside fixture integration.'
    }
    if (Test-Path -LiteralPath (Join-Path $LiteralPath $Name)) { return @{ 'fixture-run' = 'owned' } }
}
function Remove-CaelestiaUserIntegration([string]$Prefix, $Integration = $null) {
    Assert-FixturePrefix $Prefix
    if ($null -eq $Integration) { throw 'Uninstall did not pass the integration record it resolved.' }
    # The pending cleanup is entered here, after the real tombstone rename, and
    # the post-removal boundary is where the tree cleanup begins.
    foreach ($name in @('fixture-run', 'shortcut.lnk', 'switch-back.lnk', 'desktop.lnk', 'apps-features.json')) {
        $path = Join-Path $env:CAELESTIA_FIXTURE_CASE "integration\$name"
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Invoke-FixtureBoundary 'remove-integration'
}
function Remove-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    throw 'Blocked registry removal outside the fixture integration boundary.'
}
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
function Get-FixtureTaskPath([string]$TaskName) {
    if ($TaskName -notmatch '^Caelestia-Maintenance(?:Watch)?-[a-f0-9]{32}$') { throw 'Blocked unexpected task name.' }
    return Join-Path $env:CAELESTIA_FIXTURE_CASE "tasks\$TaskName.json"
}
function New-ScheduledTaskAction {
    param($Execute, $WorkingDirectory, $Argument)
    [pscustomobject]@{ Execute = $Execute; WorkingDirectory = $WorkingDirectory; Arguments = $Argument }
}
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return $null }
function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable,
        $ExecutionTimeLimit, $RestartCount, $RestartInterval)
    [pscustomobject]@{ ExecutionTimeLimitSeconds = $ExecutionTimeLimit.TotalSeconds; RestartCount = $RestartCount; RestartIntervalSeconds = $RestartInterval.TotalSeconds }
}
function New-ScheduledTaskTrigger { param([switch]$Once, $At) [pscustomobject]@{ At = $At } }
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Principal, $Settings, $ErrorAction)
    Invoke-FixtureBoundary 'register-task'
    @{ TaskName = $TaskName; Actions = @($Action); Trigger = $Trigger; Settings = $Settings } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-FixtureTaskPath $TaskName) -Encoding UTF8
    Invoke-FixtureBoundary 'after-register-task'
}
function Get-ScheduledTask {
    param($TaskName, $TaskPath, $ErrorAction)
    if ($TaskName -eq 'Caelestia-Maintenance*') {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $env:CAELESTIA_FIXTURE_CASE 'tasks') -File) {
            Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        }
        return
    }
    $path = Get-FixtureTaskPath $TaskName
    if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}
function Start-ScheduledTask {
    param($TaskName, $ErrorAction)
    $null = Get-FixtureTaskPath $TaskName
    Invoke-FixtureBoundary 'start-task'
    # Assert that a different process can enter the real locked transaction at
    # this boundary in the controller tests. No real task starts here.
}
function Stop-ScheduledTask {
    param($TaskName, $TaskPath, $ErrorAction)
    $null = Get-FixtureTaskPath $TaskName
    Invoke-FixtureBoundary 'stop-task'
}
function Unregister-ScheduledTask {
    param($TaskName, $TaskPath, [switch]$Confirm, $ErrorAction)
    if ($TaskName -eq 'fixture-no-task') { return }
    $path = Get-FixtureTaskPath $TaskName
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
}
function Start-CaelestiaDetached {
    param([string]$Prefix, [switch]$LegacyReady, [string]$TaskName, [switch]$PreparedSchemeRuntime)
    Assert-FixturePrefix $Prefix
    if (-not $PreparedSchemeRuntime) { throw 'Unexpected unprepared launch.' }
    Invoke-FixtureBoundary 'launch'
}
