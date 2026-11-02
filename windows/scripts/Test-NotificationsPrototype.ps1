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
$output = Join-Path $BuildRoot ('notifications-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$records = New-Object Collections.Generic.List[object]
$failure = $null
$profile = Join-Path $BuildRoot 'notifications-prototype-profile'
$historyPath = Join-Path $profile 'state\notifs.json'
# These are test-owned paths. The ordinary user profile is never read or
# written; the legacy path is measured only to prove it did not change.
$legacyHistory = Join-Path $env:USERPROFILE '.local\state\caelestia\notifs.json'

function Get-DesktopSnapshot([string]$Name) {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath (Join-Path $output "$Name.json") | ConvertFrom-Json
}
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Desktop-Identity($State) {
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorerRunning = $State.explorerRunning
        # Our own short-lived qs.exe smokes (and concurrent agents' smokes) are
        # not persistent desktop state.
        processes = @($State.relevantProcesses | Where-Object { $_.name -notin @('qs', 'quickshell') })
    } | ConvertTo-Json -Depth 10 -Compress
}
function FileIdentity([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [ordered]@{ exists = $false; sha256 = '' } }
    [ordered]@{ exists = $true; sha256 = (Get-FileHash -LiteralPath $Path).Hash }
}
function Assert-PathConfined([string]$Path, [string]$Root, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path)
    Assert ($full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) `
        "$Label is outside the isolated profile: $full"
}
function Assert-Common($State, [string]$Mode) {
    Assert ($State.mirroringOff -eq $true) "$Mode mode enabled system notification mirroring."
    Assert ($State.mirrorSystemNotifications -eq $false) "$Mode mode requested mirrorSystemNotifications."
    Assert ($State.systemMirrorActive -eq $false) "$Mode mode activated the system mirror."
    Assert ($State.protectedDismissals -eq 0) "$Mode mode targeted a real Windows notification for dismissal."
    # Mirroring, its two side effects and every access request are absent.
    Assert ($State.mirrorOptIn -eq $false) "$Mode mode staged the mirroring opt-in."
    Assert ($State.mirrorControlEnabled -eq $false) "$Mode mode offered the mirroring control."
    Assert ($State.mirrorStatus -eq 'disabled') "$Mode mode reported mirroring status '$($State.mirrorStatus)'."
    Assert ($State.mirrorAccessState -eq 'Unknown') "$Mode mode observed notification access."
    Assert ($State.canRequestMirrorAccess -eq $false) "$Mode mode made access requestable."
    Assert ($State.mirrorConsentRequested -eq $false -and $State.mirrorConsentPending -eq $false) `
        "$Mode mode recorded mirroring consent."
    Assert ($State.mirrorAccessRequests -eq 0) "$Mode mode issued a notification access request."
    Assert ($State.mirrorWrites -eq 0) "$Mode mode wrote mirrorSystemNotifications."
    Assert ($State.windowsDismissEnabled -eq $false -and $State.appOpenEnabled -eq $false) `
        "$Mode mode enabled a mirrored-record side effect."
    Assert ($State.mirroredCount -eq 0 -and $State.windowsDismissals -eq 0) `
        "$Mode mode observed a mirrored record or Windows dismissal."
    Assert ($State.mirrorSettingsActionRequired -eq $false -and $State.settingsOpenRequests -eq 0) `
        "$Mode mode offered or opened Windows notification settings."
    Assert ($State.appOpenRefusals -eq 0 -and $State.appOpenInvocations -eq 0) `
        "$Mode mode reached the app-open path."
    Assert ($State.deniedPolls -eq 0 -and -not $State.deniedPollingActive) `
        "$Mode mode polled denied access."
    Assert ($State.centerVisible -eq $State.dockLoaded) `
        "$Mode mode reported an inconsistent notification-center visibility."
    if ($Mode -eq 'Disabled') {
        Assert ($State.status -eq 'disabled') 'Disabled mode did not report disabled.'
        Assert (-not $State.enabled) 'Disabled mode enabled the service.'
        Assert (-not $State.nativeRequested) 'Disabled mode activated the native backend loader.'
        Assert (-not $State.backendLoaded) 'Disabled mode constructed NotificationServer.'
        Assert (-not $State.uiLoaded) 'Disabled mode loaded the original notification UI.'
        Assert (-not $State.dockLoaded) 'Disabled mode loaded the original notification dock.'
        Assert ($State.listCount -eq 0 -and $State.popupCount -eq 0) 'Disabled mode observed notifications.'
    } else {
        Assert ($State.enabled -eq $true) 'Local mode did not enable notifications.'
        Assert ($State.status -eq 'local') "Local mode did not settle: $($State.status) ($($State.reason))"
        Assert ($State.nativeRequested -eq $true) 'Local mode did not activate the native backend loader.'
        Assert ($State.backendLoaded -eq $true) 'Local mode did not construct NotificationServer.'
        Assert ($State.uiLoaded -eq $true) 'Local mode did not load the original notification UI.'
        Assert ($State.dockLoaded -eq $true) 'Local mode did not load the original notification dock.'
        Assert ($State.pathConfined -eq $true) 'Local mode did not report confined paths.'
        Assert ($State.historyInsideProfile -eq $true) 'History path is outside the isolated profile.'
        Assert ($State.systemNotificationAccess -eq 0) 'Local mode changed system notification access.'
        Assert ($State.ownership -eq 'unknown') 'Unexpected native ownership was invented.'
    }
}
function Read-History {
    Assert (Test-Path -LiteralPath $historyPath -PathType Leaf) 'Persisted notification history is missing.'
    Assert-PathConfined $historyPath $profile 'Notification history'
    $raw = Get-Content -LiteralPath $historyPath -Raw
    Assert ($raw.TrimStart().StartsWith('[')) 'Persisted notification history is not a list.'
    $json = @($raw | ConvertFrom-Json)
    return $json
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
$beforeLegacy = FileIdentity $legacyHistory
try {
    $fixture = & "$PSScriptRoot\Test-NotificationService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Notification fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })

    # Start from an empty history in the test-owned profile so the first local
    # run is a real arrival rather than a restored record.
    Remove-Item -LiteralPath $historyPath -Force -ErrorAction SilentlyContinue

    $screenCount = $beforeDesktop.monitors.Count
    Assert ($screenCount -gt 0) 'No measured monitor available.'

    # Disabled mode on every screen: no native server, no original UI.
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -Notifications -NotificationsMode Disabled -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
        Assert $result.passed "Notifications disabled UI failed on screen $screen."
        $records.Add([ordered]@{ kind = 'disabled'; result = $result })
        Assert ($result.notificationsSnapshots.Count -eq 2) 'Disabled smoke did not record initial and final state.'
        foreach ($snapshot in $result.notificationsSnapshots) {
            Assert-Common $snapshot.state 'Disabled'
        }
    }

    # First local run: fresh profile, one persistent local notification.
    $runA = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -Notifications -NotificationsMode Local -Smoke -ScaleFactor native -ScreenIndex 0 | ConvertFrom-Json
    Assert $runA.passed 'Local notifications persist run failed.'
    $records.Add([ordered]@{ kind = 'local-persist'; result = $runA })
    Assert ($runA.notificationsSnapshots.Count -eq 2) 'Local persist run did not record initial and final state.'
    $initialA = $runA.notificationsSnapshots[0].state
    $finalA = $runA.notificationsSnapshots[1].state
    Assert-Common $initialA 'Local'
    Assert-Common $finalA 'Local'
    Assert ($initialA.runMode -eq 'persist' -and $initialA.restoredCount -eq 0 -and $initialA.listCount -eq 0) `
        'Fresh local run did not start with an empty history.'
    Assert ($finalA.runMode -eq 'persist' -and $finalA.postedPresent -eq $true -and $finalA.postedLocal -eq $true) `
        'Local notification did not arrive through the shell server.'
    Assert ($finalA.postedPopup -eq $true) 'Local notification did not appear in the original popup list.'
    Assert ($finalA.postedActions -ge 1) 'Local notification action did not reach the original UI contract.'
    Assert ($finalA.listCount -eq 1 -and $finalA.popupCount -eq 1) 'Persist run did not retain one popped-up notification.'
    Assert ($finalA.historyContainsPosted -eq $true) 'Persist run did not keep the notification in history.'
    Assert ($finalA.localDismissals -eq 0) 'Persist run dismissed the test notification.'
    $historyA = @(Read-History)
    Assert ($historyA.Count -eq 1) 'Persisted history did not contain exactly the test notification.'
    Assert ($historyA[0].summary -eq 'Caelestia Windows local notification') 'Persisted history summary changed.'
    Assert ($historyA[0].local -eq $true) 'Persisted history lost the local marker.'
    Assert ([string]$historyA[0].recordId -ne '') 'Persisted history has no stable record id.'
    Assert ([string]$historyA[0].notificationId -ne '') 'Persisted history has no notification id.'

    # Second local run: restore in a new process, expire and dismiss one new
    # notification, then leave the restored entry intact.
    $runB = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -Notifications -NotificationsMode Local -Smoke -ScaleFactor native -ScreenIndex 0 | ConvertFrom-Json
    Assert $runB.passed 'Local notifications expire/dismiss run failed.'
    $records.Add([ordered]@{ kind = 'local-expire-dismiss'; result = $runB })
    $initialB = $runB.notificationsSnapshots[0].state
    $finalB = $runB.notificationsSnapshots[1].state
    Assert-Common $initialB 'Local'
    Assert-Common $finalB 'Local'
    Assert ($initialB.runMode -eq 'expire-dismiss' -and $initialB.restoredCount -eq 1 -and $initialB.listCount -eq 1) `
        'Restart did not restore the persisted local notification.'
    Assert ($initialB.restoredIds -contains '1') 'Restored notification id was not observed.'
    Assert ($finalB.runMode -eq 'expire-dismiss') 'Restored run did not take the expiry/dismiss path.'
    Assert ($finalB.postedPresent -eq $false) 'Expired/dismissed test notification remained in the list.'
    Assert ($finalB.listCount -eq 1 -and $finalB.popupCount -eq 0) 'Expiry/dismiss did not return to the restored list.'
    Assert ($finalB.historyContainsPosted -eq $false) 'Dismissed notification survived in the isolated history.'
    Assert ($finalB.localDismissals -ge 1) 'Local dismissal did not reach the backend.'
    Assert ($finalB.protectedDismissals -eq 0) 'A real Windows notification was dismissed.'
    $historyB = @(Read-History)
    Assert ($historyB.Count -eq 1) 'Dismissal did not leave exactly the restored notification.'
    Assert ($historyB[0].recordId -ne $finalB.postedRecordId) 'Dismissed record still matches the persisted record id.'

    # Local mode on the remaining screens proves the original UI renders the
    # restored list and the local path still works at each monitor origin.
    for ($screen = 1; $screen -lt $screenCount; $screen++) {
        $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
            -Notifications -NotificationsMode Local -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
        Assert $result.passed "Notifications local UI failed on screen $screen."
        $records.Add([ordered]@{ kind = 'local-extra-screen'; result = $result })
        $initial = $result.notificationsSnapshots[0].state
        $final = $result.notificationsSnapshots[1].state
        Assert-Common $initial 'Local'
        Assert-Common $final 'Local'
        Assert ($initial.restoredCount -eq 1) 'Extra-screen run did not restore the persisted notification.'
        Assert ($final.listCount -eq 1 -and $final.popupCount -eq 0) 'Extra-screen run did not return to the restored list.'
    }

    # The ordinary M1 bar/session profile remains available and unchanged.
    $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -CachePath $M1CachePath
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })

    # Re-run the shared service fixtures required by this slice's evidence.
    $mediaFixture = & "$PSScriptRoot\Test-MediaService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $mediaFixture.passed 'Media service fixture regression failed.'
    $records.Add([ordered]@{ kind = 'media-service-regression'; result = $mediaFixture })
    $batteryFixture = & "$PSScriptRoot\Test-BatteryService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $batteryFixture.passed 'Battery service fixture regression failed.'
    $records.Add([ordered]@{ kind = 'battery-service-regression'; result = $batteryFixture })
} catch {
    $failure = $_.ToString()
} finally {
    $afterDesktop = Get-DesktopSnapshot 'desktop-after'
    $afterLegacy = FileIdentity $legacyHistory
}
try {
    Assert ((Desktop-Identity $beforeDesktop) -eq (Desktop-Identity $afterDesktop)) 'Shell processes, work areas or taskbar state changed.'
    Assert (($beforeLegacy | ConvertTo-Json -Compress) -eq ($afterLegacy | ConvertTo-Json -Compress)) 'The ordinary user notification history changed.'
} catch {
    if ($failure) { $failure += "`n" + $_.ToString() } else { $failure = $_.ToString() }
}
$summary = [ordered]@{
    passed = -not [bool]$failure; failure = $failure
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    historyPath = $historyPath
    legacyHistory = $legacyHistory
    legacyHistoryBefore = $beforeLegacy
    legacyHistoryAfter = $afterLegacy
    measurementSources = @('Get-DesktopState.ps1', 'Test-NotificationService.ps1', 'Test-NotificationsPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
