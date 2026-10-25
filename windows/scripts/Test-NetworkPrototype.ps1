[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$output = Join-Path $BuildRoot ('network-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
    # this read-only gate. Compare physical work areas, the taskbar and the
    # installed shells. Transient qs process entries are excluded because other
    # agents may run bounded smoke tests concurrently; every harness-owned run
    # is separately required to exit cleanly.
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorerRunning = $State.explorerRunning
        processes = @($State.relevantProcesses | Where-Object { $_.name -notin @('qs', 'quickshell') })
    } | ConvertTo-Json -Depth 10 -Compress
}
function Network-Stable($State) {
    # Adapter/radio/connection state, list policy and command diagnostics may
    # not change during a no-input, no-scan smoke. Scanning/connecting are
    # asserted false separately because Windows can report another process's
    # scan completion through the same notification source.
    [ordered]@{
        status = $State.status; reason = $State.reason
        enabled = $State.enabled; controlsEnabled = $State.controlsEnabled
        backendLoaded = $State.backendLoaded; nativeRequested = $State.nativeRequested
        initialized = $State.initialized; adapterPresent = $State.adapterPresent
        radioOn = $State.radioOn; locationDenied = $State.locationDenied
        connected = $State.connected; activeSsid = $State.activeSsid
        hasInternet = $State.hasInternet; limited = $State.limited
        listVisible = $State.listVisible; listAvailable = $State.listAvailable
        listHidden = $State.listHidden; networkCount = $State.networkCount
        networks = $State.networks
        ethernetConnected = $State.ethernetConnected
        ethernetDeviceCount = $State.ethernetDeviceCount
        ethernetControlSupported = $State.ethernetControlSupported
        ethernetConfigSupported = $State.ethernetConfigSupported
        lastResultKind = $State.lastResultKind; lastResultText = $State.lastResultText
        commandsSent = $State.commandsSent; scansRequested = $State.scansRequested
        pendingSsid = $State.pendingSsid
        popoutLoaded = $State.popoutLoaded
        popoutControlsEnabled = $State.popoutControlsEnabled
        popoutNativeConnect = $State.popoutNativeConnect
        popoutEthernetControlAvailable = $State.popoutEthernetControlAvailable
    } | ConvertTo-Json -Depth 10 -Compress
}
function Assert-ReadOnlyNetwork($State) {
    Assert (-not $State.controlsEnabled) 'Smoke enabled network controls.'
    Assert ($State.commandsSent -eq 0) 'Smoke sent a radio/connect/disconnect/forget command.'
    Assert ($State.scansRequested -eq 0) 'Smoke requested a network scan.'
    Assert ($State.lastResultKind -eq '') 'Smoke recorded a command result.'
    Assert ($State.pendingSsid -eq '') 'Smoke left a pending connection.'
    Assert ($State.listVisible -eq $false) 'Smoke requested visible-list scanning.'
    Assert ($State.scanning -eq $false) 'Smoke observed a requested scan state.'
    Assert ($State.connecting -eq $false) 'Smoke observed a connection attempt.'
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    $fixture = & "$PSScriptRoot\Test-NetworkService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    # Native screen selection is explicit. The parent runs this harness on the
    # desktop; the smoke never sends a radio/connect/disconnect/forget request,
    # never requests a scan and never enables input.
    $screenCount = $beforeDesktop.monitors.Count
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        foreach ($mode in @('Disabled', 'ReadOnly')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -Network -NetworkMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Network UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'network'; result = $result })
            Assert ($result.networkSnapshots.Count -eq 2) 'Network smoke did not record initial and final state.'
            $initial = $result.networkSnapshots[0].state
            $final = $result.networkSnapshots[1].state
            Assert-ReadOnlyNetwork $initial
            Assert-ReadOnlyNetwork $final
            Assert ($initial.enabled -eq ($mode -ne 'Disabled')) 'Network observation opt-in does not match the requested mode.'
            if ($mode -eq 'Disabled') {
                $disabledClean = ($initial.status -eq 'disabled') -and (-not $initial.nativeRequested) -and (-not $initial.backendLoaded) -and (-not $initial.popoutLoaded) -and ($initial.networkCount -eq 0) -and ($initial.activeSsid -eq '')
                Assert $disabledClean 'Disabled mode constructed the backend or original popout.'
            } else {
                Assert (@('no-adapter', 'radio-off', 'location-denied', 'connected', 'disconnected').Contains($initial.status)) `
                    "Network service did not settle: $($initial.status) ($($initial.reason))"
                Assert ($initial.nativeRequested) 'Enabled mode did not activate the native backend loader.'
                Assert ($initial.popoutLoaded) 'Enabled mode did not load the original network popout.'
                Assert ($initial.popoutControlsEnabled -eq $false) 'Original popout control hook stayed enabled in smoke.'
                Assert ($initial.popoutNativeConnect -eq $true) 'Original popout did not use the native connect path.'
                Assert ($initial.popoutEthernetControlAvailable -eq $false) 'Ethernet control was advertised as available.'
                Assert ($initial.initialized) 'Enabled mode did not settle its bounded initialization.'
                Assert ($initial.adapterPresent -eq ($initial.status -ne 'no-adapter')) 'Adapter state disagrees with the settled status.'
                $listClean = if ($initial.listAvailable) {
                    (-not $initial.listHidden) -and ($initial.networkCount -eq @($initial.networks).Count)
                } else {
                    $initial.listHidden -and ($initial.networkCount -eq 0) -and (@($initial.networks).Count -eq 0)
                }
                Assert $listClean 'Network list visibility is inconsistent with the settled state.'
                if ($initial.status -eq 'location-denied') {
                    Assert ($initial.reason -match 'location permission') 'Location denial reason is not explicit.'
                    Assert ($initial.activeSsid -eq '') 'Location denial retained an unverifiable connection.'
                }
                if ($initial.status -eq 'connected') {
                    Assert ($initial.activeSsid -ne '') 'Connected state has no active SSID.'
                    Assert ($initial.limited -eq (-not $initial.hasInternet)) 'Limited state disagrees with the internet flag.'
                } else {
                    Assert ($initial.activeSsid -eq '') 'Non-connected state retained an active SSID.'
                }
                Assert ($initial.ethernetDeviceCount -eq $(if ($initial.ethernetConnected) { 1 } else { 0 })) 'Ethernet projection is inconsistent.'
            }
            Assert ((Network-Stable $initial) -eq (Network-Stable $final)) 'Network policy or observation changed during the read-only smoke.'
        }
    }
    $regression = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -Smoke -ScaleFactor native -ScreenIndex 0 | ConvertFrom-Json
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
    measurementSources = @('Get-DesktopState.ps1', 'Test-NetworkService.ps1', 'Test-NetworkPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
