[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [ValidateRange(0, 15)][int]$ScreenIndex = 1,
    [string]$OutputRoot,
    # Reuse a deployed temporary install from an earlier interrupted run. It is
    # still a caelestia-frame-* copy under TEMP, never the live installation.
    [string]$ReusePrefix,
    # The installed smoke takes about 15 s of QML runtime; the isolated frame
    # fixture is independent of it. Skipping the smoke is for a bounded rerun
    # of the fixture only, after a complete run has already validated the
    # installed runtime.
    [switch]$SkipSmoke,
    # Overall bound. Every wait and IPC call below is separately bounded; this
    # converts a slow install or a wedged child into a reported failure instead
    # of an unexplained kill by the caller's own timeout. Leave enough room for
    # a cold first start of both the smoke and the frame fixture.
    [ValidateRange(60, 900)][int]$TimeoutSeconds = 300
)

# A temporary deployed runtime, with read-only smoke on one secondary display.
# No takeover supervisor, taskbar changes, global recovery or desktop input.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$startedAt = [DateTime]::UtcNow
$deadline = $startedAt.AddSeconds($TimeoutSeconds)
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $repoRoot ('windows\.local\frame-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$temporaryRoot = Join-Path $env:TEMP ('caelestia-frame-' + [guid]::NewGuid().ToString('N'))
$prefix = Join-Path $temporaryRoot 'install'
$runtimePrefix = $prefix
$profile = Join-Path $temporaryRoot 'profile'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcher = $null
$fixture = $null
$fixtureOut = $null
$fixtureErr = $null
$failure = $null
$summary = [ordered]@{
    passed = $false; phase = 'start'; startedAtUtc = $startedAt.ToString('o')
    timeoutSeconds = $TimeoutSeconds; prefix = $prefix; profile = $profile; screenIndex = $ScreenIndex
}

function Snapshot([string]$Name) {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath "$OutputRoot\$Name.json" | ConvertFrom-Json
}
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Deadline([string]$Where) {
    if ([DateTime]::UtcNow -gt $deadline) {
        throw "The run exceeded $TimeoutSeconds s in '$($summary.phase)' while $Where."
    }
}
# Record the current phase and persist it immediately. A caller that kills the
# run still gets the last completed phase instead of an unexplained timeout.
function Set-Phase([string]$Name) {
    Assert-Deadline "entering '$Name'"
    $summary.phase = $Name
    $summary.elapsedSeconds = [int]([DateTime]::UtcNow - $startedAt).TotalSeconds
    Write-Host ("[{0,3} s] {1}" -f $summary.elapsedSeconds, $Name)
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$OutputRoot\result.json" -Encoding UTF8
}
function WorkIdentity($State) {
    @($State.monitors | ForEach-Object {
        "$($_.deviceName):$($_.physicalWorkArea | ConvertTo-Json -Compress)"
    }) -join ';'
}
function WorkDeltas($Before, $After, [string]$DeviceName) {
    $base = ($Before.monitors | Where-Object deviceName -eq $DeviceName).physicalWorkArea
    $work = ($After.monitors | Where-Object deviceName -eq $DeviceName).physicalWorkArea
    if (-not $base -or -not $work) { return $null }
    [ordered]@{
        left = $work.left - $base.left
        top = $work.top - $base.top
        right = $base.right - $work.right
        bottom = $base.bottom - $work.bottom
    }
}
function OtherWorkUnchanged($Before, $After, [string]$DeviceName) {
    foreach ($monitor in @($Before.monitors)) {
        if ($monitor.deviceName -eq $DeviceName) { continue }
        $now = @($After.monitors | Where-Object deviceName -eq $monitor.deviceName)
        if ($now.Count -ne 1) { return $false }
        if (($now[0].physicalWorkArea | ConvertTo-Json -Compress) -ne
            ($monitor.physicalWorkArea | ConvertTo-Json -Compress)) { return $false }
    }
    return $true
}
# A GUI-subsystem qs.exe that cannot start or a wedged instance would otherwise
# block the caller forever: IpcClient::waitForResponse has no timeout. Bound
# every invocation and kill the client on expiry so the phase reports instead.
function Invoke-QsIpc([string[]]$IpcArgs, [int]$TimeoutMs = 5000, [switch]$AllowTimeout) {
    $quoted = @($IpcArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = "$runtimePrefix\qs.exe"
    $info.Arguments = $quoted -join ' '
    $info.WorkingDirectory = $prefix
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['PATH'] = "$prefix;$env:SystemRoot\System32;$env:SystemRoot"
    $process = [Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMs)) {
        try { $process.Kill(); $null = $process.WaitForExit(2000) } catch {}
        $process.Dispose()
        # A readiness poll must keep waiting through a still-starting instance.
        # Action calls keep the hard failure so a wedged child cannot be
        # mistaken for success.
        if ($AllowTimeout) {
            return [pscustomobject]@{ exitCode = -1; timedOut = $true; stdout = ''; stderr = '' }
        }
        throw "qs ipc did not answer within $TimeoutMs ms: $($IpcArgs -join ' ')"
    }
    $result = [pscustomobject]@{
        exitCode = $process.ExitCode
        timedOut = $false
        stdout = $out.GetAwaiter().GetResult()
        stderr = $err.GetAwaiter().GetResult()
    }
    $process.Dispose()
    return $result
}
function ShellState {
    $result = Invoke-QsIpc @('ipc', '--path', "$runtimePrefix\shell\shell.qml", 'call', 'shell', 'state') 5000 -AllowTimeout
    if ($result.timedOut -or $result.exitCode -ne 0) { return $null }
    try { return $result.stdout | ConvertFrom-Json } catch { return $null }
}
function Wait-Condition([scriptblock]$Condition, [int]$Seconds, [string]$Message, [int]$PollMs = 200) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Assert-Deadline $Message
        if (& $Condition) { return }
        Start-Sleep -Milliseconds $PollMs
    } while ([DateTime]::UtcNow -lt $until)
    throw $Message
}
function Stop-OwnedProcesses {
    # This exact executable path identifies only this test's children, even when
    # the live shell has a running supervisor and identical process name.
    $owned = @(Get-Process qs -ErrorAction SilentlyContinue | ForEach-Object {
        try { if ($_.Path -eq "$runtimePrefix\qs.exe") { $_ } } catch {}
    })
    foreach ($child in $owned) {
        if ($child.HasExited) { continue }
        if ($fixture -and $child.Id -eq $fixture.Id) {
            try { $null = Invoke-QsIpc @('ipc', '--pid', "$($fixture.Id)", 'call', 'frameTest', 'quit') 3000 } catch {}
        }
        if (-not $child.WaitForExit(3000)) {
            try { $child.Kill(); $null = $child.WaitForExit(2000) } catch {}
        }
    }
}
# Save the fixture's logs and remove only its own stale AppBar registrations,
# including after an interrupted or failed run.
function Save-FixtureArtifacts {
    if (-not ($fixture -and $fixture.HasExited)) { return }
    if ($null -ne $fixtureOut) {
        try { $fixtureOut.GetAwaiter().GetResult() | Set-Content -LiteralPath "$OutputRoot\fixture.stdout.log" } catch {}
    }
    if ($null -ne $fixtureErr) {
        try { $fixtureErr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$OutputRoot\fixture.stderr.log" } catch {}
    }
    if (-not ('Caelestia.Takeover.Native' -as [type])) {
        Add-Type -Path "$PSScriptRoot\DesktopTakeover.cs" -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    }
    [Caelestia.Takeover.Native]::RemoveStaleAppBars($fixture.Id) | Out-Null
}

# Validate a reused temporary install before touching the desktop at all. The
# bare leaf checks keep this from ever pointing at the live installation.
if ($ReusePrefix) {
    $prefix = (Resolve-Path -LiteralPath $ReusePrefix).Path
    $temporaryRoot = Split-Path -Parent $prefix
    $profile = Join-Path $temporaryRoot 'profile'
    Assert ((Split-Path -Leaf $prefix) -eq 'install') 'ReusePrefix must be the install directory of a caelestia-frame-* run.'
    Assert ((Split-Path -Leaf $temporaryRoot) -like 'caelestia-frame-*') 'ReusePrefix must be a caelestia-frame-* temporary run.'
    Assert (Test-Path -LiteralPath "$prefix\install.json") "Reused prefix has no install record: $prefix"
    $runtimePrefix = Resolve-CaelestiaRuntimePrefix $prefix
    Assert (Test-Path -LiteralPath "$runtimePrefix\qs.exe") "Reused prefix has no deployed runtime: $prefix"
    Assert (Test-Path -LiteralPath "$runtimePrefix\shell\shell.qml") "Reused prefix has no staged shell: $prefix"
    Assert (Test-Path -LiteralPath "$profile\config") "Reused prefix has no temporary profile: $profile"
    $summary.prefix = $prefix
    $summary.profile = $profile
    $summary.reused = $true
}

$before = Snapshot 'desktop-before'
# ScreenIndex is a Qt index, not EnumDisplayMonitors order. Check the actual
# selected screen against the real monitor bounds after startup, before
# asserting anything about the reservation.
Assert ($before.monitors.Count -gt 1) 'This live-safe test requires a secondary monitor.'
Set-Phase 'baseline'
try {
    if (-not $ReusePrefix) {
        & "$PSScriptRoot\Install-Caelestia.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -Prefix $prefix -ProfileRoot $profile -SkipSchemeRuntime *> "$OutputRoot\install.log"
    }
    Set-Phase 'installed'
    $runtimePrefix = Resolve-CaelestiaRuntimePrefix $prefix

    # Seed the temporary profile exactly as Start-Caelestia would, so the
    # fixture phase also works with -SkipSmoke and a reused install.
    foreach ($dir in @('config', 'state', 'cache', 'data', 'runtime', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $dir) | Out-Null
    }
    foreach ($name in @('shell.json', 'keybinds.json', 'windows.json')) {
        $target = Join-Path $profile "config\$name"
        if (-not (Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath "$runtimePrefix\defaults\$name" -Destination $target
        }
    }

    $smokeScreen = $null
    if (-not $SkipSmoke) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + "$prefix\Start-Caelestia.ps1" + '" -Prefix "' + $prefix `
            + '" -Smoke -ScreenIndex ' + $ScreenIndex + ' -SkipSchemeRuntime'
        $launcher = Start-Process $powershellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput "$OutputRoot\launch.stdout.log" -RedirectStandardError "$OutputRoot\launch.stderr.log"
        $null = $launcher.Handle
        $summary.smokePid = $launcher.Id
        Set-Phase 'smoke-started'

        $state = $null
        # Start-Caelestia bounds the same smoke at 60 s. Wait slightly longer
        # here so the launcher can report its own failure instead, and tolerate
        # the cold QML cache of a first run after installation.
        $smokeDeadline = [DateTime]::UtcNow.AddSeconds(75)
        while ([DateTime]::UtcNow -lt $smokeDeadline) {
            Assert-Deadline 'waiting for the installed smoke'
            Start-Sleep -Milliseconds 500
            $state = ShellState
            if ($state -and $state.smokeComplete) { break }
            $launcher.Refresh()
            if ($launcher.HasExited) {
                throw "The installed smoke exited before completing (code $($launcher.ExitCode)); inspect launch logs."
            }
        }
        Assert ($state -and $state.smokeComplete) 'The installed smoke did not complete.'
        $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$OutputRoot\shell-state.json" -Encoding UTF8
        $smokeWindows = @($state.windows)
        Assert ($smokeWindows.Count -eq 1) 'The isolated smoke created more than one drawer.'
        $window = $smokeWindows[0]
        $smokeScreen = $window.screen
        Assert ($state.keyboard -and $state.keyboard.layout -match '^[a-z]{2,3}$') `
            'Native keyboard layout was unavailable.'
        # The smoke must not reserve work area: ShellRoot disables Exclusions
        # while CAELESTIA_SHELL_SMOKE is set, so the live secondary display keeps
        # its bounds. The fixture below owns the reservation check.
        $afterSmoke = Snapshot 'desktop-smoke'
        Assert ((WorkIdentity $afterSmoke) -eq (WorkIdentity $before)) `
            'The installed smoke changed a work area; it must stay read-only.'
        $summary.smokeScreen = $smokeScreen
        $summary.keyboard = $state.keyboard
        Set-Phase 'smoke-complete'

        $quit = Invoke-QsIpc @('ipc', '--path', "$runtimePrefix\shell\shell.qml", 'call', 'shell', 'quit') 5000
        Assert ($quit.exitCode -eq 0) "Could not quit the installed smoke: $($quit.stderr)"
        Assert ($launcher.WaitForExit(15000)) 'The smoke launcher did not finish after quit.'
        Assert ($launcher.ExitCode -eq 0) 'The installed smoke failed; inspect launch logs.'
        Set-Phase 'smoke-quit'
    }

    # Exercise stable fullscreen reservations using the actual exclusions.
    # A real fullscreen target would also change the installed live shell.
    Copy-Item -LiteralPath "$repoRoot\windows\combined-prototype\FrameExclusionsTest.qml" -Destination "$runtimePrefix\shell\frame-test.qml" -Force
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = "$runtimePrefix\qs.exe"
    $info.Arguments = '--no-color --path "' + "$runtimePrefix\shell\frame-test.qml" + '"'
    $info.WorkingDirectory = $runtimePrefix
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['PATH'] = "$runtimePrefix;$env:SystemRoot\System32;$env:SystemRoot"
    $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$runtimePrefix\shell\imports;$runtimePrefix\qml"
    $info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$runtimePrefix\shell\imports;$runtimePrefix\qml"
    $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
    $info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
    $info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
    $info.EnvironmentVariables['CAELESTIA_SHELL_SCREEN'] = "$ScreenIndex"
    $info.EnvironmentVariables['QS_DISABLE_CRASH_HANDLER'] = '1'
    $fixture = [Diagnostics.Process]::Start($info)
    $fixtureOut = $fixture.StandardOutput.ReadToEndAsync()
    $fixtureErr = $fixture.StandardError.ReadToEndAsync()
    $summary.fixturePid = $fixture.Id
    Set-Phase 'fixture-started'

    # Wait for the fixture's own readiness handshake before asking it for
    # state. A cold first QML start can take much longer than the old 10 s
    # window, and an unanswered IPC call is "not ready yet", not a failure.
    $expected = $null
    Wait-Condition {
        if ($fixture.HasExited) {
            throw "The frame fixture exited before answering: $($fixtureErr.GetAwaiter().GetResult())"
        }
        $reply = Invoke-QsIpc @('ipc', '--pid', "$($fixture.Id)", 'call', 'frameTest', 'ready') 4000 -AllowTimeout
        if ($reply.timedOut -or $reply.exitCode -ne 0) { return $false }
        try { $ready = $reply.stdout | ConvertFrom-Json } catch { return $false }
        $script:fixtureReady = $ready
        return [bool]$ready.ready
    } 60 'The frame fixture did not finish starting.'
    Set-Phase 'fixture-ready'

    $reply = Invoke-QsIpc @('ipc', '--pid', "$($fixture.Id)", 'call', 'frameTest', 'expected') 4000
    if ($reply.exitCode -ne 0) { throw "The frame fixture did not report its expected reservation: $($reply.stderr)" }
    try { $expected = $reply.stdout | ConvertFrom-Json } catch { throw 'The frame fixture returned invalid state.' }
    Assert ($null -ne $expected -and $expected.screen) 'The frame fixture reported no screen.'
    if ($expected.screen -ne $script:fixtureReady.screen) {
        throw "The frame fixture changed screens while starting ($($script:fixtureReady.screen) -> $($expected.screen))."
    }
    Assert (-not $expected.reservations) 'The frame fixture reserved a work area before validation.'
    if ($smokeScreen) {
        Assert ($expected.screen -eq $smokeScreen) `
            "The fixture selected '$($expected.screen)' but the smoke measured '$smokeScreen'."
    }
    # Qt names screens by model on some systems; fall back to the screen origin,
    # accepting either native or device-independent coordinates.
    $target = @($before.monitors | Where-Object deviceName -eq $expected.screen)
    if ($target.Count -ne 1) {
        $target = @($before.monitors | Where-Object {
            ($_.physicalBounds.left -eq $expected.x -and $_.physicalBounds.top -eq $expected.y) -or
            ($_.physicalBounds.left -eq [Math]::Round($expected.x * $expected.dpr) -and
             $_.physicalBounds.top -eq [Math]::Round($expected.y * $expected.dpr)) })
    }
    Assert ($target.Count -eq 1) "The fixture screen '$($expected.screen)' at $($expected.x),$($expected.y) is not a monitor."
    $device = $target[0].deviceName
    # The fixture starts with its exclusions inactive. Refuse to reserve (or let
    # an application be moved by a temporary work-area change) on the primary
    # display, including with -SkipSmoke, where there is no smoke screen to
    # cross-check against.
    Assert (-not $target[0].primary) 'The frame fixture must reserve a secondary monitor only.'
    $idle = Snapshot 'fixture-idle'
    Assert ((WorkIdentity $idle) -eq (WorkIdentity $before)) `
        'The frame fixture changed a work area before its reservations were enabled.'
    $summary.fixtureScreen = $expected.screen
    $summary.fixtureDevice = $device
    $summary.expected = [ordered]@{
        left = $expected.left; top = $expected.top; right = $expected.right; bottom = $expected.bottom
        dpr = $expected.dpr; barZone = $expected.barZone; borderZone = $expected.borderZone
    }

    $reserve = Invoke-QsIpc @('ipc', '--pid', "$($fixture.Id)", 'call', 'frameTest', 'setReservations', 'true') 4000
    Assert ($reserve.exitCode -eq 0) "Could not enable the fixture reservations: $($reserve.stderr)"
    Set-Phase 'fixture-validated'

    $delta = $null
    Wait-Condition {
        if ($fixture.HasExited) {
            throw "The frame fixture exited before reserving: $($fixtureErr.GetAwaiter().GetResult())"
        }
        $snapshot = Snapshot 'fixture-reserved'
        $script:fixtureLast = $snapshot
        $script:fixtureDelta = WorkDeltas $before $snapshot $device
        if ($null -eq $script:fixtureDelta) { return $false }
        return ($script:fixtureDelta.left -gt 0 -and $script:fixtureDelta.top -gt 0 `
            -and $script:fixtureDelta.right -gt 0 -and $script:fixtureDelta.bottom -gt 0)
    } 10 'The frame fixture did not reserve the four edges.'
    $delta = $script:fixtureDelta
    $reserved = $script:fixtureLast
    foreach ($edge in @('left', 'top', 'right', 'bottom')) {
        Assert ([Math]::Abs($delta[$edge] - $expected.$edge) -le 2) `
            "$edge reservation was $($delta[$edge]) px; expected $($expected.$edge) px."
    }
    Assert (OtherWorkUnchanged $before $reserved $device) 'The frame fixture changed another monitor.'
    Assert (($reserved.taskbar | ConvertTo-Json -Compress) -eq ($before.taskbar | ConvertTo-Json -Compress)) `
        'The frame fixture changed taskbar flags.'
    $summary.delta = $delta
    Set-Phase 'fixture-reserved'

    # Fullscreen input must keep every reservation registered, on entry and on
    # exit, without moving the work area at all.
    $set = Invoke-QsIpc @('ipc', '--pid', "$($fixture.Id)", 'call', 'frameTest', 'setFullscreen', 'true') 4000
    Assert ($set.exitCode -eq 0) "Could not set the fixture fullscreen input: $($set.stderr)"
    Start-Sleep -Milliseconds 750
    $fullscreen = Snapshot 'fixture-fullscreen'
    Assert ((WorkIdentity $fullscreen) -eq (WorkIdentity $reserved)) 'Fullscreen changed the reserved work area.'
    Set-Phase 'fixture-fullscreen'

    $clear = Invoke-QsIpc @('ipc', '--pid', "$($fixture.Id)", 'call', 'frameTest', 'setFullscreen', 'false') 4000
    Assert ($clear.exitCode -eq 0) "Could not clear the fixture fullscreen input: $($clear.stderr)"
    Start-Sleep -Milliseconds 750
    $restored = Snapshot 'fixture-restored'
    Assert ((WorkIdentity $restored) -eq (WorkIdentity $reserved)) 'Leaving fullscreen changed the reserved work area.'
    Set-Phase 'fixture-restored'

    $quit = Invoke-QsIpc @('ipc', '--pid', "$($fixture.Id)", 'call', 'frameTest', 'quit') 4000
    Assert ($quit.exitCode -eq 0) "Could not quit the frame fixture: $($quit.stderr)"
    Assert ($fixture.WaitForExit(5000)) 'The fullscreen fixture did not quit.'
    $summary.fullscreenFixture = $fixture.ExitCode -eq 0
    Assert $summary.fullscreenFixture 'The fullscreen fixture failed.'
    Set-Phase 'fixture-quit'
    $summary.passed = $true
} catch {
    $failure = $_.ToString()
    $summary.failure = $failure
} finally {
    try { Stop-OwnedProcesses } catch { $summary.cleanupError = $_.ToString() }
    if ($launcher -and -not $launcher.HasExited) {
        $null = $launcher.WaitForExit(10000)
        if (-not $launcher.HasExited) {
            try { $launcher.Kill(); $null = $launcher.WaitForExit(3000) } catch {}
            $summary.cleanupError = 'The smoke launcher had to be killed.'
        }
    }
    try { Save-FixtureArtifacts } catch { $summary.cleanupError = $_.ToString() }
    Start-Sleep -Milliseconds 500
    $after = Snapshot 'desktop-after'
    if ((WorkIdentity $before) -ne (WorkIdentity $after) `
        -or ($before.taskbar | ConvertTo-Json -Compress) -ne ($after.taskbar | ConvertTo-Json -Compress)) {
        $summary.passed = $false
        if (-not $summary.failure) {
            $summary.failure = 'Work areas or taskbar state differed after quit.'
        } else {
            $summary.cleanupFailure = 'Work areas or taskbar state differed after quit.'
        }
    }
    foreach ($process in @($before.relevantProcesses | Where-Object name -eq 'qs')) {
        if (-not (Get-Process -Id $process.pid -ErrorAction SilentlyContinue)) {
            $summary.passed = $false
            if (-not $summary.failure) {
                $summary.failure = "An existing shell process exited: $($process.pid)"
            } else {
                $summary.cleanupFailure = "An existing shell process exited: $($process.pid)"
            }
        }
    }
    if (Test-Path -LiteralPath "$profile\logs") {
        Copy-Item -LiteralPath "$profile\logs" -Destination "$OutputRoot\runtime-logs" -Recurse -Force
    }
    $summary.elapsedSeconds = [int]([DateTime]::UtcNow - $startedAt).TotalSeconds
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$OutputRoot\result.json" -Encoding UTF8
}
$summary | ConvertTo-Json -Depth 10
if (-not $summary.passed) { throw $summary.failure }
