[CmdletBinding()]
param(
    [string]$Prefix = $PSScriptRoot,
    [ValidateSet('Status', 'Rollback', 'Watch')][string]$Command = 'Status',
    # A GUI request queues maintenance outside the shell's process tree.
    [switch]$Wait,
    [string]$TaskName,
    [string]$ExpectedCurrent,
    # Watchdog operation. Its queued maintenance task writes these phases.
    [string]$OperationId,
    # Bound for a queued rollback's queued/working phase. When the deadline
    # passes without a terminal phase, the watchdog records the failure the
    # Updates page waits for instead of leaving it working forever.
    [ValidateRange(1, 86400)][int]$PhaseTimeoutSeconds = 300
)
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$Prefix = Resolve-CaelestiaDirectory $Prefix
if ($Command -eq 'Status') {
    $record = Read-CaelestiaInstall $Prefix
    $runtime = Resolve-CaelestiaRuntimePrefix $Prefix
    $current = Read-CaelestiaInstall $runtime
    $previous = $null
    if ($record.version -eq 2 -and $record.previous) {
        $previous = Read-CaelestiaInstall (Get-CaelestiaVersionPrefix $Prefix $record.previous)
    }
    [ordered]@{
        schema = 1; versioned = $record.version -eq 2
        current = $(if ($current.versionId) { $current.versionId } else { 'legacy' })
        sourceRevision = $current.sourceRevision
        previous = $(if ($previous) { $previous.versionId } else { '' })
        previousRevision = $(if ($previous) { $previous.sourceRevision } else { '' })
        canRollback = $null -ne $previous
        # Public previews are manually downloadable. This command reads only
        # installed state; it neither checks remote versions nor downloads.
        automaticUpdatesAvailable = $false
        remoteVersionChecked = $false
        latestVersion = $null
        manualReleaseUrl = 'https://github.com/KldsSeeGhosts/caelestia-windows/releases'
        # Compatibility field: means an automatic/authenticated channel,
        # never the existence of a public manual download.
        downloadChannelAvailable = $false
        releasesUrl = 'https://github.com/KldsSeeGhosts/caelestia-windows/releases'
    } | ConvertTo-Json
    return
}
$installLock = Enter-CaelestiaInstallLock $Prefix
$operationFile = ''
$tracked = $false
$terminalWritten = $false
$queuedTask = ''
function Write-Operation([string]$Id, [string]$Phase) {
    Write-CaelestiaJsonAtomic $operationFile @{
        schema = 1; operationId = $Id; phase = $Phase
        prefix = $Prefix; installId = $record.installId
    }
}
function Read-Operation {
    if (-not (Test-Path -LiteralPath $operationFile -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $operationFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.schema -ne 1 -or $state.operationId -notmatch '^[a-f0-9]{32}$' -or
        ($state.prefix -and $state.prefix -ne $Prefix) -or
        ($state.installId -and $state.installId -ne $record.installId)) { return $null }
    return $state
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
    # A dead/busy tracked worker leaves reporting to this watchdog. Lock
    # refusal throws without unregistering it, so Task Scheduler can retry.
    # No missing journal/profile is ever created by the watcher.
    if ($Command -eq 'Watch') {
        $state = Read-Operation
        if ($state -and [string]$state.operationId -eq $OperationId -and $state.phase -in @('queued', 'working')) {
            Write-Operation $OperationId 'failed'
        }
        Unregister-ScheduledTask -TaskName ('Caelestia-MaintenanceWatch-' + $OperationId) -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName ('Caelestia-Maintenance-' + $OperationId) -Confirm:$false -ErrorAction SilentlyContinue
        return
    }
    if ($ExpectedCurrent) { Assert-CaelestiaVersionId $ExpectedCurrent }
    if (-not $Wait) {
        if ($record.version -ne 2 -or -not $record.previous) { throw 'No previous version is retained.' }
        if ($ExpectedCurrent -and $record.current -ne $ExpectedCurrent) { throw 'The selected version changed. Refresh before requesting rollback.' }
        $pending = Read-Operation
        if ($pending -and $pending.phase -in @('queued', 'working')) { throw 'A rollback request is already in progress.' }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($operationFile)) | Out-Null
        $operationId = [guid]::NewGuid().ToString('N')
        $name = 'Caelestia-Maintenance-' + $operationId
        $action = New-ScheduledTaskAction -Execute (Get-WindowsPowerShellPath) -WorkingDirectory $Prefix `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') +
                '" -Prefix "' + $Prefix + '" -Command Rollback -Wait -TaskName "' + $name +
                '" -ExpectedCurrent "' + $record.current + '"')
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        # The worker's existing hard execution bound releases a hung worker's
        # lock. A busy watcher retries at one-minute intervals, without writing
        # through another transaction. Indefinitely held unrelated locks still
        # need a separate consumer timeout to guarantee a UI deadline.
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::FromSeconds($PhaseTimeoutSeconds + 60))
        $watchName = 'Caelestia-MaintenanceWatch-' + $operationId
        try {
            # Reporting must be registered successfully before accepting a
            # queued operation. Do not silently queue without its watchdog.
            $watchAction = New-ScheduledTaskAction -Execute (Get-WindowsPowerShellPath) -WorkingDirectory $Prefix `
                -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') +
                    '" -Prefix "' + $Prefix + '" -Command Watch -OperationId "' + $operationId + '" -TaskName "' + $watchName + '"')
            $watchTrigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddSeconds($PhaseTimeoutSeconds))
            $watchSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromSeconds(30)) `
                -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
            Register-ScheduledTask -TaskName $watchName -Action $watchAction -Trigger $watchTrigger -Principal $principal -Settings $watchSettings -ErrorAction Stop | Out-Null
            Write-Operation $operationId 'queued'
            Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
            $queuedTask = $name
        } catch {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $watchName -Confirm:$false -ErrorAction SilentlyContinue
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
            $tracked = $true
        }
        try {
            if ($record.version -ne 2 -or -not $record.previous) { throw 'No previous version is retained.' }
            if ($ExpectedCurrent -and $record.current -ne $ExpectedCurrent) { throw 'The selected version changed before rollback could start.' }
            if ($tracked) { Write-Operation $operationId 'working' }
            Switch-CaelestiaVersion $Prefix $record.previous -Restart
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
    # queue-vs-own-worker race. If start fails, the retained watchdog owns the
    # bounded failure report; the request process also exits nonzero to the UI.
    Start-ScheduledTask -TaskName $queuedTask -ErrorAction Stop
    @{ operationId = $operationId } | ConvertTo-Json -Compress
}
