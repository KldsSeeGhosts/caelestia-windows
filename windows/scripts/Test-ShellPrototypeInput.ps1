[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][switch]$AllowDesktopInput,
    [switch]$TestTransparencyOff,
    [string]$BuildRoot,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
if (-not $AllowDesktopInput) { throw 'Real pointer/keyboard/focus tests require -AllowDesktopInput.' }
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
if (-not $BuildRoot) { $BuildRoot = "$repoRoot\windows\.local\build" }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $OutputDirectory) { $OutputDirectory = "$BuildRoot\input-$(Get-Date -Format yyyyMMdd-HHmmss-fff)" }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Add-Type -Path "$PSScriptRoot\NativeInputTest.cs"
$oldPath = $env:PATH
$env:PATH = "$QtPrefix\bin;$env:PATH"
$qs = "$BuildRoot\quickshell\qs.exe"
$native = [Caelestia.InputTest.Native]
$previousDpi = $native::SetThreadDpiAwarenessContext([IntPtr](-4))
if ($previousDpi -eq [IntPtr]::Zero) { throw 'Could not select physical DPI context.' }
$previousForeground = $native::GetForegroundWindow()
$previousCursor = New-Object Caelestia.InputTest.Native+Point
if (-not $native::GetCursorPos([ref]$previousCursor)) { throw 'Could not read pointer position.' }
$transparencyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$previousTransparency = Get-ItemPropertyValue -LiteralPath $transparencyKey -Name EnableTransparency
$uiSettingsType = [Windows.UI.ViewManagement.UISettings,Windows.UI.ViewManagement,ContentType=WindowsRuntime]
$previousAdvancedEffects = ([Activator]::CreateInstance($uiSettingsType)).AdvancedEffectsEnabled
$fixture = $null
$fixtureWindow = [IntPtr]::Zero
$launcher = $null
$prototypePid = 0
$records = New-Object Collections.Generic.List[object]
$passed = $false
$failure = $null

function Get-State {
    $raw = & $qs ipc --pid $prototypePid call prototype state
    if ($LASTEXITCODE -ne 0) { throw "Exact-instance IPC failed: $raw" }
    return $raw | ConvertFrom-Json
}
function Wait-State([scriptblock]$Condition, [string]$Message, [int]$Timeout = 3000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $state = Get-State
        if (& $Condition $state) { return $state }
        Start-Sleep -Milliseconds 30
    } while ($timer.ElapsedMilliseconds -lt $Timeout)
    throw "$Message : $($state | ConvertTo-Json -Depth 5 -Compress)"
}
function Assert([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Wait-Foreground([int]$Expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        $foreground = $native::ForegroundProcess()
        if ($foreground -eq $Expected) { return }
        Start-Sleep -Milliseconds 20
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected foreground PID $Expected, observed $foreground."
}
function Record([string]$Scenario, $State = (Get-State), $Details = $null) {
    $record = [ordered]@{
        scenario = $Scenario; timestampUtc = [DateTime]::UtcNow.ToString('o')
        prototypePid = $prototypePid; foregroundPid = $native::ForegroundProcess()
        state = $State; detail = $Details
    }
    $records.Add($record)
    $record | ConvertTo-Json -Depth 12 -Compress | Add-Content -LiteralPath "$OutputDirectory\scenarios.jsonl"
    Write-Output "PASS $Scenario"
}
function Move-Local([double]$X, [double]$Y) {
    $native::Move([int]($windowRect.Left + $X * $state.dpr), [int]($windowRect.Top + $Y * $state.dpr))
}
function Click-Local([double]$X, [double]$Y) {
    $native::Click([int]($windowRect.Left + $X * $state.dpr), [int]($windowRect.Top + $Y * $state.dpr))
}
function Drag-Local([double]$X1, [double]$Y1, [double]$X2, [double]$Y2) {
    $native::Drag([int]($windowRect.Left + $X1 * $state.dpr), [int]($windowRect.Top + $Y1 * $state.dpr),
        [int]($windowRect.Left + $X2 * $state.dpr), [int]($windowRect.Top + $Y2 * $state.dpr))
}
function Read-Fixture {
    Get-Content -LiteralPath "$OutputDirectory\fixture.jsonl" -Tail 1 | ConvertFrom-Json
}
function Wait-FixtureClick([int]$Expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        $fixtureState = Read-Fixture
        if ($fixtureState.clickCount -eq $Expected) { return }
        if ($fixtureState.clickCount -gt $Expected) { break }
        Start-Sleep -Milliseconds 20
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Fixture expected $Expected clicks, observed $($fixtureState.clickCount)."
}
function Open-Session {
    Move-Local 3 200
    $state = Wait-State { param($s) $s.barWidth -gt 59 } 'Hover bar did not open'
    Click-Local $state.powerCenter.x $state.powerCenter.y
    Wait-State { param($s) $s.session -and $s.sessionOffset -lt 0.01 -and $s.sessionFocusedIcon -ne '' } 'Session did not open/focus'
}

try {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath "$OutputDirectory\desktop-before.json" | Out-Null
    # The test owns this fixture and launcher only. Existing applications stay open.
    $fixture = Start-Process powershell.exe -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$OutputDirectory\fixture.stdout.log" -RedirectStandardError "$OutputDirectory\fixture.stderr.log" -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-STA', '-File', "`"$PSScriptRoot\Start-InputTarget.ps1`"",
        '-LogPath', "`"$OutputDirectory\fixture.jsonl`"", '-ClientWidth', '1800', '-ClientHeight', '1300')
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do { $fixtureWindow = $native::WindowForProcess($fixture.Id); Start-Sleep -Milliseconds 100 } while (
        $fixtureWindow -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline -and -not $fixture.HasExited)
    Assert ($fixtureWindow -ne [IntPtr]::Zero) 'Input fixture did not start'
    if ($TestTransparencyOff) {
        Set-ItemProperty -LiteralPath $transparencyKey -Name EnableTransparency -Value 0
        Assert ((Get-ItemPropertyValue -LiteralPath $transparencyKey -Name EnableTransparency) -eq 0) 'Transparency did not turn off'
    }
    $observedTransparency = Get-ItemPropertyValue -LiteralPath $transparencyKey -Name EnableTransparency
    $observedAdvancedEffects = ([Activator]::CreateInstance($uiSettingsType)).AdvancedEffectsEnabled
    if ($TestTransparencyOff) { Assert (-not $observedAdvancedEffects) 'Windows advanced effects remain enabled' }
    # Test startup under the real preference. Do not broadcast live desktop
    # reconfiguration to unrelated shells or change their running surfaces.
    $launcher = Start-Process powershell.exe -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$OutputDirectory\launcher.stdout.log" -RedirectStandardError "$OutputDirectory\launcher.stderr.log" `
        -ArgumentList @('-NoProfile', '-File', "`"$PSScriptRoot\Start-ShellPrototype.ps1`"", '-QtPrefix', "`"$QtPrefix`"",
            '-BuildRoot', "`"$BuildRoot`"", '-Wait', '-TraceInput')
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 100
        $launchText = Get-Content -LiteralPath "$OutputDirectory\launcher.stdout.log" -Raw
        if ($launchText -match 'prototype \(PID (\d+)\)') { $prototypePid = [int]$Matches[1] }
    } while ($prototypePid -eq 0 -and [DateTime]::UtcNow -lt $deadline -and -not $launcher.HasExited)
    Assert ($prototypePid -gt 0) 'Prototype launcher did not report its PID'
    Assert ($launchText -match 'Staged source: ([^\r\n]+)') 'Prototype stage path missing'
    $runName = Split-Path -Leaf $Matches[1]
    $capturePath = "$BuildRoot\logs\$runName.png"
    $prototype = Get-Process -Id $prototypePid
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do { $prototypeWindow = $native::WindowForProcess($prototypePid); Start-Sleep -Milliseconds 100 } while (
        $prototypeWindow -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline -and -not $prototype.HasExited)
    Assert ($prototypeWindow -ne [IntPtr]::Zero) 'Prototype window did not start'

    foreach ($screenIndex in @(0, 1, 0)) {
        & $qs ipc --pid $prototypePid call prototype moveToScreen $screenIndex | Out-Null
        Start-Sleep -Milliseconds 700
        $state = Get-State
        $windowRect = New-Object Caelestia.InputTest.Native+Rect
        Assert ($native::GetWindowRect($prototypeWindow, [ref]$windowRect)) 'No native window rectangle'
        Assert ($state.width -eq 900 -and $state.height -eq 620) 'Window geometry changed on transfer'
        Assert ([Math]::Abs(($windowRect.Right - $windowRect.Left) - 900 * $state.dpr) -le 1) 'Physical width disagrees with DPR'
        Assert ($native::SetWindowPos($fixtureWindow, [IntPtr]::Zero,
            $windowRect.Left - 30, $windowRect.Top - 30, [int](950 * $state.dpr), [int](700 * $state.dpr), 0x0010)) 'Fixture placement failed'
        Click-Local 400 400
        Start-Sleep -Milliseconds 200
        Assert ($native::ForegroundProcess() -eq $fixture.Id) 'Fixture did not receive transparent-center click'
        Move-Local 400 300
        $state = Wait-State { param($s) $s.barWidth -lt 11 -and -not $s.containsMouse } 'Bar did not close'
        $prefix = "screen$screenIndex-dpr$($state.dpr)"
        # One SendInput movement, then stationary. No click or secondary movement.
        Move-Local 3 200
        $state = Wait-State { param($s) $s.barHovered -and $s.containsMouse -and $s.barWidth -gt 59 } 'Single-jump hover failed'
        $stationaryCursor = New-Object Caelestia.InputTest.Native+Point
        $native::GetCursorPos([ref]$stationaryCursor) | Out-Null
        Assert ([Math]::Abs($stationaryCursor.X - ($windowRect.Left + 3 * $state.dpr)) -le 2 -and
            [Math]::Abs($stationaryCursor.Y - ($windowRect.Top + 200 * $state.dpr)) -le 2) 'External pointer movement invalidated stationary hover'
        Assert ($native::ForegroundProcess() -eq $fixture.Id) 'Hover stole foreground focus'
        Record "$prefix-single-jump-hover" $state
        for ($i = 0; $i -lt 12; $i++) {
            Move-Local 400 300
            Start-Sleep -Milliseconds 40
            Move-Local 3 200
            Start-Sleep -Milliseconds 40
        }
        $state = Wait-State { param($s) $s.barWidth -gt 59 } 'Rapid boundary entry left bar closed'
        Move-Local 400 300
        $state = Wait-State { param($s) $s.barWidth -lt 11 } 'Rapid boundary exit left bar open'
        Record "$prefix-rapid-boundaries" $state @{ cycles = 12; dwellMilliseconds = 40 }

        # Original Interactions drag thresholds pin/unpin the bar.
        Move-Local 3 200
        $state = Wait-State { param($s) $s.barWidth -gt 59 } 'Hover did not reopen'
        Drag-Local 3 200 ($state.barDragThreshold + 45) 200
        $state = Wait-State { param($s) $s.barPinned } 'Bar drag did not pin'
        Move-Local 400 300
        Start-Sleep -Milliseconds 450
        $state = Get-State
        Assert ($state.barPinned -and $state.barWidth -gt 59) 'Pinned bar closed on leave'
        Record "$prefix-bar-pin" $state
        Drag-Local 50 200 3 200
        $state = Wait-State { param($s) -not $s.barPinned } 'Bar reverse drag did not unpin'
        Move-Local 400 300
        $state = Wait-State { param($s) $s.barWidth -lt 11 } 'Unpinned bar did not close'
        Record "$prefix-bar-unpin" $state

        $state = Open-Session
        Assert ($native::ForegroundProcess() -eq $prototypePid) 'Session did not acquire foreground'
        Assert ($state.sessionButtons.Count -eq 4) 'Required session buttons missing'
        Record "$prefix-power-open" $state
        $captureStart = [DateTime]::UtcNow
        & $qs ipc --pid $prototypePid call prototype capture | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do { Start-Sleep -Milliseconds 50 } while (
            (-not (Test-Path -LiteralPath $capturePath) -or (Get-Item -LiteralPath $capturePath).LastWriteTimeUtc -lt $captureStart) -and
            [DateTime]::UtcNow -lt $deadline)
        Assert ((Test-Path -LiteralPath $capturePath) -and (Get-Item -LiteralPath $capturePath).LastWriteTimeUtc -ge $captureStart) 'Capture did not complete'
        Copy-Item -LiteralPath $capturePath -Destination "$OutputDirectory\$prefix-open-$($records.Count).png"
        $initialIcon = $state.sessionFocusedIcon
        $native::Key(0x28) # Down
        $state = Wait-State { param($s) $s.sessionFocusedIcon -ne $initialIcon } 'Down traversal failed'
        $downIcon = $state.sessionFocusedIcon
        $native::Key(0x26) # Up
        $state = Wait-State { param($s) $s.sessionFocusedIcon -eq $initialIcon } 'Up traversal failed'
        $native::Key(0x09) # Tab
        $state = Wait-State { param($s) $s.sessionFocusedIcon -eq $downIcon } 'Tab traversal failed'
        Record "$prefix-keyboard" $state @{ initialIcon = $initialIcon; downIcon = $downIcon }
        $native::Key(0x0d) # Return is consumed by the unavailable session adapter.
        $native::Key(0x1b)
        $state = Wait-State { param($s) -not $s.sessionVisible -and $s.focusStatus -in @('restore-succeeded', 'restore-requested') } 'Escape/focus return failed'
        # Cross-thread SetForegroundWindow can complete after the request returns.
        # Observe the real foreground; do not retry activation or trust the status alone.
        Wait-Foreground $fixture.Id
        Record "$prefix-escape-focus-return" $state

        $state = Open-Session
        $clicksBefore = (Read-Fixture).clickCount
        Click-Local 400 400
        $state = Wait-State { param($s) -not $s.sessionVisible } 'Outside click did not dismiss'
        Start-Sleep -Milliseconds 150
        Assert ((Read-Fixture).clickCount -eq $clicksBefore + 1) 'Outside click did not reach fixture exactly once'
        Assert ($native::ForegroundProcess() -eq $fixture.Id) 'Outside click lost fixture foreground'
        Record "$prefix-outside-click" $state @{ clicksBefore = $clicksBefore; clicksAfter = (Read-Fixture).clickCount }

        # Switch foreground without a mouse button during the backend's 500 ms grace.
        Move-Local 3 200
        $state = Wait-State { param($s) $s.barWidth -gt 59 } 'Hover did not reopen'
        Click-Local $state.powerCenter.x $state.powerCenter.y
        $openingTimer = [Diagnostics.Stopwatch]::StartNew()
        $state = Wait-State { param($s) $s.session } 'Session did not start'
        $switchTimer = [Diagnostics.Stopwatch]::StartNew()
        Assert ($native::SetForegroundWindow($fixtureWindow)) 'Early fixture activation denied'
        $switchAge = $openingTimer.ElapsedMilliseconds
        Assert ($switchAge -lt 500) 'App switch missed the early foreground grace period'
        $state = Wait-State { param($s) -not $s.session -and $s.focusStatus -like 'restore-skipped*' } 'Early app switch was not reconciled'
        Assert ($native::ForegroundProcess() -eq $fixture.Id) 'Early switch focus was stolen back'
        Record "$prefix-early-app-switch" $state @{ switchAgeMilliseconds = $switchAge; reconciliationMilliseconds = $switchTimer.ElapsedMilliseconds }

        # Original right-edge session gestures, avoiding action buttons.
        Drag-Local 897 $state.sessionDragY 780 $state.sessionDragY
        $state = Wait-State { param($s) $s.session -and $s.sessionOffset -lt 0.01 } 'Session edge drag did not open'
        Record "$prefix-session-drag-open" $state
        Drag-Local $state.sessionButtons[0].center.x $state.sessionDragY 897 $state.sessionDragY
        $state = Wait-State { param($s) -not $s.sessionVisible } 'Session reverse drag did not close'
        Record "$prefix-session-drag-close" $state
        for ($i = 0; $i -lt 4; $i++) {
            $state = Open-Session
            $native::Key(0x1b)
            $state = Wait-State { param($s) -not $s.sessionVisible } 'Repeated Escape failed'
        }
        $clicksBefore = (Read-Fixture).clickCount
        Click-Local 400 400
        Wait-FixtureClick ($clicksBefore + 1)
        Record "$prefix-repeated-open-close" $state @{ cycles = 4 }
    }
    $passed = $true
} catch {
    $failure = $_.ToString()
    Write-Warning $failure
} finally {
    if ($prototypePid -gt 0 -and (Get-Process -Id $prototypePid -ErrorAction SilentlyContinue)) {
        & $qs ipc --pid $prototypePid call prototype quit | Out-Null
    }
    if ($launcher -and -not $launcher.WaitForExit(10000)) { $passed = $false; $failure = 'Launcher did not exit after exact-instance quit.' }
    if ($fixture -and -not $fixture.HasExited) {
        if ($fixtureWindow -eq [IntPtr]::Zero) { $fixtureWindow = $native::WindowForProcess($fixture.Id) }
        $native::PostMessage($fixtureWindow, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        if (-not $fixture.WaitForExit(15000)) {
            $passed = $false
            $failure = "$failure Fixture process did not exit after closing."
        }
    }
    if ($TestTransparencyOff) {
        Set-ItemProperty -LiteralPath $transparencyKey -Name EnableTransparency -Value $previousTransparency
    }
    $restoredTransparency = Get-ItemPropertyValue -LiteralPath $transparencyKey -Name EnableTransparency
    $restoredAdvancedEffects = ([Activator]::CreateInstance($uiSettingsType)).AdvancedEffectsEnabled
    if ($restoredTransparency -ne $previousTransparency) { $passed = $false; $failure = 'Transparency was not restored.' }
    if ($restoredAdvancedEffects -ne $previousAdvancedEffects) { $passed = $false; $failure = 'Windows advanced effects were not restored.' }
    $native::Move($previousCursor.X, $previousCursor.Y)
    if ($native::IsWindow($previousForeground)) { $native::SetForegroundWindow($previousForeground) | Out-Null }
    $native::SetThreadDpiAwarenessContext($previousDpi) | Out-Null
    $env:PATH = $oldPath
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath "$OutputDirectory\desktop-after.json" | Out-Null
    $before = Get-Content -LiteralPath "$OutputDirectory\desktop-before.json" -Raw | ConvertFrom-Json
    $after = Get-Content -LiteralPath "$OutputDirectory\desktop-after.json" -Raw | ConvertFrom-Json
    $desktopPreserved = (($before.monitors | ConvertTo-Json -Depth 8 -Compress) -eq ($after.monitors | ConvertTo-Json -Depth 8 -Compress)) -and
        (($before.taskbar | ConvertTo-Json -Compress) -eq ($after.taskbar | ConvertTo-Json -Compress)) -and
        (($before.relevantProcesses | ConvertTo-Json -Compress) -eq ($after.relevantProcesses | ConvertTo-Json -Compress))
    if (-not $desktopPreserved) { $passed = $false; $failure = 'Desktop state or relevant processes changed.' }
    $runtime = $null
    if ($launcher -and $launcher.HasExited) {
        $launchText = Get-Content -LiteralPath "$OutputDirectory\launcher.stdout.log" -Raw
        $jsonStart = $launchText.IndexOf('{')
        if ($jsonStart -ge 0) { $runtime = $launchText.Substring($jsonStart) | ConvertFrom-Json }
        if (-not $runtime -or $runtime.exitCode -ne 0) { $passed = $false; $failure = 'Launcher/runtime result missing or failed.' }
        if ($runtime) {
            $diagnostics = Get-Content -LiteralPath $runtime.stdout, $runtime.stderr -Raw
            if ($diagnostics -match '(?m)^\d{4}-\d{2}-\d{2} [^\r\n]+ (WARN(?:ING)?|ERROR|FATAL|CRIT(?:ICAL)?)\b') {
                $passed = $false; $failure = 'Runtime diagnostics occurred.'
            }
        }
    }
    [ordered]@{
        passed = $passed; failure = $failure; sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        sourceDirty = [bool](& git -C $repoRoot status --porcelain); runtime = $runtime
        testScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
        nativeInputSha256 = (Get-FileHash -LiteralPath "$PSScriptRoot\NativeInputTest.cs").Hash
        desktopPreserved = $desktopPreserved; transparencyOff = $TestTransparencyOff.IsPresent
        transparencyBefore = $previousTransparency; transparencyAfter = $restoredTransparency
        transparencyDuring = $observedTransparency
        advancedEffectsBefore = $previousAdvancedEffects; advancedEffectsDuring = $observedAdvancedEffects
        advancedEffectsAfter = $restoredAdvancedEffects
        command = 'powershell -NoProfile -File windows/scripts/Test-ShellPrototypeInput.ps1'
        parameters = @{ QtPrefix = $QtPrefix; AllowDesktopInput = $true; TestTransparencyOff = $TestTransparencyOff.IsPresent
            BuildRoot = $BuildRoot; OutputDirectory = $OutputDirectory }
        scenarioCount = $records.Count
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$OutputDirectory\result.json" -Encoding UTF8
}
Write-Output "Evidence: $OutputDirectory"
if (-not $passed) { throw "Native input acceptance failed: $failure" }
