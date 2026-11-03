[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [string]$RunRoot,
    # Run every UI smoke on the offscreen QPA. This is the normal test mode:
    # no window is shown and frame presentation never depends on DWM.
    [switch]$Offscreen,
    [string]$M1CachePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $BuildRoot 'run' }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$output = Join-Path $BuildRoot ('audio-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$records = New-Object Collections.Generic.List[object]
$failure = $null

function Get-AudioSnapshot([string]$Name) {
    & "$PSScriptRoot\Get-AudioState.ps1" -OutputPath (Join-Path $output "$Name.json") | ConvertFrom-Json
}
function Get-DesktopSnapshot([string]$Name) {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath (Join-Path $output "$Name.json") | ConvertFrom-Json
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-AudioReadable($State) {
    Assert ($State.Errors.Count -eq 0) 'Independent audio enumerator failed.'
    foreach ($endpoint in $State.Endpoints) {
        Assert ($endpoint.Errors.Count -eq 0) 'Independent endpoint snapshot failed.'
    }
}
function Desktop-Identity($State) {
    # Foreground/cursor movement and unrelated application processes are outside
    # this read-only gate. Compare physical work areas and the existing shells.
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorerRunning = $State.explorerRunning
        # Our own bounded smoke has exited; other agents' transient qs
        # processes are not persistent desktop state.
        processes = @($State.relevantProcesses | Where-Object { $_.name -notin @('qs', 'quickshell') })
    } | ConvertTo-Json -Depth 10 -Compress
}

$beforeAudio = Get-AudioSnapshot 'audio-before'
$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    Assert-AudioReadable $beforeAudio
    $fixture = & "$PSScriptRoot\Test-AudioService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    # Native screen selection is explicit. Run every connected screen, with no
    # pointer/keyboard activation, audio writes, system settings or monitor moves.
    # The offscreen QPA exposes one virtual screen. Otherwise cover every
    # measured monitor, as before.
    $screenCount = if ($Offscreen) { 1 } else { $beforeDesktop.monitors.Count }
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        foreach ($mode in @('Disabled', 'ReadOnly')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -RunRoot $RunRoot -Offscreen:$Offscreen `
                -Audio -AudioMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Audio UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'audio'; result = $result })
            $initial = $result.audioSnapshots[0].state
            $final = $result.audioSnapshots[1].state
            Assert (-not $initial.controlsEnabled -and -not $final.controlsEnabled) 'Smoke enabled controls.'
            if ($mode -eq 'Disabled') {
                Assert ($initial.status -eq 'disabled' -and -not $initial.backendLoaded -and $initial.sinks.Count -eq 0 -and $initial.sources.Count -eq 0) 'Disabled service constructed its backend or observed hardware.'
            } else {
                Assert ($initial.status -eq 'ready' -or $initial.status -eq 'unavailable') 'Audio did not settle.'
            }
            # Endpoints/defaults must not change during a quiet read-only smoke.
            # Stream count may change independently as other applications run.
            $initialEndpoints = $initial | Select-Object -Property * -ExcludeProperty streamCount
            $finalEndpoints = $final | Select-Object -Property * -ExcludeProperty streamCount
            Assert (($initialEndpoints | ConvertTo-Json -Depth 10 -Compress) -eq ($finalEndpoints | ConvertTo-Json -Depth 10 -Compress)) 'Observed audio changed during read-only smoke.'
        }
    }
    $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -RunRoot $RunRoot -Offscreen:$Offscreen -CachePath $M1CachePath
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })
} catch {
    $failure = $_.ToString()
} finally {
    $afterAudio = Get-AudioSnapshot 'audio-after'
    $afterDesktop = Get-DesktopSnapshot 'desktop-after'
}
try {
    Assert-AudioReadable $afterAudio
    Assert (($beforeAudio | ConvertTo-Json -Depth 10 -Compress) -eq ($afterAudio | ConvertTo-Json -Depth 10 -Compress)) 'Independent endpoint volume/mute/channel/default-role state changed.'
    Assert ((Desktop-Identity $beforeDesktop) -eq (Desktop-Identity $afterDesktop)) 'Shell processes, work areas or taskbar state changed.'
} catch {
    if ($failure) { $failure += "`n" + $_.ToString() } else { $failure = $_.ToString() }
}
$summary = [ordered]@{
    passed = -not [bool]$failure; failure = $failure
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    measurementSources = @('Get-AudioState.ps1', 'NativeAudioSnapshot.cs', 'Get-DesktopState.ps1', 'Test-AudioPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
