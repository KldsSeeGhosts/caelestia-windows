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
$output = Join-Path $BuildRoot ('session-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
    # this read-only gate. Other agents may run concurrent qs prototypes, so
    # compare physical work areas, the existing shells and non-qs processes;
    # Session-Leaked independently proves this harness left no qs behind.
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorerRunning = $State.explorerRunning
        processes = @($State.relevantProcesses | Where-Object { $_.name -ne 'qs' })
    } | ConvertTo-Json -Depth 10 -Compress
}
function Session-Leaked() {
    @(Get-CimInstance Win32_Process -Filter "Name='qs.exe'" -ErrorAction Stop | Where-Object {
        $_.CommandLine -like '*shell-runs\session-*' -or $_.CommandLine -like '*session-prototype-profile*'
    })
}
function Session-Stable($State) {
    [ordered]@{
        mode = $State.mode; enabled = $State.enabled
        actionsEnabled = $State.actionsEnabled; available = $State.available
        status = $State.status; nativeRequested = $State.nativeRequested
        backendLoaded = $State.backendLoaded; backendError = $State.backendError
        hibernateCapabilityKnown = $State.hibernateCapabilityKnown
        canHibernate = $State.canHibernate
        hibernateSupported = $State.hibernateSupported
        actionGating = $State.actionGating; fallbackBlocked = $State.fallbackBlocked
        actions = $State.actions
        lastOutcome = $State.lastOutcome; lastAction = $State.lastAction
        lastConsumed = $State.lastConsumed; lastDispatched = $State.lastDispatched
        lastRequested = $State.lastRequested; lastSucceeded = $State.lastSucceeded
    } | ConvertTo-Json -Depth 10 -Compress
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    $fixture = & "$PSScriptRoot\Test-SessionService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Session adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    $screenCount = if ($Offscreen) { 1 } else { $beforeDesktop.monitors.Count }
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        foreach ($mode in @('Disabled', 'Observe')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -RunRoot $RunRoot -Offscreen:$Offscreen -Session -SessionMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Session UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'session'; result = $result })
            Assert ($result.sessionSnapshots.Count -eq 2) 'Session smoke did not record initial and final state.'
            Assert ($result.sessionButtons.Count -eq 4) 'Session smoke did not record four original buttons.'
            Assert (@($result.sessionButtons | Where-Object { -not $_.disabled }).Count -eq 0) `
                'An original session button did not use disabled styling in smoke.'
            $initial = $result.sessionSnapshots[0].state
            $final = $result.sessionSnapshots[1].state
            Assert ($initial.mode -eq $mode) 'Session mode was not propagated to the host.'
            Assert (-not $initial.actionsEnabled) 'Smoke enabled session action dispatch.'
            Assert $initial.fallbackBlocked 'Detached fallback was not blocked.'
            Assert (-not $initial.lastDispatched -and -not $initial.lastRequested -and -not $initial.lastSucceeded) `
                'Smoke reported an action dispatch or success.'
            Assert $initial.lastConsumed 'Unknown probe was not consumed.'
            foreach ($action in @('lock', 'logout', 'shutdown', 'reboot', 'suspend', 'hibernate', 'firmware')) {
                Assert ($initial.actions.$action.available -eq $false) "Session action is available in smoke: $action"
                $expectedConfirmation = @('logout', 'shutdown', 'reboot', 'firmware').Contains($action)
                Assert ($initial.actions.$action.requiresConfirmation -eq $expectedConfirmation) `
                    "Session confirmation policy is wrong for $action"
            }
            if ($mode -eq 'Disabled') {
                $disabledClean = (-not $initial.enabled) -and (-not $initial.available) -and
                    (-not $initial.nativeRequested) -and (-not $initial.backendLoaded) -and
                    (-not $initial.hibernateCapabilityKnown) -and (-not $initial.hibernateSupported) -and
                    ($initial.lastOutcome -eq 'disabled')
                Assert $disabledClean 'Disabled mode constructed the native session backend or dispatched.'
            } else {
                $observeConsistent = $initial.enabled -and $initial.available -and
                    $initial.nativeRequested -and $initial.backendLoaded -and
                    $initial.hibernateCapabilityKnown -and
                    ($initial.canHibernate -eq $initial.hibernateSupported) -and
                    ($initial.lastOutcome -eq 'unsupported') -and
                    ($initial.actions.hibernate.capability -eq $initial.hibernateSupported)
                Assert $observeConsistent 'Observe mode did not expose a consistent read-only capability state.'
            }
            Assert ((Session-Stable $initial) -eq (Session-Stable $final)) `
                'Session policy or capability changed during the read-only smoke.'
            Assert ($result.stdout -and $result.stderr) 'Session smoke did not record logs.'
        }
    }
    $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -RunRoot $RunRoot -Offscreen:$Offscreen -CachePath $M1CachePath
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })
    $leaked = @(Session-Leaked)
    Assert ($leaked.Count -eq 0) "Session prototype process remained: $($leaked.ProcessId -join ', ')"
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
    measurementSources = @('Get-DesktopState.ps1', 'Test-SessionService.ps1', 'Test-SessionPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
