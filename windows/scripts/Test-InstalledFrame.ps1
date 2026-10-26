[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [ValidateRange(0, 15)][int]$ScreenIndex = 1,
    [string]$OutputRoot
)

# A temporary deployed runtime, with read-only smoke on one secondary display.
# No takeover supervisor, taskbar changes, global recovery or desktop input.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $repoRoot ('windows\.local\frame-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$temporaryRoot = Join-Path $env:TEMP ('caelestia-frame-' + [guid]::NewGuid().ToString('N'))
$prefix = Join-Path $temporaryRoot 'install'
$profile = Join-Path $temporaryRoot 'profile'
$launcher = $null
$childPid = $null
$fixture = $null
$failure = $null
$summary = [ordered]@{ passed = $false; prefix = $prefix; profile = $profile; screenIndex = $ScreenIndex }
function Snapshot([string]$Name) {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath "$OutputRoot\$Name.json" | ConvertFrom-Json
}
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function WorkIdentity($State) {
    @($State.monitors | ForEach-Object {
        "$($_.deviceName):$($_.physicalWorkArea | ConvertTo-Json -Compress)"
    }) -join ';'
}
function ShellState {
    $raw = & "$prefix\Start-Caelestia.ps1" -Prefix $prefix -Command State -SkipSchemeRuntime
    $raw | ConvertFrom-Json
}

$before = Snapshot 'desktop-before'
# ScreenIndex is a Qt index, not EnumDisplayMonitors order. Check the actual
# selected screen against the primary bounds after startup, before asserting.
Assert ($before.monitors.Count -gt 1) 'This live-safe test requires a secondary monitor.'
try {
    & "$PSScriptRoot\Install-Caelestia.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -Prefix $prefix -ProfileRoot $profile *> "$OutputRoot\install.log"
    $arguments = '-NoProfile -File "' + "$prefix\Start-Caelestia.ps1" + '" -Prefix "' + $prefix `
        + '" -Smoke -ScreenIndex ' + $ScreenIndex + ' -SkipSchemeRuntime'
    $launcher = Start-Process "$PSHOME\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$OutputRoot\launch.stdout.log" -RedirectStandardError "$OutputRoot\launch.stderr.log"
    $null = $launcher.Handle

    $state = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(35)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try { $state = ShellState } catch { $state = $null }
        if ($state -and $state.smokeComplete) { break }
        $launcher.Refresh()
        if ($launcher.HasExited) { throw 'Installed smoke exited before completing.' }
    }
    Assert ($state -and $state.smokeComplete) 'Installed smoke did not complete.'
    $state | ConvertTo-Json -Depth 12 | Set-Content "$OutputRoot\shell-state.json" -Encoding UTF8
    Assert ($state.windows.Count -eq 1) 'The isolated smoke created more than one drawer.'
    $window = $state.windows[0]
    $reserved = Snapshot 'desktop-reserved'
    $changed = @($reserved.monitors | Where-Object {
        $device = $_.deviceName
        $base = $before.monitors | Where-Object deviceName -eq $device
        ($_.physicalWorkArea | ConvertTo-Json -Compress) -ne ($base.physicalWorkArea | ConvertTo-Json -Compress)
    })
    Assert ($changed.Count -eq 1 -and -not $changed[0].primary) 'Only the secondary monitor may change.'
    $monitor = $changed[0]
    $base = ($before.monitors | Where-Object deviceName -eq $monitor.deviceName).physicalWorkArea
    $work = $monitor.physicalWorkArea
    $delta = [ordered]@{
        left = $work.left - $base.left
        top = $work.top - $base.top
        right = $base.right - $work.right
        bottom = $base.bottom - $work.bottom
    }
    $expected = [ordered]@{
        left = [int][Math]::Round($window.barZone * $window.dpr)
        top = [int][Math]::Round($window.borderZone * $window.dpr)
        right = [int][Math]::Round($window.borderZone * $window.dpr)
        bottom = [int][Math]::Round($window.borderZone * $window.dpr)
    }
    foreach ($edge in @('left', 'top', 'right', 'bottom')) {
        Assert ($delta[$edge] -gt 0 -and [Math]::Abs($delta[$edge] - $expected[$edge]) -le 2) `
            "$edge reservation was $($delta[$edge]) px; expected $($expected[$edge]) px."
    }
    Assert ($state.keyboard.layout -match '^[a-z]{2,3}$') 'Native keyboard layout was unavailable.'
    $summary.monitor = $monitor.deviceName
    $summary.delta = $delta
    $summary.expected = $expected
    $summary.keyboard = $state.keyboard
    & "$prefix\Start-Caelestia.ps1" -Prefix $prefix -Command Quit -SkipSchemeRuntime | Out-Null
    Assert ($launcher.WaitForExit(15000)) 'Smoke launcher did not finish after quit.'
    Assert ($launcher.ExitCode -eq 0) 'Installed smoke failed; inspect launch logs.'

    # Exercise fullscreen release/reacquisition using the actual exclusions.
    # A real fullscreen target would also change the installed live shell.
    Copy-Item -LiteralPath "$repoRoot\windows\combined-prototype\FrameExclusionsTest.qml" -Destination "$prefix\shell\frame-test.qml"
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = "$prefix\qs.exe"
    $info.Arguments = '--no-color --path "' + "$prefix\shell\frame-test.qml" + '"'
    $info.WorkingDirectory = $prefix
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['PATH'] = "$prefix;$env:SystemRoot\System32;$env:SystemRoot"
    $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$prefix\shell\imports;$prefix\qml"
    $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
    $info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
    $info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
    $info.EnvironmentVariables['CAELESTIA_SHELL_SCREEN'] = "$ScreenIndex"
    $fixture = [Diagnostics.Process]::Start($info)
    $fixtureOut = $fixture.StandardOutput.ReadToEndAsync()
    $fixtureErr = $fixture.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 200
        $snapshot = Snapshot 'fixture-reserved'
        if ((WorkIdentity $snapshot) -eq (WorkIdentity $reserved)) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ((WorkIdentity $snapshot) -eq (WorkIdentity $reserved)) 'The fullscreen fixture did not reserve the same four edges.'
    & "$prefix\qs.exe" ipc --pid $fixture.Id call frameTest setFullscreen true | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Could not set the fixture fullscreen input.'
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        Start-Sleep -Milliseconds 200
        $snapshot = Snapshot 'fixture-fullscreen'
        if ((WorkIdentity $snapshot) -eq (WorkIdentity $before)) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ((WorkIdentity $snapshot) -eq (WorkIdentity $before)) 'Fullscreen did not release all four exclusions.'
    & "$prefix\qs.exe" ipc --pid $fixture.Id call frameTest setFullscreen false | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Could not clear the fixture fullscreen input.'
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        Start-Sleep -Milliseconds 200
        $snapshot = Snapshot 'fixture-restored-frame'
        if ((WorkIdentity $snapshot) -eq (WorkIdentity $reserved)) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ((WorkIdentity $snapshot) -eq (WorkIdentity $reserved)) 'Leaving fullscreen did not restore all four exclusions.'
    & "$prefix\qs.exe" ipc --pid $fixture.Id call frameTest quit | Out-Null
    Assert ($fixture.WaitForExit(3000)) 'The fullscreen fixture did not quit.'
    $summary.fullscreenFixture = $fixture.ExitCode -eq 0
    Assert $summary.fullscreenFixture 'The fullscreen fixture failed.'
    $summary.passed = $true
} catch {
    $failure = $_.ToString()
    $summary.failure = $failure
} finally {
    # This exact executable path identifies only this test's child, even when
    # the live shell has a running supervisor and identical process name.
    $owned = @(Get-Process qs -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq "$prefix\qs.exe" })
    foreach ($child in $owned) {
        $childPid = $child.Id
        if ($fixture -and $child.Id -eq $fixture.Id) {
            & "$prefix\qs.exe" ipc --pid $fixture.Id call frameTest quit | Out-Null
        }
        try { & "$prefix\Start-Caelestia.ps1" -Prefix $prefix -Command Quit -SkipSchemeRuntime | Out-Null } catch {}
        if (-not $child.WaitForExit(3000)) { $child.Kill(); $child.WaitForExit() }
    }
    if ($launcher -and -not $launcher.HasExited) { $null = $launcher.WaitForExit(10000) }
    if ($fixture -and $fixture.HasExited) {
        $fixtureOut.GetAwaiter().GetResult() | Set-Content "$OutputRoot\fixture.stdout.log"
        $fixtureErr.GetAwaiter().GetResult() | Set-Content "$OutputRoot\fixture.stderr.log"
        if (-not ('Caelestia.Takeover.Native' -as [type])) {
            Add-Type -Path "$PSScriptRoot\DesktopTakeover.cs" -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
        }
        [Caelestia.Takeover.Native]::RemoveStaleAppBars($fixture.Id) | Out-Null
    }
    Start-Sleep -Milliseconds 500
    $after = Snapshot 'desktop-after'
    if ((WorkIdentity $before) -ne (WorkIdentity $after) `
        -or ($before.taskbar | ConvertTo-Json -Compress) -ne ($after.taskbar | ConvertTo-Json -Compress)) {
        $summary.passed = $false
        $summary.failure = 'Work areas or taskbar state differed after quit.'
    }
    foreach ($process in @($before.relevantProcesses | Where-Object name -eq 'qs')) {
        if (-not (Get-Process -Id $process.pid -ErrorAction SilentlyContinue)) {
            $summary.passed = $false
            $summary.failure = "An existing shell process exited: $($process.pid)"
        }
    }
    if (Test-Path "$profile\logs") { Copy-Item -LiteralPath "$profile\logs" -Destination "$OutputRoot\runtime-logs" -Recurse }
    $summary | ConvertTo-Json -Depth 10 | Set-Content "$OutputRoot\result.json" -Encoding UTF8
}
$summary | ConvertTo-Json -Depth 10
if (-not $summary.passed) { throw $summary.failure }
