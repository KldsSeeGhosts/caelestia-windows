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
$output = Join-Path $BuildRoot ('media-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
function Media-Stable($State) {
    # Position, length, playback state and metadata may advance while a real
    # session is playing. Policy, lifecycle, session identity and guard flags
    # must not change during a quiet read-only smoke.
    [ordered]@{
        status = $State.status; enabled = $State.enabled
        controlsEnabled = $State.controlsEnabled; backendLoaded = $State.backendLoaded
        nativeRequested = $State.nativeRequested
        nativeReady = $State.nativeReady; backendReady = $State.backendReady
        ready = $State.ready; noSessions = $State.noSessions
        sessionsObserved = $State.sessionsObserved; lastError = $State.lastError
        playerCount = $State.playerCount; players = $State.players
        activeIdentity = $State.activeIdentity; playerLoaded = $State.playerLoaded
        playerControlsEnabled = $State.playerControlsEnabled
        stopSupported = $State.stopSupported; raiseSupported = $State.raiseSupported
        quitSupported = $State.quitSupported; openUriSupported = $State.openUriSupported
        volumeSupported = $State.volumeSupported
    } | ConvertTo-Json -Depth 10 -Compress
}
function Assert-GuardedControls($State) {
    Assert (-not $State.controlsEnabled) 'Smoke enabled playback controls.'
    Assert (-not $State.playerControlsEnabled) 'Original component control hook stayed enabled in smoke.'
    foreach ($gate in @('canControl', 'canPlay', 'canPause', 'canTogglePlaying',
        'canSeek', 'canGoNext', 'canGoPrevious', 'canSetShuffle', 'canSetLoop',
        'canStop', 'canRaise', 'canQuit', 'canOpenUri', 'canSetVolume')) {
        Assert ($State.$gate -eq $false) "Read-only capability gate is true: $gate"
    }
    $unsupported = $State.stopSupported -or $State.raiseSupported -or $State.quitSupported -or $State.openUriSupported -or $State.volumeSupported
    Assert (-not $unsupported) 'Unsupported action was advertised as supported.'
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    $fixture = & "$PSScriptRoot\Test-MediaService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    # Native screen selection is explicit. The parent runs this harness on the
    # desktop; the smoke itself never sends a transport request or enables input.
    $screenCount = $beforeDesktop.monitors.Count
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        foreach ($mode in @('Disabled', 'ReadOnly')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -Media -MediaMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Media UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'media'; result = $result })
            Assert ($result.mediaSnapshots.Count -eq 2) 'Media smoke did not record initial and final state.'
            $initial = $result.mediaSnapshots[0].state
            $final = $result.mediaSnapshots[1].state
            Assert-GuardedControls $initial
            Assert-GuardedControls $final
            Assert ($initial.enabled -eq ($mode -ne 'Disabled')) 'Media observation opt-in does not match the requested mode.'
            if ($mode -eq 'Disabled') {
                $disabledClean = ($initial.status -eq 'disabled') -and (-not $initial.nativeRequested) -and (-not $initial.backendLoaded) -and (-not $initial.playerLoaded) -and ($initial.playerCount -eq 0) -and ($initial.activeIdentity -eq '')
                Assert $disabledClean 'Disabled mode constructed the backend or original component.'
            } else {
                Assert (@('no-sessions', 'observed', 'unavailable').Contains($initial.status)) `
                    "Media service did not settle: $($initial.status) ($($initial.reason))"
                Assert ($initial.nativeRequested) 'Enabled mode did not activate the native backend loader.'
                Assert ($initial.playerLoaded) 'Enabled mode did not load the original player component.'
                $healthy = @('no-sessions', 'observed').Contains($initial.status)
                $readyConsistent = ($initial.ready -eq $healthy) -and ($initial.nativeReady -eq $healthy) -and ($initial.backendReady -eq $healthy)
                Assert $readyConsistent 'Readiness disagrees with the settled status.'
                if ($healthy) {
                    Assert (-not $initial.lastError) 'Healthy scan retained an error.'
                } else {
                    Assert ($initial.lastError) 'Unavailable backend did not expose operation/HRESULT.'
                    $staleClean = ($initial.playerCount -eq 0) -and (@($initial.players).Count -eq 0) -and ($initial.activeIdentity -eq '')
                    Assert $staleClean 'Unavailable backend exposed stale sessions.'
                }
                if ($initial.status -eq 'no-sessions') {
                    $emptyClean = $initial.noSessions -and (-not $initial.sessionsObserved) -and ($initial.playerCount -eq 0)
                    Assert $emptyClean 'Healthy empty scan invented sessions.'
                } elseif ($initial.status -eq 'observed') {
                    $observedConsistent = $initial.sessionsObserved -and (-not $initial.noSessions) -and ($initial.playerCount -gt 0) -and (@($initial.players) -contains $initial.activeIdentity)
                    Assert $observedConsistent 'Observed sessions are inconsistent.'
                }
            }
            Assert ((Media-Stable $initial) -eq (Media-Stable $final)) 'Media policy or session identity changed during the read-only smoke.'
        }
    }
    $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -CachePath $M1CachePath
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
    measurementSources = @('Get-DesktopState.ps1', 'Test-MediaService.ps1', 'Test-MediaPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
