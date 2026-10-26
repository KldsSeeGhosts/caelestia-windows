[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$output = Join-Path $BuildRoot ('hypr-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
function Assert-DisabledHypr($State, [string]$Label) {
    Assert ($State.enabled -eq $false) "$Label enabled Hypr observation."
    Assert ($State.dispatchEnabled -eq $false) "$Label enabled Hypr dispatch."
    Assert ($State.status -eq 'disabled') "$Label status is $($State.status)."
    Assert ($State.backendRequested -eq $false) "$Label requested the native backend loader."
    Assert ($State.backendLoaded -eq $false) "$Label loaded the native backend."
    Assert ($State.initialized -eq $false) "$Label initialized Hyprland data."
    Assert ($State.monitorCount -eq 0) "$Label exposed monitors."
    Assert ($State.workspaceCount -eq 0) "$Label exposed workspaces."
    Assert ($State.toplevelCount -eq 0) "$Label exposed toplevels."
    Assert ($State.focusedMonitorId -eq -1) "$Label exposed a focused monitor."
    Assert ($State.focusedWorkspaceId -eq -1) "$Label exposed a focused workspace."
    Assert ($State.workspacesLoaded -eq $false) "$Label loaded the original Workspaces."
    Assert ($State.specialLoaded -eq $false) "$Label loaded the original SpecialWorkspaces."
    Assert ($State.activeWindowLoaded -eq $false) "$Label loaded the original ActiveWindow."
    Assert ($State.commandsSent -eq 0) "$Label dispatched a command."
    Assert ($State.refusals -eq 0) "$Label recorded a dispatch refusal."
    Assert ($State.consumed -eq 0) "$Label consumed a special-workspace request."
}
function Assert-HyprLog($Result, [string]$Label) {
    $combined = (Get-Content -LiteralPath $Result.stdout -Raw) + "`n" + (Get-Content -LiteralPath $Result.stderr -Raw)
    $statusCount = [regex]::Matches($combined, 'CAELESTIA_HYPR_STATUS hypr=0 dispatch=0').Count
    Assert ($statusCount -eq 1) "$Label did not print exactly one 'hypr=0 dispatch=0' status line ($statusCount)."
    Assert ($combined -notmatch 'CAELESTIA_HYPR_BACKEND_READY') "$Label constructed the native Hyprland backend."
    Assert ($combined -notmatch 'CAELESTIA_HYPR_FAIL') "$Label reported a smoke failure."
    Assert ($combined -notmatch 'CAELESTIA_HYPR_FIXTURE_FAIL') "$Label reported a fixture failure."
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    $fixture = & "$PSScriptRoot\Test-HyprService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    # Native safety: this harness runs ONLY Disabled. Observe and Dispatch
    # construct the backend's WindowTracker/VirtualDesktops/TilingManager and
    # may dispatch desktop/window commands; those modes are owned by the
    # orchestrator's live run and are deliberately not reachable here.
    $screenCount = $beforeDesktop.monitors.Count
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -Hypr -HyprMode Disabled -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
        Assert $result.passed "Hypr prototype failed on screen $screen in Disabled mode."
        $records.Add([ordered]@{ kind = 'hypr-disabled'; result = $result })
        Assert ($result.hyprSnapshots.Count -eq 2) 'Hypr smoke did not record initial and final state.'
        Assert-DisabledHypr $result.hyprSnapshots[0].state 'Initial disabled smoke'
        Assert-DisabledHypr $result.hyprSnapshots[1].state 'Final disabled smoke'
        Assert-HyprLog $result "Hypr Disabled screen $screen"
    }
    $regression = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -Smoke -ScaleFactor native -ScreenIndex 0 | ConvertFrom-Json
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })
    $regressionLog = (Get-Content -LiteralPath $regression.stdout -Raw) + "`n" + (Get-Content -LiteralPath $regression.stderr -Raw)
    Assert ($regressionLog -notmatch 'CAELESTIA_HYPR_BACKEND_READY') 'M1 regression loaded the Hyprland backend.'
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
    measurementSources = @('Get-DesktopState.ps1', 'Test-HyprService.ps1', 'Test-HyprPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
