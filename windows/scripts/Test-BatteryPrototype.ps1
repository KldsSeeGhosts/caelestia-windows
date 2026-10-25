[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
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
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorerRunning = $State.explorerRunning
        processes = $State.relevantProcesses
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
        foreach ($mode in @('Disabled', 'ReadOnly')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -Battery -BatteryMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Battery UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'battery'; result = $result })
            $initial = $result.batterySnapshots[0].state
            $final = $result.batterySnapshots[1].state
            if ($mode -eq 'Disabled') {
                Assert ($initial.status -eq 'disabled' -and -not $initial.backendLoaded -and -not $initial.hasBattery) 'Disabled service constructed its backend or observed hardware.'
            } else {
                Assert ($initial.status -eq 'ready' -or $initial.status -eq 'unavailable') 'Battery did not settle.'
            }
            # Display state must be stable during a quiet read-only smoke. The
            # native time estimate can tick on discharging hardware; every other
            # projected field must match between INITIAL and FINAL.
            $initialStable = $initial | Select-Object -Property * -ExcludeProperty timeToEmpty
            $finalStable = $final | Select-Object -Property * -ExcludeProperty timeToEmpty
            Assert (($initialStable | ConvertTo-Json -Depth 10 -Compress) -eq ($finalStable | ConvertTo-Json -Depth 10 -Compress)) 'Observed battery state changed during read-only smoke.'
        }
    }
    $regression = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -Smoke -ScaleFactor native -ScreenIndex 0 | ConvertFrom-Json
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })
    # The shared launcher/staging scripts also serve the audio slice; re-run its
    # full acceptance harness as the regression gate.
    $audioRegression = & "$PSScriptRoot\Test-AudioPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $audioRegression.passed 'Audio prototype regression gate failed.'
    $records.Add([ordered]@{ kind = 'audio-regression'; result = $audioRegression })
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
