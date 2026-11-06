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
$record = Read-CaelestiaInstall $Prefix
if ($Command -eq 'Status') {
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
$operationFile = Join-Path (Resolve-CaelestiaDirectory $record.profile) 'state\update-operation.json'
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($operationFile)) | Out-Null
function Write-Operation([string]$Id, [string]$Phase) {
    Write-CaelestiaJsonAtomic $operationFile @{ schema = 1; operationId = $Id; phase = $Phase }
}
# The deadline watchdog. A task that dies after 'queued' or 'working' cannot
# write its own failure, so this separate task records it when the bound
# expires. It only acts on its own operation: a record that already reached a
# terminal phase, or belongs to another request, is left untouched.
if ($Command -eq 'Watch') {
    if ($OperationId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid operation identifier.' }
    try {
        $state = Get-Content -LiteralPath $operationFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($state.schema -eq 1 -and [string]$state.operationId -eq $OperationId -and $state.phase -in @('queued', 'working')) {
            Write-Operation $OperationId 'failed'
        }
    } catch { }
    if ($TaskName) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    # The bound expired: stop tracking a worker that never reported a terminal
    # phase. Unregistering also releases its task slot if the process died.
    Unregister-ScheduledTask -TaskName ('Caelestia-Maintenance-' + $OperationId) -Confirm:$false -ErrorAction SilentlyContinue
    return
}
if ($ExpectedCurrent) {
    Assert-CaelestiaVersionId $ExpectedCurrent
}
if (-not $Wait) {
    if ($record.version -ne 2 -or -not $record.previous) { throw 'No previous version is retained.' }
    if ($ExpectedCurrent -and $record.current -ne $ExpectedCurrent) { throw 'The selected version changed. Refresh before requesting rollback.' }
    $operationId = [guid]::NewGuid().ToString('N')
    $name = 'Caelestia-Maintenance-' + $operationId
    $action = New-ScheduledTaskAction -Execute (Get-WindowsPowerShellPath) -WorkingDirectory $Prefix `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') +
            '" -Prefix "' + $Prefix + '" -Command Rollback -Wait -TaskName "' + $name +
            '" -ExpectedCurrent "' + $record.current + '"')
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    # A hung task is force-stopped a minute after its watchdog fires, so the
    # install lock cannot be held for ever either.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::FromSeconds($PhaseTimeoutSeconds + 60))
    $watchName = 'Caelestia-MaintenanceWatch-' + $operationId
    try {
        # The watchdog is scheduled before anything can stall: if this process
        # dies after writing 'queued' or the worker dies before 'working', the
        # phase is still bounded. It watches a record that does not exist yet
        # when the request itself never queues, which is harmless.
        try {
            $watchAction = New-ScheduledTaskAction -Execute (Get-WindowsPowerShellPath) -WorkingDirectory $Prefix `
                -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Prefix 'Manage-Caelestia.ps1') +
                    '" -Prefix "' + $Prefix + '" -Command Watch -OperationId "' + $operationId + '" -TaskName "' + $watchName + '"')
            $watchTrigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddSeconds($PhaseTimeoutSeconds))
            $watchSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $watchName -Action $watchAction -Trigger $watchTrigger -Principal $principal -Settings $watchSettings -ErrorAction Stop | Out-Null
        } catch {
            # The rollback is still the right thing to do; only its failure
            # reporting is degraded, which must not block it.
            Write-Warning "The rollback watchdog could not be scheduled: $($_.Exception.Message)"
        }
        Write-Operation $operationId 'queued'
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
    }
    catch {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $watchName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Operation $operationId 'failed'
        throw
    }
    @{ operationId = $operationId } | ConvertTo-Json -Compress
    return
}
$installLock = Enter-CaelestiaInstallLock $Prefix
$operationId = if ($TaskName -match '^Caelestia-Maintenance-([a-f0-9]{32})$') { $Matches[1] } else { [guid]::NewGuid().ToString('N') }
$watchTask = if ($TaskName -match '^Caelestia-Maintenance-[a-f0-9]{32}$') { 'Caelestia-MaintenanceWatch-' + $operationId } else { '' }
try {
    if (-not $installLock) { throw 'An installation or rollback is already in progress.' }
    # Re-read under the same lock as Install-Caelestia.
    $record = Read-CaelestiaInstall $Prefix
    if ($record.version -ne 2 -or -not $record.previous) { throw 'No previous version is retained.' }
    if ($ExpectedCurrent -and $record.current -ne $ExpectedCurrent) { throw 'The selected version changed before rollback could start.' }
    Write-Operation $operationId 'working'
    Switch-CaelestiaVersion $Prefix $record.previous -Restart
    Write-Operation $operationId 'complete'
} catch {
    Write-Operation $operationId 'failed'
    throw
} finally {
    Exit-CaelestiaInstallLock $installLock
    if ($TaskName -match '^Caelestia-Maintenance-[a-f0-9]{32}$') {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    # A completed rollback needs no watchdog; one whose task died was left
    # registered on purpose so it can record the failure.
    if ($watchTask) {
        Unregister-ScheduledTask -TaskName $watchTask -Confirm:$false -ErrorAction SilentlyContinue
    }
}
