[CmdletBinding()]
param(
    [string]$Prefix = $PSScriptRoot,
    [ValidateSet('Status', 'Rollback', 'Watch', 'CheckUpdate', 'SetChannel', 'Update')][string]$Command = 'Status',
    # A GUI request queues maintenance outside the shell's process tree.
    [switch]$Wait,
    [string]$TaskName,
    [string]$ExpectedCurrent,
    [string]$ExpectedBuild,
    [ValidateSet('development', 'preview', 'stable')][string]$Channel,
    [switch]$AcceptDevelopment,
    # Watchdog operation. Its queued maintenance task writes these phases.
    [string]$OperationId,
    # Bound for a queued rollback's queued/working phase. When the deadline
    # passes without a terminal phase, the watchdog records the failure the
    # Updates page waits for instead of leaving it working forever.
    [ValidateRange(1, 86400)][int]$PhaseTimeoutSeconds = 300
)
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
. (Join-Path $PSScriptRoot 'Caelestia-Update.ps1')
$Prefix = Resolve-CaelestiaDirectory $Prefix
if ($Command -eq 'Update' -and -not $PSBoundParameters.ContainsKey('PhaseTimeoutSeconds')) { $PhaseTimeoutSeconds = 1800 }
$trustPath = Join-Path $PSScriptRoot 'update-trust.json'
$trust = if (Test-Path -LiteralPath $trustPath -PathType Leaf) {
    Read-CaelestiaStrictJsonFile $trustPath
} else { @{ status = 'unconfigured'; rootKeys = @() } }
$publicFeed = Get-CaelestiaUpdateChannel
# Retained shells can still send the old command through the stable launcher.
# The only accepted channel is already selected, so there is nothing to store.
if ($Command -eq 'SetChannel') {
    if ($Channel -cne $publicFeed) { throw 'Caelestia now has one update feed.' }
    @{ schema = 1; channel = $publicFeed } | ConvertTo-Json -Compress
    return
}
if ($Command -in @('CheckUpdate', 'Update') -and $Channel -and $Channel -cne $publicFeed) {
    throw 'The requested update feed is not supported.'
}
if ($Command -eq 'CheckUpdate') {
    $current = Read-CaelestiaInstall (Resolve-CaelestiaRuntimePrefix $Prefix)
    Invoke-CaelestiaUpdateCheck $trust $publicFeed $current.releaseId (Get-CaelestiaUpdateStatePath) | ConvertTo-Json -Depth 10 -Compress
    return
}
if ($Command -eq 'Status') {
    $record = Read-CaelestiaInstall $Prefix
    $runtime = Resolve-CaelestiaRuntimePrefix $Prefix
    $current = Read-CaelestiaInstall $runtime
    $previous = $null
    if ($record.version -eq 2 -and $record.previous) {
        $previous = Read-CaelestiaInstall (Get-CaelestiaVersionPrefix $Prefix $record.previous)
    }
    $releaseVersion = ''
    if ($current.releaseId) {
        try { $releaseVersion = (ConvertTo-CaelestiaSemVer $current.releaseId).Version } catch { }
    }
    [ordered]@{
        schema = 1; versioned = $record.version -eq 2
        current = $(if ($current.versionId) { $current.versionId } else { 'legacy' })
        sourceRevision = $current.sourceRevision
        releaseVersion = $releaseVersion
        displayVersion = $(if ($current.displayVersion) { $current.displayVersion } else { $releaseVersion })
        channel = $publicFeed
        updatesConfigured = Test-CaelestiaTrustConfigured $trust
        previous = $(if ($previous) { $previous.versionId } else { '' })
        previousDisplayVersion = $(if ($previous.displayVersion) { $previous.displayVersion } elseif ($previous.releaseId) { $previous.releaseId } else { '' })
        previousRevision = $(if ($previous) { $previous.sourceRevision } else { '' })
        canRollback = $null -ne $previous
        # This command reads only installed state; it never checks the feed.
        automaticUpdatesAvailable = Test-CaelestiaTrustConfigured $trust
        remoteVersionChecked = $false
        latestVersion = $null
        manualReleaseUrl = 'https://kldsseeghosts.github.io/caelestia-windows/#install'
        # Compatibility field: means an automatic/authenticated channel,
        # never the existence of a public manual download.
        downloadChannelAvailable = Test-CaelestiaTrustConfigured $trust
        releasesUrl = 'https://github.com/KldsSeeGhosts/caelestia-windows/releases'
    } | ConvertTo-Json
    return
}
$installLock = Enter-CaelestiaInstallLock $Prefix
$operationFile = ''
$tracked = $false
$CaelestiaTrackedOperationId = ''
$terminalWritten = $false
$queuedTask = ''
$operationKind = if ($Command -eq 'Update') { 'update' } else { 'rollback' }
function Write-Operation([string]$Id, [string]$Phase, [string]$Step = '',
    [long]$Completed = 0, [long]$Total = 0, [string]$Unit = '') {
    Write-CaelestiaJsonAtomic $operationFile @{
        schema = 1; operationId = $Id; phase = $Phase
        kind = $operationKind
        step = $Step
        progress = @{ completed = $Completed; total = $Total; unit = $Unit }
        expectedCurrent = $(if ($ExpectedCurrent) { $ExpectedCurrent } else { $record.current })
        expectedBuild = $ExpectedBuild; channel = $Channel
        prefix = $Prefix; installId = $record.installId
        # Bound a queued request even if its watchdog never starts or retries.
        # A later request can fence the expired worker under the prefix lock.
        queuedDeadlineUtc = [DateTime]::UtcNow.AddSeconds($PhaseTimeoutSeconds + 60).ToString('o')
    }
}
function Read-Operation {
    if (-not (Test-Path -LiteralPath $operationFile -PathType Leaf)) { return $null }
    try { $state = Get-Content -LiteralPath $operationFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'The rollback operation journal is unreadable. Inspect it before requesting maintenance.' }
    if ($state.schema -ne 1 -or $state.operationId -notmatch '^[a-f0-9]{32}$' -or
        ($state.prefix -and -not (Test-CaelestiaSamePath $state.prefix $Prefix)) -or
        ($state.installId -and $state.installId -ne $record.installId)) { return $null }
    return $state
}
function Write-PolicyRefusal([string]$Id) {
    Write-Operation $Id 'failed'
    $scriptPath = (Join-Path $Prefix 'Manage-Caelestia.ps1').Replace("'", "''")
    $quotedPrefix = $Prefix.Replace("'", "''")
    $manual = "& '$scriptPath' -Prefix '$quotedPrefix' -Command $Command -Wait -ExpectedCurrent '$($record.current)'"
    if ($Command -eq 'Update') { $manual += " -ExpectedBuild '$ExpectedBuild' -Channel '$Channel'" }
    $response = @{
        schema = 1; operationId = $Id; phase = 'failed'; code = 'scheduler-policy'
        message = 'Task Scheduler blocked the request. Run this command in an unelevated PowerShell window:'
        manualCommand = $manual
    } | ConvertTo-Json -Compress
    # ASCII JSON is also UTF-8, even when the hidden host writes through an
    # OEM code page. Escape UTF-16 code units after JSON serialization so
    # backslashes, apostrophes and surrogate pairs round-trip unchanged.
    [regex]::Replace($response, '[^\x00-\x7f]', {
        param($match)
        '\u{0:x4}' -f [int][char]$match.Value
    })
}
function Get-OperationTasks([string]$Id) {
    foreach ($name in @("Caelestia-Maintenance-$Id", "Caelestia-MaintenanceWatch-$Id")) {
        foreach ($task in @(Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue)) {
            $actions = @($task.Actions)
            if ($actions.Count -eq 1 -and (Test-CaelestiaSamePath $actions[0].WorkingDirectory $Prefix) -and
                ([string]$actions[0].Arguments).IndexOf('-File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                ([string]$actions[0].Arguments).IndexOf('-Prefix "' + $Prefix + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $task }
        }
    }
}
try {
    # No manifest/profile read, directory creation, journal write or queued-task
    # setup on refusal. Direct -Wait calls never participate in UI journaling.
    if (-not $installLock) { throw 'An installation, rollback or uninstall is already in progress.' }
    if ($Command -eq 'Watch' -and $OperationId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid operation identifier.' }
    if ($Command -eq 'Watch' -and -not (Test-Path -LiteralPath (Join-Path $Prefix 'install.json'))) {
        # Uninstall may have won before this scheduled action started.
        # Never reconstruct the old profile from stale task arguments.
        Unregister-ScheduledTask -TaskName ('Caelestia-Maintenance-' + $OperationId) -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName ('Caelestia-MaintenanceWatch-' + $OperationId) -Confirm:$false -ErrorAction SilentlyContinue
        return
    }
    $record = Read-CaelestiaInstall $Prefix
    if ($Command -eq 'Watch' -or -not $Wait -or $TaskName) {
        $operationFile = Join-Path (Resolve-CaelestiaDirectory $record.profile) 'state\update-operation.json'
    }
    # A dead/busy tracked worker leaves reporting to this watchdog. Scheduler
    # retries are configured, not qualified here. A later queued request also
    # recovers expired journals, without depending on those retries.
    # No missing journal/profile is ever created by the watcher.
    if ($Command -eq 'Watch') {
        $state = Read-Operation
        if ($state -and [string]$state.operationId -eq $OperationId -and $state.phase -in @('queued', 'working')) {
            if ($state.kind -eq 'update') { $operationKind = 'update' }
            if ($state.phase -eq 'working' -and $state.installId -ceq $record.installId -and
                $state.handoff.phase -eq 'stopping' -and $state.handoff.wasRunning -eq $true -and
                $state.handoff.sessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId) {
                try {
                    if (-not @(Get-CaelestiaProcesses $Prefix).Count -and -not @(Get-CaelestiaSupervisors $record.profile).Count) {
                        $committed = Resolve-CaelestiaRuntimePrefix $Prefix
                        Start-CaelestiaDetached $Prefix -LegacyReady -PreparedSchemeRuntime -RuntimePrefix $committed
                    }
                } catch { Write-Warning 'Could not restart the committed Caelestia version. Start Caelestia from the Start menu.' }
            }
            Write-Operation $OperationId 'failed'
        }
        Unregister-ScheduledTask -TaskName ('Caelestia-MaintenanceWatch-' + $OperationId) -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName ('Caelestia-Maintenance-' + $OperationId) -Confirm:$false -ErrorAction SilentlyContinue
        return
    }
    if ($ExpectedCurrent) { Assert-CaelestiaVersionId $ExpectedCurrent }
    if ($Command -eq 'Update') {
        if (-not $ExpectedCurrent -or -not (Test-CaelestiaPublishedVersion $ExpectedBuild) -or -not $Channel) {
            throw 'An update requires exact current, build and channel identities.'
        }
        if (-not (Test-CaelestiaTrustConfigured $trust)) { throw 'Updates are not configured.' }
    }
    if (-not $Wait) {
        if ($record.version -ne 2 -or ($Command -eq 'Rollback' -and -not $record.previous)) { throw 'No previous version is retained.' }
        if ($ExpectedCurrent -and $record.current -ne $ExpectedCurrent) { throw 'The selected version changed. Refresh before requesting rollback.' }
        $pending = Read-Operation
        if ($pending -and $pending.phase -in @('queued', 'working')) {
            $pendingTasks = @(Get-OperationTasks ([string]$pending.operationId))
            $queuedDeadline = [DateTime]::MinValue
            # ConvertFrom-Json already yields a DateTime for an ISO timestamp
            # under PowerShell 7; 5.1 leaves the raw string for TryParseExact.
            if ($pending.queuedDeadlineUtc -is [DateTime]) {
                $queuedDeadline = $pending.queuedDeadlineUtc
                $hasDeadline = $true
            } else {
                $hasDeadline = [DateTime]::TryParseExact([string]$pending.queuedDeadlineUtc, 'o',
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$queuedDeadline)
            }
            if ($pending.phase -eq 'queued' -and $pendingTasks.Count -gt 0 -and $hasDeadline -and
                $queuedDeadline.Kind -eq [DateTimeKind]::Utc -and $queuedDeadline -gt [DateTime]::UtcNow -and
                $queuedDeadline -le [DateTime]::UtcNow.AddSeconds(86460)) {
                throw 'A rollback request is already in progress.'
            }
            # Holding the prefix lock proves no tracked worker is inside its
            # transaction. Fence a dead working, orphaned/expired queued or
            # legacy unbounded request before another worker can enter.
            Write-Operation ([string]$pending.operationId) 'failed'
            foreach ($task in $pendingTasks) {
                Stop-ScheduledTask -TaskPath '\' -TaskName $task.TaskName -ErrorAction Stop
                Unregister-ScheduledTask -TaskPath '\' -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
            }
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($operationFile)) | Out-Null
        $operationId = [guid]::NewGuid().ToString('N')
        $name = 'Caelestia-Maintenance-' + $operationId
        $action = New-ScheduledTaskAction -Execute (Get-CaelestiaPowerShellPath) -WorkingDirectory $Prefix `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') +
                '" -Prefix "' + $Prefix + '" -Command ' + $Command + ' -Wait -TaskName "' + $name +
                '" -ExpectedCurrent "' + $record.current + '" -PhaseTimeoutSeconds ' + $PhaseTimeoutSeconds +
                $(if ($Command -eq 'Update') { ' -ExpectedBuild "' + $ExpectedBuild + '" -Channel ' + $Channel } else { '' }))
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        # The worker's existing hard execution bound releases a hung worker's
        # lock. One-minute scheduler retries are configured but not assumed
        # to run: stale-request recovery above provides a separate path.
        # Indefinitely held unrelated locks still need a consumer deadline.
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::FromSeconds($PhaseTimeoutSeconds + 60))
        $watchName = 'Caelestia-MaintenanceWatch-' + $operationId
        try {
            # Reporting must be registered successfully before accepting a
            # queued operation. Do not silently queue without its watchdog.
            $watchAction = New-ScheduledTaskAction -Execute (Get-CaelestiaPowerShellPath) -WorkingDirectory $Prefix `
                -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') +
                    '" -Prefix "' + $Prefix + '" -Command Watch -OperationId "' + $operationId + '" -TaskName "' + $watchName + '"')
            $watchTrigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddSeconds($PhaseTimeoutSeconds))
            $watchSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromSeconds(180)) `
                -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
            Register-ScheduledTask -TaskName $watchName -Action $watchAction -Trigger $watchTrigger -Principal $principal -Settings $watchSettings -ErrorAction Stop | Out-Null
            Write-Operation $operationId 'queued'
            Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
            $queuedTask = $name
        } catch {
            $registrationError = $_
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $watchName -Confirm:$false -ErrorAction SilentlyContinue
            if (Test-CaelestiaTaskSchedulerAccessDenied $registrationError) {
                Write-PolicyRefusal $operationId
                return
            }
            Write-Operation $operationId 'failed'
            throw
        }
    } else {
        if ($TaskName) {
            if ($TaskName -notmatch '^Caelestia-Maintenance-([a-f0-9]{32})$') { throw 'Invalid maintenance task name.' }
            $operationId = $Matches[1]
            $state = Read-Operation
            if (-not $state -or $state.operationId -ne $operationId -or $state.phase -ne 'queued') {
                throw 'The queued rollback no longer owns this operation.'
            }
            if (($state.kind -and $state.kind -cne $operationKind) -or
                ($state.expectedCurrent -and $state.expectedCurrent -cne $ExpectedCurrent) -or
                ($Command -eq 'Update' -and ($state.expectedBuild -cne $ExpectedBuild -or $state.channel -cne $Channel))) {
                throw 'The worker arguments do not match the accepted operation.'
            }
            $tracked = $true
        }
        try {
            if ($record.version -ne 2 -or ($Command -eq 'Rollback' -and -not $record.previous)) { throw 'No previous version is retained.' }
            if ($ExpectedCurrent -and $record.current -ne $ExpectedCurrent) { throw 'The selected version changed before rollback could start.' }
            if ($tracked) {
                Write-Operation $operationId 'working'
                $CaelestiaTrackedOperationId = $operationId
            }
            if ($Command -eq 'Update') {
                Invoke-CaelestiaUpdateInstall $Prefix $ExpectedCurrent $ExpectedBuild $Channel $trust {
                    param($step, [long]$completed = 0, [long]$total = 0, [string]$unit = '')
                    if ($tracked) { Write-Operation $operationId 'working' $step $completed $total $unit }
                }
            } else { Switch-CaelestiaVersion $Prefix $record.previous -Restart }
            if ($tracked) { Write-Operation $operationId 'complete'; $terminalWritten = $true }
        } catch {
            if ($tracked) { Write-Operation $operationId 'failed'; $terminalWritten = $true }
            throw
        } finally {
            if ($tracked) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
            # A terminal write succeeded. A busy/unvalidated worker never gets
            # here and must leave reporting to its still-registered watchdog.
            if ($terminalWritten) {
                Unregister-ScheduledTask -TaskName ('Caelestia-MaintenanceWatch-' + $operationId) -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }
} finally {
    Exit-CaelestiaInstallLock $installLock
}
if ($queuedTask) {
    # The worker takes the same lock. Starting it only after release avoids a
    # queue-vs-own-worker race. On explicit policy denial no worker started;
    # fence this request in the journal and remove both registrations.
    try { Start-ScheduledTask -TaskName $queuedTask -ErrorAction Stop }
    catch {
        if (-not (Test-CaelestiaTaskSchedulerAccessDenied $_)) { throw }
        $settleLock = Enter-CaelestiaInstallLock $Prefix
        if (-not $settleLock) { throw } # A concurrent holder may own the request.
        try {
            $record = Read-CaelestiaInstall $Prefix
            $state = Read-Operation
            if (-not $state -or $state.operationId -cne $operationId -or $state.phase -cne 'queued') { throw }
            Write-PolicyRefusal $operationId
            Unregister-ScheduledTask -TaskName $queuedTask -Confirm:$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName ('Caelestia-MaintenanceWatch-' + $operationId) -Confirm:$false -ErrorAction SilentlyContinue
        } finally { Exit-CaelestiaInstallLock $settleLock }
        return
    }
    @{ operationId = $operationId } | ConvertTo-Json -Compress
}
