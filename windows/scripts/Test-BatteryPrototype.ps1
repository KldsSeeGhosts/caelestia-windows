[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    # Optional shared M1 result cache; one path per suite invocation.
    [string]$M1CachePath,
    # Focused review gate: only ReadOnly/Profiles battery smoke. Omits Disabled,
    # M1 and audio native runs while retaining fixture/state-preservation checks.
    [switch]$ReadOnlyProfilesOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$output = Join-Path $BuildRoot ('battery-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$records = New-Object Collections.Generic.List[object]
$failure = $null

function Get-PowerSnapshot([string]$Name) {
    & "$PSScriptRoot\Get-PowerState.ps1" -OutputPath (Join-Path $output "$Name.json") | ConvertFrom-Json
}
function Get-DesktopSnapshot([string]$Name) {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath (Join-Path $output "$Name.json") | ConvertFrom-Json
}
function Assert($Condition, [string]$Message) {
    # Untyped: callers pass booleans and non-empty measurement values alike.
    if (-not $Condition) { throw $Message }
}
function Assert-PowerReadable($State) {
    Assert ($State.Warnings.Count -eq 0) 'Independent power enumerator reported warnings.'
    Assert ($State.activeScheme.guid) 'Active power scheme was not measured.'
    Assert ($State.overlayScheme.guid) 'Effective overlay scheme was not measured.'
    Assert ($null -ne $State.systemPowerStatus) 'GetSystemPowerStatus snapshot missing.'
}
function Desktop-Identity($State) {
    # Foreground/cursor movement and unrelated application processes are outside
    # this read-only gate. Compare physical work areas and the existing shells.
    # Concurrent bounded smokes own a transient qs process; this harness waits
    # for its own child to exit, so it excludes qs/quickshell from the shared
    # snapshot instead of claiming another agent's run.
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorerRunning = $State.explorerRunning
        processes = @($State.relevantProcesses | Where-Object { $_.name -notin @('qs', 'quickshell') })
    } | ConvertTo-Json -Depth 10 -Compress
}

$beforePower = Get-PowerSnapshot 'power-before'
$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    Assert-PowerReadable $beforePower
    $fixture = & "$PSScriptRoot\Test-BatteryService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    # Native screen selection is explicit. Run every connected screen, with no
    # pointer/keyboard activation, power writes, system settings or monitor moves.
    $screenCount = $beforeDesktop.monitors.Count
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        $modes = if ($ReadOnlyProfilesOnly) { @('ReadOnly', 'Profiles') } else { @('Disabled', 'ReadOnly', 'Profiles') }
        foreach ($mode in $modes) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -Battery -BatteryMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Battery UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'battery'; result = $result })
            $initial = $result.batterySnapshots[0].state
            $final = $result.batterySnapshots[1].state
            if ($mode -eq 'Disabled') {
                Assert ($initial.status -eq 'disabled' -and -not $initial.backendLoaded -and -not $initial.hasBattery) 'Disabled service constructed its backend or observed hardware.'
                Assert (-not $initial.profilesEnabled -and $initial.profilesState -eq 'disabled' -and $initial.availableProfiles.Count -eq 0) 'Disabled mode constructed power profiles.'
            } else {
                Assert ($initial.status -eq 'ready' -or $initial.status -eq 'unavailable') 'Battery did not settle.'
                Assert ((Get-Content -LiteralPath $result.stdout -Raw).Contains('CAELESTIA_BATTERY_SELECTOR_PASS:')) 'Windows selector hook did not route through the read-only service.'
            }
            # Smoke never opts into profile writes, and observation must be a
            # truthful observing/unknown capability, never a fabricated profile.
            Assert (-not $initial.profileWritesEnabled -and -not $initial.profileWritesRequested) 'Smoke enabled power profile writes.'
            Assert ($initial.writeState -eq 'idle') 'Smoke started a power profile write.'
            if ($mode -eq 'ReadOnly') {
                Assert (-not $initial.profilesEnabled -and $initial.profilesState -eq 'disabled' -and $initial.availableProfiles.Count -eq 0) 'ReadOnly mode constructed power profiles.'
            }
            if ($mode -eq 'Profiles') {
                Assert $initial.profilesEnabled 'Profiles mode did not opt into observation.'
                Assert ($initial.profilesState -eq 'observing' -or $initial.profilesState -eq 'unknown') 'Profile observation did not settle.'
                if ($initial.profilesState -eq 'observing') {
                    Assert ($initial.profileStatusEnabled -and $initial.profileControlsEnabled) 'Observed profile is not shown read-only.'
                    Assert ($initial.availableProfiles -contains $initial.profile) 'Observed profile is not in the available set.'
                } else {
                    Assert (-not $initial.profileStatusEnabled -and -not $initial.profileControlsEnabled) 'Unknown profile is presented as available.'
                    Assert ($initial.profile -eq -1) 'Unknown profile leaked a value.'
                }
            }
            # Display state must be stable during a quiet read-only smoke. The
            # native time estimate can tick on discharging hardware; every other
            # projected field must match between INITIAL and FINAL.
            $initialStable = $initial | Select-Object -Property * -ExcludeProperty timeToEmpty
            $finalStable = $final | Select-Object -Property * -ExcludeProperty timeToEmpty
            Assert (($initialStable | ConvertTo-Json -Depth 10 -Compress) -eq ($finalStable | ConvertTo-Json -Depth 10 -Compress)) 'Observed battery or profile state changed during read-only smoke.'
        }
    }
    if (-not $ReadOnlyProfilesOnly) {
        $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -CachePath $M1CachePath
        Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
        $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })
        $M1CachePath = $regression.m1CachePath
        # The shared launcher/staging scripts also serve the audio slice; re-run
        # its full acceptance harness as the regression gate with this suite's
        # cached M1 result, so the nested harness does not repeat the smoke.
        $audioRegression = & "$PSScriptRoot\Test-AudioPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -M1CachePath $M1CachePath | ConvertFrom-Json
        Assert $audioRegression.passed 'Audio prototype regression gate failed.'
        $records.Add([ordered]@{ kind = 'audio-regression'; result = $audioRegression })
    }
} catch {
    $failure = $_.ToString()
} finally {
    $afterPower = Get-PowerSnapshot 'power-after'
    $afterDesktop = Get-DesktopSnapshot 'desktop-after'
}
try {
    Assert-PowerReadable $afterPower
    # The active scheme and effective overlay scheme are the write targets of
    # plan changes and PowerProfiles selection. Both must be unchanged.
    Assert (($beforePower.identity | ConvertTo-Json -Depth 5 -Compress) -eq ($afterPower.identity | ConvertTo-Json -Depth 5 -Compress)) 'Native power scheme, overlay, or battery presence/level state changed.'
    Assert ((Desktop-Identity $beforeDesktop) -eq (Desktop-Identity $afterDesktop)) 'Shell processes, work areas or taskbar state changed.'
} catch {
    if ($failure) { $failure += "`n" + $_.ToString() } else { $failure = $_.ToString() }
}
$summary = [ordered]@{
    passed = -not [bool]$failure; failure = $failure
    readOnlyProfilesOnly = [bool]$ReadOnlyProfilesOnly
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    measurementSources = @('Get-PowerState.ps1', 'Get-DesktopState.ps1', 'Test-BatteryService.ps1', 'Test-BatteryPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
