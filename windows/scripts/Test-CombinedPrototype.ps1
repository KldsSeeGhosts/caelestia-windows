[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$output = Join-Path $BuildRoot ('combined-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
# Every service the combined prototype plugs in must print one status line per
# phase, with observation on and every control, write, launch, activation,
# dispatch and mirror flag off.
function Assert-CombinedServiceLines([string]$StdoutPath) {
    $stdoutText = Get-Content -LiteralPath $StdoutPath -Raw
    $lines = @([regex]::Matches($stdoutText, 'CAELESTIA_COMBINED_SERVICE name=(?<name>\w+) (?<rest>[^\r\n]+)'))
    Assert ($lines.Count -ge 20) "Combined smoke did not print initial and final service lines (found $($lines.Count))."
    $expected = @('audio', 'battery', 'bluetooth', 'brightness', 'media', 'network', 'apps', 'tray', 'notifications', 'session')
    $names = @($lines | ForEach-Object { $_.Groups['name'].Value })
    foreach ($name in $expected) {
        $count = @($names | Where-Object { $_ -eq $name }).Count
        Assert ($count -ge 2) "Service '$name' has fewer than an initial and a final status line ($count)."
    }
    $controlKeys = @('controls', 'launch', 'activation', 'mirror', 'profileWrites', 'actions')
    foreach ($line in $lines) {
        foreach ($pair in $line.Groups['rest'].Value -split ' ') {
            $key, $value = $pair -split '=', 2
            if ($controlKeys -contains $key) {
                Assert ($value -eq 'false') "Service '$($line.Groups['name'].Value)' reported $key=$value."
            }
            if ($key -eq 'enabled') {
                Assert ($value -eq 'true') "Service '$($line.Groups['name'].Value)' was not enabled."
            }
            if ($key -eq 'hook') {
                Assert ($value -eq '0') "Combined run left the backend tray hook enabled."
            }
            if ($key -eq 'commandsSent') {
                Assert ($value -eq '0') "Combined run sent a network command."
            }
            if ($key -eq 'mode') {
                Assert ($value -eq 'Observe') "Session was not in observation-only mode."
            }
        }
    }
    foreach ($popout in @('audio', 'network', 'bluetooth', 'battery')) {
        Assert ($stdoutText -match "CAELESTIA_COMBINED_POPOUT $popout ") "The $popout popout did not load."
    }
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
try {
    # Native screen selection is explicit. The parent runs this harness on the
    # desktop; the combined smoke sends no input, opens every panel
    # programmatically, refuses every write through the facades and captures
    # one screenshot per phase.
    $screenCount = $beforeDesktop.monitors.Count
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -Combined -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
        Assert $result.passed "Combined smoke failed on screen $screen."
        $records.Add([ordered]@{ kind = 'combined'; screen = $screen; result = $result })
        Assert ($result.captures.Count -ge 8) "Combined smoke on screen $screen did not capture every phase ($($result.captures.Count) captures)."
        foreach ($capture in $result.captures) {
            Assert (Test-Path -LiteralPath ([Uri]$capture).LocalPath) "Capture file missing: $capture"
        }
        Assert-CombinedServiceLines $result.stdout
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
    measurementSources = @('Get-DesktopState.ps1', 'Start-ShellPrototype.ps1', 'Test-CombinedPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
