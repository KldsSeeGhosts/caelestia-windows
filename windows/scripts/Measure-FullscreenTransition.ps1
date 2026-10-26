[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackendTrace,
    [Parameter(Mandatory)][string]$TaskbarActions
)

$ErrorActionPreference = 'Stop'

function Field($Object, [string[]]$Names) {
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $null
}

function Read-Timeline([string]$Path, [string]$Source) {
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $Path).Path)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json } catch { throw "${Path}:${lineNumber}: invalid JSON: $_" }
        $tick = Field $record @('qpc', 'qpcTicks', 'qpcTimestamp', 'timestampQpc', 'monotonicTicks')
        $frequency = Field $record @('qpcFrequency', 'frequency', 'stopwatchFrequency', 'tickFrequency')
        $parsedTick = 0L
        $parsedFrequency = 0L
        if (-not [long]::TryParse([string]$tick, [ref]$parsedTick) -or
            -not [long]::TryParse([string]$frequency, [ref]$parsedFrequency) -or $parsedFrequency -le 0) {
            throw "${Path}:${lineNumber}: missing or invalid QPC timestamp/frequency; cannot synchronize these logs."
        }
        [pscustomobject]@{ Tick = $parsedTick; Frequency = $parsedFrequency; Source = $Source; Record = $record; Line = $lineNumber }
    }
}

$events = @(Read-Timeline $BackendTrace 'backend') + @(Read-Timeline $TaskbarActions 'taskbar')
if ($events.Count -eq 0) { throw 'Both logs are empty.' }
$frequencies = @($events.Frequency | Sort-Object -Unique)
if ($frequencies.Count -ne 1) { throw 'QPC frequencies differ; these logs cannot be combined safely.' }
$frequency = [double]$frequencies[0]
$events = @($events | Sort-Object Tick, Source, Line)
$backend = @($events | Where-Object Source -eq 'backend')
$actions = @($events | Where-Object Source -eq 'taskbar')
$transitions = @($backend | Where-Object {
    $_.Record.event -eq 'fullscreen' -and -not ($_.Record.initial -and -not $_.Record.active)
})

function Milliseconds([long]$Start, [long]$End) {
    return [math]::Round(($End - $Start) * 1000.0 / $frequency, 3)
}

# An action reports visibility immediately before and after its own call. The
# start of a visible interval is unknown unless a prior observation saw it.
$visible = @{}
$intervals = [System.Collections.Generic.List[object]]::new()
foreach ($action in $actions) {
    $r = $action.Record
    if ($r.Operation -notin @('show', 'hide', 'restore')) { continue }
    $key = [string](Field $r @('device', 'handle'))
    $before = Field $r @('visibleBefore')
    $after = Field $r @('visibleAfter', 'visible')
    if ($null -eq $after) { continue }
    if ($r.Operation -eq 'show' -and $after -eq $true -and -not $visible.ContainsKey($key)) {
        # This is the observed show/callback time, not necessarily the instant
        # Windows made the taskbar visible.
        $visible[$key] = $action.Tick
    } elseif ($before -eq $true -and -not $visible.ContainsKey($key)) {
        $visible[$key] = $null
    }
    if ($after -eq $true -and -not $visible.ContainsKey($key)) {
        $visible[$key] = $action.Tick
    } elseif ($after -eq $false -and $visible.ContainsKey($key)) {
        $intervals.Add([pscustomobject]@{ Device = $key; Start = $visible[$key]; End = $action.Tick })
        $visible.Remove($key)
    }
}
foreach ($key in @($visible.Keys)) {
    $intervals.Add([pscustomobject]@{ Device = $key; Start = $visible[$key]; End = $null })
}

foreach ($transition in $transitions) {
    $r = $transition.Record
    $next = @($transitions | Where-Object { $_.Tick -gt $transition.Tick -and $_.Record.window -eq $r.window } | Select-Object -First 1)
    $end = if ($next.Count) { $next[0].Tick } else { $events[-1].Tick }
    $matching = @($backend | Where-Object {
        $_.Tick -ge $transition.Tick -and $_.Tick -le $end -and $_.Record.window -eq $r.window -and
        (($r.active -and $_.Record.event -eq 'tiler_state' -and $_.Record.state -eq 'Suspended') -or
         (-not $r.active -and $_.Record.event -eq 'placement_verified' -and $_.Record.landed -eq $true))
    } | Select-Object -First 1)
    $metric = if ($matching.Count) { Milliseconds $transition.Tick $matching[0].Tick } else { $null }
    $changes = @($backend | Where-Object {
        $_.Tick -ge $transition.Tick -and $_.Tick -le $end -and $_.Record.event -in @('appbar_register', 'appbar_position', 'appbar_remove', 'work_area')
    })
    $exposures = @($intervals | Where-Object {
        if ($null -eq $_.Start) {
            # Only the observation immediately before this action is known.
            $null -ne $_.End -and $_.End -ge $transition.Tick -and $_.End -le $end
        } else {
            ($null -eq $_.End -or $_.End -ge $transition.Tick) -and $_.Start -le $end
        }
    } | ForEach-Object {
        $start = if ($null -eq $_.Start) { $null } elseif ($_.Start -lt $transition.Tick) { $transition.Tick } else { $_.Start }
        $finish = if ($null -eq $_.End) { $null } elseif ($_.End -gt $end) { $end } else { $_.End }
        [pscustomobject]@{
            Device = $_.Device
            DurationMs = if ($null -ne $start -and $null -ne $finish) { Milliseconds $start $finish } else { $null }
            StartKnown = ($null -ne $_.Start)
            EndKnown = ($null -ne $_.End)
        }
    })
    [pscustomobject]@{
        Window = $r.window
        Transition = if ($r.active) { 'fullscreen_on' } else { 'fullscreen_off' }
        InitialObservation = [bool]$r.initial
        Utc = $r.utc
        Qpc = $transition.Tick
        Endpoint = if ($r.active) { 'tiler_suspended' } else { 'tile_verified_landed' }
        LatencyMs = $metric
        TaskbarVisibleIntervals = $exposures
        AppBarWorkAreaEvents = @($changes | ForEach-Object { $_.Record })
    }
}
