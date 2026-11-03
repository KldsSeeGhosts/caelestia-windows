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
$output = Join-Path $BuildRoot ('tiling-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
function Assert-DisabledTiling($State, [string]$Label) {
    Assert ($State.mode -eq 'off') "$Label mode is $($State.mode)."
    Assert ($State.requestedMode -eq 'off') "$Label requested $($State.requestedMode)."
    Assert ($State.status -eq 'disabled') "$Label status is $($State.status)."
    Assert ($State.backendRequested -eq $false) "$Label requested the native wrapper loader."
    Assert ($State.backendLoaded -eq $false) "$Label loaded the native tiling wrapper."
    Assert ($State.backendEnabled -eq $false) "$Label enabled a tiler."
    Assert ($State.includedSupported -eq $false) "$Label reported allowlist support."
    Assert ($State.managedCount -eq 0) "$Label reported managed windows."
    Assert ($State.failedCount -eq 0) "$Label reported failed windows."
    Assert ($State.lastError -eq '') "$Label reported a tiling error."
    Assert ($State.recentFailureCount -eq 0) "$Label recorded a fitting failure."
    Assert ($State.toastCount -eq 0) "$Label decided a toast."
    Assert ($State.toastsLoaded -eq $true) "$Label did not load the original toast surface."
}
function Assert-TilingLog($Result, [string]$Label) {
    $combined = (Get-Content -LiteralPath $Result.stdout -Raw) + "`n" + (Get-Content -LiteralPath $Result.stderr -Raw)
    $statusCount = [regex]::Matches($combined, 'CAELESTIA_TILING_STATUS tiling=off included=0 excluded=0 gapsIn=5 gapsOut=10 status=disabled').Count
    Assert ($statusCount -eq 1) "$Label did not print exactly one 'tiling=off included=0 excluded=0 gapsIn=5 gapsOut=10 status=disabled' status line ($statusCount)."
    Assert ($combined -notmatch 'CAELESTIA_TILING_BACKEND_READY') "$Label constructed the native tiling wrapper."
    Assert ($combined -notmatch 'CAELESTIA_TILING_FAIL') "$Label reported a smoke failure."
    Assert ($combined -notmatch 'CAELESTIA_TILING_FIXTURE_FAIL') "$Label reported a fixture failure."
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    $fixture = & "$PSScriptRoot\Test-TilingService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    # Native safety: this harness runs ONLY Disabled. Observe and Interactive
    # construct the backend Tiling singleton (which runs rescueParked over real
    # windows) and Interactive may enable the tiler; those modes are owned by
    # the orchestrator's live run on a prepared desktop and are deliberately
    # not reachable here.
    $screenCount = if ($Offscreen) { 1 } else { $beforeDesktop.monitors.Count }
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -RunRoot $RunRoot -Offscreen:$Offscreen -Tiling -TilingMode Disabled -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
        Assert $result.passed "Tiling prototype failed on screen $screen in Disabled mode."
        $records.Add([ordered]@{ kind = 'tiling-disabled'; result = $result })
        Assert ($result.tilingSnapshots.Count -eq 2) 'Tiling smoke did not record initial and final state.'
        Assert-DisabledTiling $result.tilingSnapshots[0].state "Initial disabled smoke"
        Assert-DisabledTiling $result.tilingSnapshots[1].state "Final disabled smoke"
        Assert-TilingLog $result "Tiling Disabled screen $screen"
    }
    $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -RunRoot $RunRoot -Offscreen:$Offscreen -CachePath $M1CachePath
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })
    $regressionLog = (Get-Content -LiteralPath $regression.stdout -Raw) + "`n" + (Get-Content -LiteralPath $regression.stderr -Raw)
    Assert ($regressionLog -notmatch 'CAELESTIA_TILING_BACKEND_READY') 'M1 regression loaded the tiling wrapper.'
    Assert ($regressionLog -notmatch 'CAELESTIA_TILING_STATUS') 'M1 regression printed a tiling status line.'
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
    measurementSources = @('Get-DesktopState.ps1', 'Test-TilingService.ps1', 'Test-TilingPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
