[CmdletBinding()]
param(
    [string]$Prefix = $PSScriptRoot,
    [ValidateSet('Status', 'Rollback')][string]$Command = 'Status',
    # A GUI request queues maintenance outside the shell's process tree.
    [switch]$Wait,
    [string]$TaskName,
    [string]$ExpectedCurrent
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
        # No release assets/feed are published yet. Never equate a GitHub
        # source commit with a downloadable, authenticated Windows update.
        downloadChannelAvailable = $false
        releasesUrl = 'https://github.com/KldsSeeGhosts/caelestia-windows/releases'
    } | ConvertTo-Json
    return
}
if ($ExpectedCurrent) {
    Assert-CaelestiaVersionId $ExpectedCurrent
}
$operationFile = Join-Path (Resolve-CaelestiaDirectory $record.profile) 'state\update-operation.json'
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($operationFile)) | Out-Null
function Write-Operation([string]$Id, [string]$Phase) {
    Write-CaelestiaJsonAtomic $operationFile @{ schema = 1; operationId = $Id; phase = $Phase }
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
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    try {
        Write-Operation $operationId 'queued'
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
    }
    catch {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        Write-Operation $operationId 'failed'
        throw
    }
    @{ operationId = $operationId } | ConvertTo-Json -Compress
    return
}
$mutex = New-CaelestiaInstallMutex $Prefix
$locked = $false
$operationId = if ($TaskName -match '^Caelestia-Maintenance-([a-f0-9]{32})$') { $Matches[1] } else { [guid]::NewGuid().ToString('N') }
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'An installation or rollback is already in progress.' }
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
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    if ($TaskName -match '^Caelestia-Maintenance-[a-f0-9]{32}$') {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
