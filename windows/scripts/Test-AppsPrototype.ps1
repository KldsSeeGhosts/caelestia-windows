[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [string]$RunRoot,
    [switch]$Offscreen,
    [string]$M1CachePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $BuildRoot 'run' }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$output = Join-Path $BuildRoot ('apps-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
    # this read-only gate. Compare physical work areas, the existing shells and
    # taskbar flags. Concurrent prototype smoke runs from other agents can own a
    # transient qs process; this harness waits for its own child to exit, so it
    # excludes qs/quickshell from the shared snapshot instead of killing or
    # claiming another agent's run.
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorerRunning = $State.explorerRunning
        processes = @($State.relevantProcesses | Where-Object { $_.name -notin @('qs', 'quickshell') })
    } | ConvertTo-Json -Depth 10 -Compress
}
function Apps-Stable($State) {
    # The catalog count and policy must not change during a quiet read-only
    # smoke. The fixed smoke query is applied after the initial snapshot, so the
    # query fields are compared separately.
    [ordered]@{
        status = $State.status; enabled = $State.enabled
        launchEnabled = $State.launchEnabled
        nativeRequested = $State.nativeRequested
        backendLoaded = $State.backendLoaded
        persistentFrequencies = $State.persistentFrequencies
        listLoaded = $State.listLoaded
        count = $State.count
        launchRequests = $State.launchRequests
        launchesIssued = $State.launchesIssued
        lastLaunchError = $State.lastLaunchError
        terminalLaunchSupported = $State.terminalLaunchSupported
    } | ConvertTo-Json -Depth 10 -Compress
}
function Assert-NoLaunch($State) {
    Assert (-not $State.launchEnabled) 'Smoke enabled app launching.'
    Assert ($State.launchRequests -eq 0) 'Smoke issued a launch request.'
    Assert ($State.launchesIssued -eq 0) 'Smoke dispatched a launch.'
    Assert (-not $State.lastLaunchError) 'Smoke recorded a launch refusal.'
    Assert (-not $State.terminalLaunchSupported) 'Terminal launch was advertised as supported.'
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    $fixture = & "$PSScriptRoot\Test-AppsService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'App adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    $screenCount = if ($Offscreen) { 1 } else { $beforeDesktop.monitors.Count }
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        foreach ($mode in @('Disabled', 'ReadOnly')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -RunRoot $RunRoot -Offscreen:$Offscreen -Apps -AppsMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Apps UI failed on screen $screen in $mode mode."
            Assert (Test-Path -LiteralPath $result.screenshot) 'Apps smoke did not produce a screenshot.'
            $records.Add([ordered]@{ kind = 'apps'; result = $result })
            Assert ($result.appsSnapshots.Count -eq 2) 'Apps smoke did not record initial and final state.'
            Assert ($result.appsSearches.Count -eq 1) 'Apps smoke did not record one search sample.'
            $initial = $result.appsSnapshots[0].state
            $final = $result.appsSnapshots[1].state
            Assert-NoLaunch $initial
            Assert-NoLaunch $final
            Assert ((Apps-Stable $initial) -eq (Apps-Stable $final)) 'Apps policy or catalog count changed during the read-only smoke.'
            Assert ($initial.enabled -eq ($mode -ne 'Disabled')) 'App catalog opt-in does not match the requested mode.'
            if ($mode -eq 'Disabled') {
                $disabledClean = ($initial.status -eq 'disabled') -and (-not $initial.nativeRequested) `
                    -and (-not $initial.backendLoaded) -and (-not $initial.listLoaded) `
                    -and ($initial.count -eq 0) -and ($initial.queryCount -eq 0) `
                    -and ($initial.listCount -eq 0) -and (@($initial.catalogNames).Count -eq 0)
                Assert $disabledClean 'Disabled mode constructed the native catalog or original list.'
                Assert (-not $initial.persistentFrequencies) 'Disabled mode constructed the frequency store.'
            } else {
                Assert (@('ready', 'empty', 'failed').Contains($initial.status)) `
                    "App catalog did not settle: $($initial.status) ($($initial.reason))"
                Assert ($initial.nativeRequested -and $initial.backendLoaded) 'Enabled mode did not activate the native catalog loader.'
                Assert $initial.listLoaded 'Enabled mode did not load the original launcher app list.'
                Assert $initial.persistentFrequencies 'Enabled mode did not create the profile frequency store.'
                $stateRoot = [IO.Path]::GetFullPath((Join-Path $result.profile 'state'))
                Assert ([IO.Path]::GetFullPath($initial.frequencyPath).StartsWith($stateRoot + '\')) `
                    'Frequency file is outside the isolated profile state directory.'
                if ($initial.status -eq 'ready') {
                    $readyConsistent = ($initial.count -gt 0) -and (@($initial.catalogNames).Count -gt 0) `
                        -and ($initial.queryCount -le $initial.count) -and $initial.searchMatchesList
                    Assert $readyConsistent 'Ready catalog state is inconsistent.'
                    Assert (@($initial.queryIcons).Count -eq [Math]::Min(6, $initial.queryCount)) `
                        'Search icons were not recorded.'
                    foreach ($icon in @($final.queryIcons)) {
                        Assert ($icon) 'Search icon fell outside the original image-missing fallback.'
                    }
                    $search = $result.appsSearches[0]
                    Assert ($search.query) 'Smoke did not enter a search query.'
                    Assert ($search.listCount -eq $search.queryCount) 'Original app list disagrees with the query result count.'
                } else {
                    Assert ($initial.count -eq 0 -and $initial.queryCount -eq 0 -and $initial.listCount -eq 0) `
                        'Non-ready catalog invented applications.'
                    if ($initial.status -eq 'failed') {
                        Assert ($initial.lastError) 'Failed catalog did not expose an error.'
                    }
                }
            }
        }
    }
    # Native frequency-store read path: a profile-local document written by the
    # harness must order the same catalog, and a corrupt document must be
    # tolerated instead of failing the catalog. No application is launched and
    # the smoke itself only reads.
    $readOnlyRun = $records | Where-Object { $_.kind -eq 'apps' -and $_.result.appsMode -eq 'ReadOnly' -and $_.result.screenIndex -eq 0 } | Select-Object -First 1
    Assert ($null -ne $readOnlyRun) 'No read-only run is available for the frequency checks.'
    $profile = $readOnlyRun.result.profile
    $frequencyPath = Join-Path $profile 'state\apps-frequencies.json'
    $catalogIds = @($readOnlyRun.result.appsSnapshots[0].state.catalogIds)
    Assert ($catalogIds.Count -gt 0) 'No observed application id is available for the frequency check.'
    $chosen = $catalogIds | Where-Object { $_ -ne $catalogIds[0] } | Select-Object -First 1
    if ($chosen) {
        $document = [ordered]@{ version = 1; frequencies = [ordered]@{ $chosen = 99 } } | ConvertTo-Json -Compress
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $frequencyPath) | Out-Null
        [IO.File]::WriteAllText($frequencyPath, $document, (New-Object Text.UTF8Encoding($false)))
        $frequencyRun = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -RunRoot $RunRoot -Offscreen:$Offscreen -Apps -AppsMode ReadOnly -Smoke -ScaleFactor native -ScreenIndex 0 | ConvertFrom-Json
        Assert $frequencyRun.passed 'Apps smoke failed with a profile frequency document.'
        $records.Add([ordered]@{ kind = 'apps-frequency-read'; result = $frequencyRun })
        $state = $frequencyRun.appsSnapshots[0].state
        Assert ($state.persistentFrequencies) 'Frequency store was not persistent for the read check.'
        Assert ($state.catalogIds[0] -eq $chosen) "Profile frequency did not order the catalog first: $($state.catalogIds[0]) != $chosen"
        Assert ($state.queryCount -le $state.count) 'Search counts are inconsistent with the frequency-ordered catalog.'
        [IO.File]::WriteAllText($frequencyPath, '{ not json', (New-Object Text.UTF8Encoding($false)))
        $corruptRun = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -RunRoot $RunRoot -Offscreen:$Offscreen -Apps -AppsMode ReadOnly -Smoke -ScaleFactor native -ScreenIndex 0 | ConvertFrom-Json
        Assert $corruptRun.passed 'Apps smoke failed with a corrupt profile frequency document.'
        $records.Add([ordered]@{ kind = 'apps-corrupt-frequency'; result = $corruptRun })
        $corruptState = $corruptRun.appsSnapshots[0].state
        Assert ($corruptState.status -eq 'ready' -and $corruptState.count -gt 0) `
            'A corrupt frequency document suppressed the catalog.'
        Remove-Item -LiteralPath $frequencyPath -Force -ErrorAction SilentlyContinue
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
    measurementSources = @('Get-DesktopState.ps1', 'Test-AppsService.ps1', 'Test-AppsPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
