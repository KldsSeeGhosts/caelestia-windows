[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [string]$RunRoot,
    [switch]$Offscreen,
    # Optional shared M1 result cache; one path per suite invocation.
    [string]$M1CachePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $BuildRoot 'run' }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$output = Join-Path $BuildRoot ('bluetooth-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$records = New-Object Collections.Generic.List[object]
$failure = $null

function Get-DesktopSnapshot([string]$Name) {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath (Join-Path $output "$Name.json") | ConvertFrom-Json
}
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
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
function Bluetooth-Stable($State) {
    # Connected counts, battery levels and transient settling state may change
    # while Windows observes a real radio. Policy, lifecycle, adapter identity
    # and guard flags must not change during a quiet read-only smoke.
    [ordered]@{
        status = $State.status; enabled = $State.enabled
        controlsEnabled = $State.controlsEnabled; backendLoaded = $State.backendLoaded
        nativeRequested = $State.nativeRequested
        initializationExpired = $State.initializationExpired
        hasAdapter = $State.hasAdapter; adapterName = $State.adapterName
        adapterState = $State.adapterState; radioEnabled = $State.radioEnabled
        radioBlocked = $State.radioBlocked; radioPending = $State.radioPending
        radioOff = $State.radioOff; radioUnknown = $State.radioUnknown
        discovering = $State.discovering; discoveryTimedOut = $State.discoveryTimedOut
        deviceCount = $State.deviceCount; devices = $State.devices
        canToggleRadio = $State.canToggleRadio
        canSetDiscovering = $State.canSetDiscovering
        canControlDevices = $State.canControlDevices
        discoverableSupported = $State.discoverableSupported
        renameSupported = $State.renameSupported
        trustedSupported = $State.trustedSupported
        blockedSupported = $State.blockedSupported
        wakeSupported = $State.wakeSupported
        settingsUri = $State.settingsUri; statusLoaded = $State.statusLoaded
        popoutLoaded = $State.popoutLoaded
        popoutControlsEnabled = $State.popoutControlsEnabled
        popoutSettingsDelegated = $State.popoutSettingsDelegated
    } | ConvertTo-Json -Depth 10 -Compress
}
function Assert-GuardedControls($State) {
    Assert (-not $State.controlsEnabled) 'Smoke enabled Bluetooth controls.'
    Assert (-not $State.popoutControlsEnabled) 'Original popout control hook stayed enabled in smoke.'
    foreach ($gate in @('canToggleRadio', 'canSetDiscovering', 'canControlDevices')) {
        Assert ($State.$gate -eq $false) "Read-only capability gate is true: $gate"
    }
    foreach ($gate in @('canConnect', 'canDisconnect', 'canPair', 'canForget')) {
        Assert (@($State.$gate | Where-Object { $_ -ne $false }).Count -eq 0) `
            "Read-only device capability gate is true: $gate"
    }
    $unsupported = $State.discoverableSupported -or $State.renameSupported `
        -or $State.trustedSupported -or $State.blockedSupported -or $State.wakeSupported
    Assert (-not $unsupported) 'Unsupported Bluetooth control was advertised as supported.'
    Assert (-not $State.discovering) 'Read-only observation started discovery.'
    Assert (-not $State.discoveryTimedOut) 'Read-only observation timed out discovery.'
    Assert ($State.settingsUri -eq 'ms-settings:bluetooth') 'Settings delegation target changed.'
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    $fixture = & "$PSScriptRoot\Test-BluetoothService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    # Native screen selection is explicit. The parent runs this harness on the
    # desktop; the smoke itself never sends a Bluetooth request or enables input.
    $screenCount = if ($Offscreen) { 1 } else { $beforeDesktop.monitors.Count }
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        foreach ($mode in @('Disabled', 'ReadOnly')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -RunRoot $RunRoot -Offscreen:$Offscreen -Bluetooth -BluetoothMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Bluetooth UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'bluetooth'; result = $result })
            Assert ($result.bluetoothSnapshots.Count -eq 2) 'Bluetooth smoke did not record initial and final state.'
            $initial = $result.bluetoothSnapshots[0].state
            $final = $result.bluetoothSnapshots[1].state
            Assert-GuardedControls $initial
            Assert-GuardedControls $final
            Assert ($initial.enabled -eq ($mode -ne 'Disabled')) 'Bluetooth observation opt-in does not match the requested mode.'
            if ($mode -eq 'Disabled') {
                $disabledClean = ($initial.status -eq 'disabled') -and (-not $initial.nativeRequested) `
                    -and (-not $initial.backendLoaded) -and (-not $initial.statusLoaded) `
                    -and (-not $initial.popoutLoaded) -and ($initial.deviceCount -eq 0) `
                    -and ($initial.adapterState -eq -1)
                Assert $disabledClean 'Disabled mode constructed the backend or original components.'
            } else {
                $allowed = @('no-adapter', 'blocked', 'off', 'radio-pending', 'on', 'unknown-radio')
                Assert ($allowed -contains $initial.status) `
                    "Bluetooth service did not settle: $($initial.status) ($($initial.reason))"
                Assert ($initial.nativeRequested) 'Enabled mode did not activate the native backend loader.'
                Assert ($initial.statusLoaded) 'Enabled mode did not load the original status icon.'
                Assert ($initial.popoutLoaded) 'Enabled mode did not load the original popout.'
                Assert ($initial.popoutSettingsDelegated -eq $true) 'Original popout did not delegate settings.'
                if ($initial.status -eq 'no-adapter') {
                    $nullClean = (-not $initial.hasAdapter) -and ($initial.deviceCount -eq 0) `
                        -and (-not $initial.radioEnabled)
                    Assert $nullClean 'Null-adapter state exposed stale adapter or devices.'
                } else {
                    Assert ($initial.hasAdapter) 'Adapter state without an adapter.'
                    Assert ($initial.adapterName) 'Adapter has no name.'
                    if ($initial.status -eq 'blocked') {
                        Assert ($initial.radioBlocked -and -not $initial.radioEnabled) 'Blocked radio state is inconsistent.'
                    } elseif ($initial.status -eq 'off') {
                        Assert ((-not $initial.radioEnabled) -and (-not $initial.radioBlocked)) 'Off radio state is inconsistent.'
                    } elseif ($initial.status -eq 'on') {
                        Assert ($initial.radioEnabled) 'On state without an enabled radio.'
                    }
                }
            }
            Assert ((Bluetooth-Stable $initial) -eq (Bluetooth-Stable $final)) `
                'Bluetooth policy or adapter identity changed during the read-only smoke.'
        }
    }
    $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -RunRoot $RunRoot -Offscreen:$Offscreen -CachePath $M1CachePath
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })
} catch {
    $failure = $_.ToString()
} finally {
    $afterDesktop = Get-DesktopSnapshot 'desktop-after'
}
try {
    Assert ((Desktop-Identity $beforeDesktop) -eq (Desktop-Identity $afterDesktop)) 'Shell processes, work areas or taskbar state changed.'
} catch {
    if ($failure) { $failure += "`n" + $_.ToString() } else { $failure = $_.ToString() }
}
$summary = [ordered]@{
    passed = -not [bool]$failure; failure = $failure
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    measurementSources = @('Get-DesktopState.ps1', 'Test-BluetoothService.ps1', 'Test-BluetoothPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
