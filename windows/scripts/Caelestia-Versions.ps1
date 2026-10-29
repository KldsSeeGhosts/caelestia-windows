# Versioned payloads are ordinary directories, never junctions/symlinks.
# Only the small root manifest and launch entrypoints change during activation.
function Assert-CaelestiaVersionId([string]$Id) {
    if ($Id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$' -or $Id -in @('.', '..')) {
        throw 'Invalid Caelestia version identifier.'
    }
}

function Get-CaelestiaVersionPrefix([string]$Prefix, [string]$Id) {
    Assert-CaelestiaVersionId $Id
    $runtime = Resolve-CaelestiaDirectory (Join-Path $Prefix "versions\$Id")
    $record = Read-CaelestiaInstall $runtime
    if ($record.version -ne 1 -or $record.installRoot -ne $Prefix -or $record.versionId -ne $Id) {
        throw 'Version payload does not belong to this installation.'
    }
    if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) {
        $owner = Read-CaelestiaInstall $Prefix
        if ($owner.profile -ne $record.profile -or $owner.installId -ne $record.installId) {
            throw 'Version payload has a different profile or installation owner.'
        }
    }
    return $runtime
}

function Resolve-CaelestiaRuntimePrefix([string]$Prefix, [switch]$Running) {
    $manifest = Join-Path $Prefix 'install.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return $Prefix }
    $record = Read-CaelestiaInstall $Prefix
    if ($record.version -eq 1) { return $Prefix }
    if ($Running) {
        $processes = @(Get-CaelestiaProcesses $Prefix)
        $paths = @($processes | ForEach-Object { [IO.Path]::GetDirectoryName($_.Path) } | Select-Object -Unique)
        if ($paths.Count -gt 1) { throw 'Multiple versions are running; refusing an ambiguous command.' }
        if ($paths.Count -eq 1) {
            $id = Split-Path -Leaf $paths[0]
            return Get-CaelestiaVersionPrefix $Prefix $id
        }
    }
    return Get-CaelestiaVersionPrefix $Prefix ([string]$record.current)
}

function Write-CaelestiaJsonAtomic([string]$Path, $Value) {
    $null = Resolve-CaelestiaDirectory ([IO.Path]::GetDirectoryName($Path))
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Refusing to replace a linked manifest.'
    }
    $temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        for ($attempt = 0; ; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($temporary, $Path) }
                break
            } catch [IO.IOException] {
                if ($attempt -ge 4) { throw }
                Start-Sleep -Milliseconds (25 -shl $attempt)
            }
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function New-CaelestiaRootRecord([string]$Prefix, $RuntimeRecord, [string]$Previous = '') {
    return [ordered]@{
        product = 'caelestia-windows'; version = 2; prefix = $Prefix
        profile = $RuntimeRecord.profile; installId = $RuntimeRecord.installId
        current = $RuntimeRecord.versionId; previous = $Previous
        sourceRevision = $RuntimeRecord.sourceRevision
        executableSha256 = $RuntimeRecord.executableSha256
    }
}

function Publish-CaelestiaPayload([string]$Prefix, [string]$Payload, [string]$Id) {
    Assert-CaelestiaVersionId $Id
    $versionRoot = Resolve-CaelestiaDirectory (Join-Path $Prefix 'versions')
    [IO.Directory]::CreateDirectory($versionRoot) | Out-Null
    $target = Join-Path $versionRoot $Id
    if (Test-Path -LiteralPath $target) { throw 'A published version is immutable; choose a new version identifier.' }
    $record = Get-Content -LiteralPath (Join-Path $Payload 'install.json') -Raw | ConvertFrom-Json
    $record.prefix = $target
    $record | Add-Member -NotePropertyName installRoot -NotePropertyValue $Prefix -Force
    $record | Add-Member -NotePropertyName versionId -NotePropertyValue $Id -Force
    Write-CaelestiaJsonAtomic (Join-Path $Payload 'install.json') $record
    [IO.Directory]::Move($Payload, $target)
    return $target
}

function Copy-CaelestiaRootEntries([string]$Prefix, [string]$Runtime) {
    # Same-directory replace avoids partially readable launcher scripts.
    foreach ($pair in @(
        @('Start-CaelestiaEntry.ps1', 'Start-Caelestia.ps1'),
        @('Uninstall-Caelestia.ps1', 'Uninstall-Caelestia.ps1'),
        @('Manage-Caelestia.ps1', 'Manage-Caelestia.ps1'),
        @('Caelestia-InstallCommon.ps1', 'Caelestia-InstallCommon.ps1'),
        @('Caelestia-Versions.ps1', 'Caelestia-Versions.ps1')
    )) {
        $target = Join-Path $Prefix $pair[1]
        if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to replace a linked launch entry.'
        }
        $temporary = $target + '.tmp-' + [guid]::NewGuid().ToString('N')
        try {
            [IO.File]::Copy((Join-Path $Runtime $pair[0]), $temporary)
            if ([IO.File]::Exists($target)) { [IO.File]::Replace($temporary, $target, [System.Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($temporary, $target) }
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
}

function Install-CaelestiaVersion([string]$Prefix, [string]$Payload, [switch]$Restart) {
    $old = if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) { Read-CaelestiaInstall $Prefix } else { $null }
    $legacy = $old -and $old.version -eq 1
    $previous = if ($old -and -not $legacy) { [string]$old.current } else { '' }
    $candidate = Get-Content -LiteralPath (Join-Path $Payload 'install.json') -Raw | ConvertFrom-Json
    if ($candidate.product -ne 'caelestia-windows' -or $candidate.version -ne 1 -or
        ($old -and ($old.profile -ne $candidate.profile -or $old.installId -ne $candidate.installId))) {
        throw 'Prepared payload does not match this installation and profile.'
    }
    $revision = if ($candidate.sourceRevision -match '^[a-f0-9]{8,40}$') { $candidate.sourceRevision.Substring(0, 8) } else { 'local' }
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + $revision + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $runtime = Publish-CaelestiaPayload $Prefix $Payload $id
    $newRecord = Read-CaelestiaInstall $runtime
    $launchTask = $null
    $stopped = $false
    $activated = $false
    try {
        # Capture a legacy rollback payload while its executable is still live.
        # Never recurse into versions/, where both source and destination live.
        if ($legacy) {
            $previous = 'legacy-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
            $legacyPath = Join-Path $Prefix "versions\$previous"
            & robocopy.exe $Prefix $legacyPath /E /XD (Join-Path $Prefix 'versions') /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw 'Legacy migration backup failed; the live installation was not changed.' }
            $global:LASTEXITCODE = 0
            $legacyRecord = $old.PSObject.Copy()
            $legacyRecord.prefix = $legacyPath
            $legacyRecord | Add-Member -NotePropertyName installRoot -NotePropertyValue $Prefix -Force
            $legacyRecord | Add-Member -NotePropertyName versionId -NotePropertyValue $previous -Force
            Write-CaelestiaJsonAtomic (Join-Path $legacyPath 'install.json') $legacyRecord
        }
        if ($Restart) { $launchTask = New-CaelestiaLaunchTask $Prefix }
        Write-Host "Prepared version $id; beginning activation."
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if ($Restart -and $old) {
            $stopped = $true
            & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null
        }
        if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $newRecord.profile).Count) {
            throw 'The installation is still running; the new version was retained but not activated.'
        }
        Copy-CaelestiaRootEntries $Prefix $runtime
        Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') (New-CaelestiaRootRecord $Prefix $newRecord $previous)
        $activated = $true
        if ($Restart) {
            Start-CaelestiaDetached $Prefix -TaskName $launchTask
            Write-Host ('Caelestia ready; version activation {0:N2}s.' -f $clock.Elapsed.TotalSeconds)
        }
        return $runtime
    } catch {
        $failure = $_
        if ($previous -and ($activated -or $stopped)) {
            if (-not $activated -and (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $newRecord.profile).Count)) {
                # Quit failed before activation; the old selector/files remain
                # authoritative. Never redirect a still-running legacy shell.
                throw $failure
            }
            if ($activated) {
                & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null
                if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $newRecord.profile).Count) {
                    throw "Activation failed and replacement is still running; versions retained at $Prefix\versions."
                }
            }
            $priorPath = Get-CaelestiaVersionPrefix $Prefix $previous
            $priorRecord = Read-CaelestiaInstall $priorPath
            # Root launch entries are the new backward-compatible router even
            # when rolling back to a legacy payload without its own router.
            Copy-CaelestiaRootEntries $Prefix $runtime
            $earlier = if ($old.version -eq 2) { [string]$old.previous } else { '' }
            Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') (New-CaelestiaRootRecord $Prefix $priorRecord $earlier)
            if ($Restart) { Start-CaelestiaDetached $Prefix -LegacyReady }
            Write-Warning 'Activation failed; the previous version was selected again.'
        }
        throw $failure
    } finally {
        if ($launchTask) { Unregister-ScheduledTask -TaskName $launchTask -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Switch-CaelestiaVersion([string]$Prefix, [string]$Id, [switch]$Restart) {
    $old = Read-CaelestiaInstall $Prefix
    if ($old.version -ne 2) { throw 'This legacy install has no retained versions. Install an update first.' }
    if ($Id -eq $old.current) { throw 'That version is already selected.' }
    $runtime = Get-CaelestiaVersionPrefix $Prefix $Id
    $record = Read-CaelestiaInstall $runtime
    if ((Get-FileHash -LiteralPath (Join-Path $runtime 'qs.exe')).Hash -ne $record.executableSha256) {
        throw 'Retained executable checksum mismatch.'
    }
    $launchTask = $null
    $activated = $false
    try {
        if ($Restart) {
            $launchTask = New-CaelestiaLaunchTask $Prefix
            & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null
        }
        if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $old.profile).Count) {
            throw 'Quit this installation before switching versions, or request a restart.'
        }
        Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') (New-CaelestiaRootRecord $Prefix $record $old.current)
        $activated = $true
        if ($Restart) { Start-CaelestiaDetached $Prefix -LegacyReady -TaskName $launchTask }
    } catch {
        $failure = $_
        if ($activated) {
            & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null
            if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $old.profile).Count) {
                throw 'Version switch failed and the replacement has not exited; selector was not changed again.'
            }
            Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') $old
            if ($Restart) { Start-CaelestiaDetached $Prefix -LegacyReady }
        } elseif ($Restart -and -not @(Get-CaelestiaProcesses $Prefix).Count -and -not @(Get-CaelestiaSupervisors $old.profile).Count) {
            Start-CaelestiaDetached $Prefix -LegacyReady
        }
        throw $failure
    } finally {
        if ($launchTask) { Unregister-ScheduledTask -TaskName $launchTask -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Remove-CaelestiaRetiredVersions([string]$Prefix) {
    $record = Read-CaelestiaInstall $Prefix
    if ($record.version -ne 2) { return }
    $running = @(Get-CaelestiaProcesses $Prefix | ForEach-Object { [IO.Path]::GetDirectoryName($_.Path) })
    foreach ($directory in Get-ChildItem -LiteralPath (Join-Path $Prefix 'versions') -Directory) {
        if ($directory.Name -in @($record.current, $record.previous) -or $directory.FullName -in $running) { continue }
        try {
            # Ownership, exact child path and link refusal are checked before
            # every recursive removal. Unknown directories are never adopted.
            $retired = Get-CaelestiaVersionPrefix $Prefix $directory.Name
            Assert-CaelestiaNoReparsePoints $retired
            Remove-Item -LiteralPath $retired -Recurse -Force
        } catch {
            # An app may still hold an old working directory or DLL. Cleanup
            # must not roll back a healthy update; retry on the next install.
            Write-Warning 'Kept a retired version; cleanup could not safely complete.'
        }
    }
}
