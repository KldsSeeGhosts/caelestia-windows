[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    # Optional shared M1 result cache; one path per suite invocation.
    [string]$M1CachePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$output = Join-Path $BuildRoot ('tray-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
    # Foreground/cursor movement and unrelated prototype processes are outside
    # this read-only gate. Compare physical work areas, taskbar state and the
    # existing Explorer process only; concurrent slices may add their own qs.
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorer = @($State.relevantProcesses | Where-Object { $_.name -eq 'explorer' })
    } | ConvertTo-Json -Depth 10 -Compress
}

function Other-Shells($State) {
    @($State.relevantProcesses | Where-Object { $_.name -ne 'explorer' } |
        ForEach-Object { "$($_.name):$($_.pid)" })
}

function Read-RunLog($Result) {
    $text = ''
    foreach ($path in @($Result.stdout, $Result.stderr)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $text += (Get-Content -LiteralPath $path -Raw)
        }
    }
    return $text
}

function Assert-TrayHookConstruction($Result, [bool]$Expected, [string]$Label) {
    # TrayHost logs this INFO line only from its constructor when the hook is
    # disabled. With systray.info enabled by the tray launcher it proves
    # whether SystemTray was actually constructed in this process.
    $log = Read-RunLog $Result
    $constructed = $log -match 'not hooking the system tray'
    Assert ($constructed -eq $Expected) `
        "${Label}: SystemTray construction was $constructed, expected $Expected."
    Assert ($log -notmatch 'Explorer restarted') "${Label}: an Explorer restart was reported."
    Assert ($log -notmatch 'the tray hook stays behind') "${Label}: interception was started."
    return $constructed
}

function Assert-Policy($State, [string]$Label) {
    Assert ($State.hookMode -eq '0') "${Label}: QS_WINDOWS_TRAY_HOOK was not 0."
    Assert (-not $State.interceptionEnabled) "${Label}: interception is advertised as enabled."
    Assert (-not $State.activationEnabled) "${Label}: activation is enabled in smoke."
    Assert ($State.menuMode -eq 'native') "${Label}: menu mode is not native."
    Assert (-not $State.menuCoordinatesSupported) "${Label}: menu coordinates are advertised."
    Assert (-not $State.scrollSupported) "${Label}: scroll is advertised as supported."
    Assert ($State.activationRequests -eq 0) "${Label}: a native activation was sent."
    Assert ($State.menuSent -eq 0) "${Label}: a native menu was opened."
}

function Assert-MenuUnavailable($State, [string]$Label) {
    Assert $State.menuLoaded "${Label}: the original tray menu did not load."
    Assert ($State.menuSemanticAvailable -eq $false) "${Label}: a semantic menu was claimed."
    Assert ($State.menuNotice.Length -gt 0) "${Label}: the unavailable notice is empty."
    Assert ($State.menuNoticeColour -eq $State.expectedDisabledColour) `
        "${Label}: the unavailable notice does not use the disabled-entry colour."
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    $fixture = & "$PSScriptRoot\Test-TrayService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Tray fixture failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })

    $screenCount = @($beforeDesktop.monitors).Count
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        foreach ($mode in @('Disabled', 'ReadOnly')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -Tray -TrayMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Tray UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'tray'; mode = $mode; screen = $screen; result = $result })
            Assert (@($result.traySnapshots).Count -eq 2) 'Tray smoke did not record initial and final state.'
            Assert ($result.trayHookMode -eq '0') 'The launcher did not force the tray hook off.'
            $initial = $result.traySnapshots[0].state
            $final = $result.traySnapshots[1].state
            Assert-Policy $initial "tray $mode screen $screen initial"
            Assert-Policy $final "tray $mode screen $screen final"
            Assert ($initial.enabled -eq ($mode -ne 'Disabled')) 'Tray observation opt-in does not match the mode.'

            if ($mode -eq 'Disabled') {
                $disabledClean = ($initial.status -eq 'disabled') -and (-not $initial.nativeRequested) `
                    -and (-not $initial.backendLoaded) -and (-not $initial.trayLoaded) `
                    -and (-not $initial.menuLoaded) -and ($initial.count -eq 0) -and ($initial.renderedCount -eq 0)
                Assert $disabledClean 'Disabled mode constructed the backend or the original components.'
                Assert ((Assert-TrayHookConstruction $result $false "tray Disabled screen $screen") -eq $false) `
                    'Disabled mode constructed SystemTray.'
                # No tray item was clicked, activated or enumerated without the hook.
                Assert (@($initial.titles).Count -eq 0) 'Disabled mode observed item titles.'
            } else {
                Assert (@('not-observable', 'empty', 'ready', 'unavailable').Contains($final.status)) `
                    "Tray service did not settle: $($final.status) ($($final.reason))"
                Assert ($final.nativeRequested -and $final.backendLoaded) `
                    'Enabled mode did not construct the native facade.'
                Assert ($final.trayLoaded -and $final.menuLoaded) `
                    'Enabled mode did not load the original tray components.'
                Assert ((Assert-TrayHookConstruction $result $true "tray ReadOnly screen $screen") -eq $true) `
                    'Enabled mode did not construct SystemTray.'
                # not-observable carries no backend error: it states the known
                # hook-off enumeration limit rather than a failure.
                $healthy = @('not-observable', 'empty', 'ready').Contains($final.status)
                Assert (($final.status -ne 'not-observable') -or ($final.ready -eq $false)) `
                    'A non-observable tray was reported ready.'
                Assert (($final.status -eq 'ready') -eq ($final.count -gt 0)) 'Tray count and status disagree.'
                if (-not $healthy) {
                    Assert ($final.lastError.Length -gt 0) 'Unavailable tray backend did not expose an error.'
                } else {
                    Assert ($final.lastError -eq '') 'Healthy tray observation retained an error.'
                }
                if ($final.count -gt 0) {
                    Assert ($final.firstHasMenu -eq $true) 'An observed item did not report hasMenu.'
                    Assert ($final.firstMenuHandleNull -eq $true) 'An observed item exposed a menu handle.'
                    Assert ($final.firstRenderableMenu -eq $false) 'A null menu was reported as renderable.'
                    Assert ($final.firstItemInteractions -eq $false) 'Read-only items are interactive.'
                    Assert ($final.firstItemNativeMenu -eq $false) 'Read-only items use native menu mode.'
                }
                Assert-MenuUnavailable $final "tray ReadOnly screen $screen"
                # The host attempted each request and the service refused it.
                Assert ($final.lastActivationResult -eq 'refused') 'Read-only activation was not refused.'
                Assert ($final.lastMenuResult -eq 'refused') 'Read-only menu was not refused.'
                Assert ($final.scrollRequests -ge 1) 'The read-only scroll attempt was not recorded.'
                # Record exactly what was observed for the archive.
                $records.Add([ordered]@{
                    kind = 'tray-observation'; screen = $screen
                    status = $final.status; count = $final.count
                    titles = @($final.titles); ids = @($final.ids)
                    renderedCount = $final.renderedCount
                    lastError = $final.lastError
                })
            }
        }
    }

    # Fixture preview: original components against plain objects, no native tray.
    $fixtureRun = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -Tray -TrayMode Disabled -TrayFixture -Smoke -ScaleFactor native -ScreenIndex 0 | ConvertFrom-Json
    Assert $fixtureRun.passed 'Tray fixture preview failed.'
    $records.Add([ordered]@{ kind = 'tray-fixture'; result = $fixtureRun })
    Assert (@($fixtureRun.traySnapshots).Count -eq 2) 'Fixture preview did not record initial and final state.'
    $fixtureInitial = $fixtureRun.traySnapshots[0].state
    $fixtureFinal = $fixtureRun.traySnapshots[1].state
    Assert ($fixtureFinal.fixture -eq $true) 'Fixture preview did not report fixture mode.'
    Assert (-not $fixtureFinal.enabled -and -not $fixtureFinal.nativeRequested `
        -and -not $fixtureFinal.backendLoaded) 'Fixture preview constructed the native backend.'
    Assert ((Assert-TrayHookConstruction $fixtureRun $false 'tray fixture preview') -eq $false) `
        'Fixture preview constructed SystemTray.'
    Assert ($fixtureFinal.trayLoaded -and $fixtureFinal.renderedCount -eq 3) `
        'Fixture preview did not render the three original delegates.'
    Assert ((ConvertTo-Json @($fixtureFinal.renderedTitles) -Compress) -eq `
        (ConvertTo-Json @('Fixture One', 'Fixture Two', 'Fixture Three') -Compress)) `
        'Fixture preview rendered unexpected items.'
    Assert ($fixtureFinal.firstIconReady -eq $true) 'The original ColouredIcon did not render.'
    Assert ($fixtureFinal.firstIconLayer -eq $true) 'The original ColouredIcon tint layer is disabled.'
    Assert ($fixtureFinal.firstIconTint -eq $fixtureFinal.expectedTint) 'The original tint colour changed.'
    Assert ($fixtureFinal.firstItemInteractions -eq $false) 'Fixture delegates are interactive.'
    Assert-MenuUnavailable $fixtureFinal 'tray fixture preview'

    $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -CachePath $M1CachePath
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })

    # Shared service fixtures must keep passing alongside this slice.
    $mediaFixture = & "$PSScriptRoot\Test-MediaService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $mediaFixture.passed 'Media service fixture regressed.'
    $records.Add([ordered]@{ kind = 'media-fixture'; result = $mediaFixture })
    $batteryFixture = & "$PSScriptRoot\Test-BatteryService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $batteryFixture.passed 'Battery service fixture regressed.'
    $records.Add([ordered]@{ kind = 'battery-fixture'; result = $batteryFixture })
} catch {
    $failure = $_.ToString()
} finally {
    $afterDesktop = Get-DesktopSnapshot 'desktop-after'
}
try {
    Assert ((Desktop-Identity $beforeDesktop) -eq (Desktop-Identity $afterDesktop)) `
        'Explorer, work areas or taskbar state changed.'
} catch {
    if ($failure) { $failure += "`n" + $_.ToString() } else { $failure = $_.ToString() }
}
$summary = [ordered]@{
    passed = -not [bool]$failure; failure = $failure
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    explorerBefore = @($beforeDesktop.relevantProcesses | Where-Object { $_.name -eq 'explorer' })
    explorerAfter = @($afterDesktop.relevantProcesses | Where-Object { $_.name -eq 'explorer' })
    taskbarBefore = $beforeDesktop.taskbar
    taskbarAfter = $afterDesktop.taskbar
    otherShellsBefore = @(Other-Shells $beforeDesktop)
    otherShellsAfter = @(Other-Shells $afterDesktop)
    measurementSources = @('Get-DesktopState.ps1', 'Test-TrayService.ps1', 'Test-TrayPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
