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
    $record = Get-Content -LiteralPath (Join-Path $Payload 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
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
    # Old retained payloads may predate Nexus. Switch never calls this helper,
    # so rolling back retains the newest self-sufficient root router.
    foreach ($name in @('Caelestia-SemVer.ps1', 'Caelestia-UpdateTrust.ps1', 'Caelestia-Update.ps1',
        'Caelestia-UpdateSecurity.cs', 'version.json', 'update-trust.json')) {
        $source = Join-Path $Runtime $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $target = Join-Path $Prefix $name
        $null = Resolve-CaelestiaDirectory $Prefix
        if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to replace a linked update entry.'
        }
        $temporary = $target + '.tmp-' + [guid]::NewGuid().ToString('N')
        try {
            [IO.File]::Copy($source, $temporary)
            if ([IO.File]::Exists($target)) { [IO.File]::Replace($temporary, $target, [System.Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($temporary, $target) }
        } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
}

# A retained payload a later start can actually use: its record belongs to this
# installation and its executable is the one that record describes. Reads files
# only; it starts and probes nothing.
function Test-CaelestiaVersionPayload([string]$Prefix, [string]$Id) {
    try {
        $runtime = Get-CaelestiaVersionPrefix $Prefix $Id
        $record = Read-CaelestiaInstall $runtime
        $executable = Join-Path $runtime 'qs.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return $false }
        if ($record.executableSha256 -and
            (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ne [string]$record.executableSha256) { return $false }
        return $true
    } catch {
        return $false
    }
}

# Newest retained payload that still exists, for a later start when the
# configured fallback is unusable. Excluded ids are skipped: the version whose
# activation just failed is not a fallback. Selection starts nothing, because
# whether a payload runs is only known from its next start.
function Select-CaelestiaExistingVersion([string]$Prefix, [string[]]$Exclude = @()) {
    $versions = Join-Path $Prefix 'versions'
    if (-not (Test-Path -LiteralPath $versions -PathType Container)) { return '' }
    foreach ($directory in @(Get-ChildItem -LiteralPath $versions -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        if ($Exclude -contains $directory.Name) { continue }
        if (Test-CaelestiaVersionPayload $Prefix $directory.Name) { return $directory.Name }
    }
    return ''
}

function Install-CaelestiaVersion([string]$Prefix, [string]$Payload, [switch]$Restart) {
    $old = if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) { Read-CaelestiaInstall $Prefix } else { $null }
    if ($old -and $old.installRoot -and $old.installRoot -ne $Prefix) {
        throw 'Do not install into an immutable version directory. Use its stable installRoot.'
    }
    $legacy = $old -and $old.version -eq 1
    $previous = if ($old -and -not $legacy) { [string]$old.current } else { '' }
    $candidate = Get-Content -LiteralPath (Join-Path $Payload 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
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
        if ($Restart) { $launchTask = New-CaelestiaLaunchTask $Prefix -PreparedSchemeRuntime }
        # Pick and verify this version's scheme generation while the old shell
        # still serves the desktop, so a slow or hung check is not an outage.
        $verifiedScheme = Select-CaelestiaSchemeGeneration $newRecord.profile (Get-CaelestiaSchemeRevision $runtime) $runtime
        # Also decide the fallback now: once the shell stops, nothing may probe.
        $restoreScheme = $null
        if ($previous) {
            try { $restoreScheme = Select-CaelestiaRestoreScheme $newRecord.profile (Get-CaelestiaVersionPrefix $Prefix $previous) $verifiedScheme } catch { }
        }
        Write-Host "Prepared version $id; beginning activation."
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if ($Restart -and $old) {
            $stopped = $true
            & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null
        }
        if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $newRecord.profile).Count) {
            throw 'The installation is still running; the new version was retained but not activated.'
        }
        Stop-CaelestiaHosts $Prefix
        Copy-CaelestiaRootEntries $Prefix $runtime
        Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') (New-CaelestiaRootRecord $Prefix $newRecord $previous)
        # Point runtime.json at the generation verified above before the
        # readiness clock starts. If none was found, activation starts fixed.
        $null = Set-CaelestiaSchemeRuntimeForRevision $newRecord.profile (Get-CaelestiaSchemeRevision $runtime) $runtime -Verified $verifiedScheme
        $activated = $true
        if ($Restart) {
            Start-CaelestiaDetached $Prefix -TaskName $launchTask -PreparedSchemeRuntime
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
                # A broken replacement record must not keep recovery from
                # quitting. The process check below, not Quit's exit path,
                # decides whether anything is still running.
                try { & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null } catch { }
                if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $newRecord.profile).Count) {
                    throw "Activation failed and replacement is still running; versions retained at $Prefix\versions."
                }
                Stop-CaelestiaHosts $Prefix
            }
            $priorPath = $null
            $priorRecord = $null
            try {
                $priorPath = Get-CaelestiaVersionPrefix $Prefix $previous
                $priorRecord = Read-CaelestiaInstall $priorPath
            } catch { }
            if ($priorPath -and $priorRecord) {
                # Root launch entries are the new backward-compatible router even
                # when rolling back to a legacy payload without its own router.
                Copy-CaelestiaRootEntries $Prefix $runtime
                $earlier = if ($old.version -eq 2) { [string]$old.previous } else { '' }
                Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') (New-CaelestiaRootRecord $Prefix $priorRecord $earlier)
                $null = Set-CaelestiaSchemeRuntimeForRevision $newRecord.profile (Get-CaelestiaSchemeRevision $priorPath) $priorPath -Verified $restoreScheme
                if ($Restart) { Start-CaelestiaDetached $Prefix -LegacyReady -PreparedSchemeRuntime }
                Write-Warning 'Activation failed; the previous version was selected again.'
            } else {
                # The retained fallback is gone or unreadable. Reselect a payload
                # that still exists so a later start does not follow a dangling
                # selector, but launch nothing: the replacement just failed and
                # the fallback is not trustworthy either.
                $salvage = ''
                try { $salvage = Select-CaelestiaExistingVersion $Prefix ([string[]]@(Split-Path -Leaf $runtime)) } catch { }
                if (-not $salvage) {
                    Write-Warning 'Activation failed and no retained version is usable; run the installer again.'
                } else {
                    try {
                        $salvagePath = Get-CaelestiaVersionPrefix $Prefix $salvage
                        $salvageRecord = Read-CaelestiaInstall $salvagePath
                        Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') (New-CaelestiaRootRecord $Prefix $salvageRecord '')
                        $null = Set-CaelestiaSchemeRuntimeForRevision $newRecord.profile (Get-CaelestiaSchemeRevision $salvagePath) $salvagePath
                        Write-Warning "Activation failed and the previous version is unusable; version $salvage is selected for the next start."
                    } catch {
                        Write-Warning 'Activation failed and the selector could not be repointed; run the installer again.'
                    }
                }
            }
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
    $previousRuntime = Get-CaelestiaVersionPrefix $Prefix ([string]$old.current)
    $previousRevision = Get-CaelestiaSchemeRevision $previousRuntime
    $targetRevision = Get-CaelestiaSchemeRevision $runtime
    $launchTask = $null
    $activated = $false
    # Verify the target's generation before the running shell is stopped.
    $verifiedScheme = Select-CaelestiaSchemeGeneration $old.profile $targetRevision $runtime
    # Also decide the fallback now: once the shell stops, nothing may probe.
    $restoreScheme = Select-CaelestiaRestoreScheme $old.profile $previousRuntime $verifiedScheme
    try {
        if ($Restart) {
            $launchTask = New-CaelestiaLaunchTask $Prefix -PreparedSchemeRuntime
            & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null
        }
        if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $old.profile).Count) {
            throw 'Quit this installation before switching versions, or request a restart.'
        }
        Stop-CaelestiaHosts $Prefix
        Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') (New-CaelestiaRootRecord $Prefix $record $old.current)
        # The generation verified above is repointed before the readiness
        # clock; a missing one leaves the fixed palette.
        $null = Set-CaelestiaSchemeRuntimeForRevision $old.profile $targetRevision $runtime -Verified $verifiedScheme
        $activated = $true
        if ($Restart) { Start-CaelestiaDetached $Prefix -LegacyReady -TaskName $launchTask -PreparedSchemeRuntime }
    } catch {
        $failure = $_
        if ($activated) {
            & (Join-Path $Prefix 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null
            if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $old.profile).Count) {
                throw 'Version switch failed and the replacement has not exited; selector was not changed again.'
            }
            Stop-CaelestiaHosts $Prefix
            Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') $old
            $null = Set-CaelestiaSchemeRuntimeForRevision $old.profile $previousRevision $previousRuntime -Verified $restoreScheme
            if ($Restart) { Start-CaelestiaDetached $Prefix -LegacyReady -PreparedSchemeRuntime }
        } elseif ($Restart -and -not @(Get-CaelestiaProcesses $Prefix).Count -and -not @(Get-CaelestiaSupervisors $old.profile).Count) {
            $null = Set-CaelestiaSchemeRuntimeForRevision $old.profile $previousRevision $previousRuntime -Verified $restoreScheme
            Start-CaelestiaDetached $Prefix -LegacyReady -PreparedSchemeRuntime
        }
        throw $failure
    } finally {
        if ($launchTask) { Unregister-ScheduledTask -TaskName $launchTask -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

# Test seam: writes the Start-menu shortcut. A throw reports an integration
# failure; the caller restores whatever the shortcut held before.
function New-CaelestiaShortcut([string]$Path, [string]$PowerShellPath, [string]$Arguments, [string]$WorkingDirectory, [string]$Icon) {
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($Path)
    $shortcut.TargetPath = $PowerShellPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = $Icon
    $shortcut.Description = 'Caelestia for Windows'
    $shortcut.Save()
}

function Get-CaelestiaAutostartKey {
    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
}

# Shortcut-only arguments. The HKCU Run value has one builder below, so a new
# launcher command cannot leave the sign-in path on the old console host.
function Get-CaelestiaAutostartArguments([string]$Prefix) {
    return '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Prefix 'Start-Caelestia.ps1') + '"'
}

# Autostart contract: this is the only function that builds the complete HKCU
# Run value. Test-CaelestiaAutostart detects and Set-CaelestiaAutostart
# writes/removes it, always through Get-CaelestiaIntegration and
# Get-CaelestiaAutostartKey. Install and the shell's switch-back path share this
# function. When the no-console launcher helper exists (installer PR #65 adds
# New-CaelestiaHiddenCommand to Caelestia-InstallCommon.ps1), use it so the
# launch command changes in one place; otherwise keep the legacy direct Windows
# PowerShell command for the current payload.
function Get-CaelestiaAutostartValue([string]$Prefix) {
    $hidden = Get-Command New-CaelestiaHiddenCommand -CommandType Function -ErrorAction SilentlyContinue
    if ($hidden) {
        return New-CaelestiaHiddenCommand $Prefix 'start'
    }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        (Join-Path $Prefix 'Start-Caelestia.ps1') + '"'
    return '"' + $powershell + '" ' + $arguments
}

# Autostart contract shared with the installer slice (PR #65):
# - Get-CaelestiaAutostartKey() returns the registry key; fixtures override it.
# - Get-CaelestiaIntegration($Prefix).RunName returns the value name.
# - Test-CaelestiaAutostart($Prefix) returns the observed state; an unreadable
#   key throws instead of reporting the entry as absent.
# - Set-CaelestiaAutostart($Prefix, $Enabled) returns an object with ok, present,
#   changed, verified, error, key, valueName and enabled.
# - Get-CaelestiaAutostartValue($Prefix) is the only HKCU Run command builder.
function Test-CaelestiaAutostart([string]$Prefix) {
    $integration = Get-CaelestiaIntegration $Prefix
    $run = Get-CaelestiaAutostartKey
    try {
        if (-not (Test-Path -LiteralPath $run)) { return $false }
        $entry = Get-ItemProperty -LiteralPath $run -ErrorAction Stop
    } catch {
        # An unreadable key is not evidence that the entry is absent. Callers
        # that only paint status can catch this; Set-CaelestiaAutostart reports
        # it as an unverified removal failure.
        throw "Could not read the Windows autostart entry '$($integration.RunName)': $($_.Exception.Message)"
    }
    return $null -ne $entry.PSObject.Properties[$integration.RunName]
}

# Additive hook for the shell's "Switch back to Windows" choice. Disable
# removes only this installation's own Run entry; it never touches another
# application's value or another prefix's hashed name. Returns a result instead
# of hiding failures: Quit proceeds so the desktop still comes back, but
# Start-Caelestia reports a removal error through a notification and a nonzero
# exit after restoring the desktop.
function Set-CaelestiaAutostart([string]$Prefix, [bool]$Enabled) {
    $integration = Get-CaelestiaIntegration $Prefix
    $run = Get-CaelestiaAutostartKey
    $result = [pscustomobject]@{
        enabled = $Enabled
        key = $run
        valueName = $integration.RunName
        changed = $false
        present = $false
        verified = $true
        ok = $true
        error = ''
    }

    if (-not $Enabled) {
        try {
            if (-not (Test-CaelestiaAutostart $Prefix)) {
                # Already absent is the requested end state, not an error.
                return $result
            }
        } catch {
            $result.ok = $false
            $result.verified = $false
            $result.error = $_.Exception.Message
            return $result
        }

        try {
            Remove-ItemProperty -LiteralPath $run -Name $integration.RunName -ErrorAction Stop
            $result.changed = $true
        } catch {
            # The verification below decides whether this was a real failure or
            # a benign missing-property race. Permission and other errors that
            # leave the entry present are reported.
            $result.ok = $false
            $result.error = $_.Exception.Message
        }

        try {
            $result.present = Test-CaelestiaAutostart $Prefix
        } catch {
            $result.ok = $false
            $result.verified = $false
            if (-not $result.error) { $result.error = $_.Exception.Message }
            return $result
        }

        if ($result.present) {
            $result.ok = $false
            if (-not $result.error) {
                $result.error = "The Windows autostart entry '$($integration.RunName)' is still present after removal."
            }
        } elseif ($result.error) {
            # Removal reported an error even though the entry is gone. Report
            # the observed end state, and keep the diagnostic for logs.
            $result.ok = $true
        }
        return $result
    }

    try {
        if (-not (Test-Path -LiteralPath $run)) { New-Item -Path $run -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $run -Name $integration.RunName -PropertyType String `
            -Value (Get-CaelestiaAutostartValue $Prefix) -Force -ErrorAction Stop | Out-Null
        $result.changed = $true
        $result.present = Test-CaelestiaAutostart $Prefix
        if (-not $result.present) {
            $result.ok = $false
            $result.error = "The Windows autostart entry '$($integration.RunName)' is still absent after it was written."
        }
    } catch {
        $result.ok = $false
        $result.error = $_.Exception.Message
        try {
            $result.present = Test-CaelestiaAutostart $Prefix
        } catch {
            $result.verified = $false
        }
    }
    return $result
}

# Best-effort visible report for a failed autostart removal. Quit still runs so
# the desktop is handed back, but the user must know the sign-in entry remains.
# No settings, permissions or notification consent are changed.
function Show-CaelestiaHandoffWarning([string]$Message) {
    if ($env:OS -ne 'Windows_NT' -or $env:CAELESTIA_TEST_SUPPRESS_TOAST -eq '1') { return }
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
        if ($notifier.Setting.ToString() -ne 'Enabled') { return }
        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>Caelestia autostart</text><text>' +
            [Security.SecurityElement]::Escape($Message) + '</text></binding></visual></toast>')
        $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {
        # Notification permission or WinRT projection can be unavailable; the
        # warning and nonzero exit below still record the failure.
    }
}

# Stable-root and payload launchers share one Quit autostart policy: remove only
# this installation's entry, surface a failure, and let Quit continue. Returns
# the failure text (empty on success) so the caller can rethrow it after Quit.
function Disable-CaelestiaAutostartForQuit([string]$Prefix) {
    $failure = ''
    try {
        $result = Set-CaelestiaAutostart -Prefix $Prefix -Enabled:$false
        if ($result.ok -ne $true -or $result.present -eq $true) {
            $failure = "Caelestia could not remove its Windows autostart entry. Quit will continue and restore the desktop. "
            if ($result.error) { $failure += $result.error + ' ' }
            $failure += "Remove the '$($result.valueName)' entry from Settings > Apps > Startup if it remains."
        }
    } catch {
        $failure = "Caelestia could not remove its Windows autostart entry. Quit will continue and restore the desktop. $($_.Exception.Message)"
    }
    if ($failure) {
        Write-Warning $failure
        Show-CaelestiaHandoffWarning $failure
    }
    return $failure
}

# The Start-menu shortcut and the optional HKCU Run entry are part of the
# activation transaction: a failure here must not leave a selector claiming a
# replacement the user was told failed, or a half-written integration behind.
# Snapshot both before writing, undo only what this transaction changed, then
# select the previous version again (and restart when the install did). A first
# install has no previous payload, so only the integration is removed and the
# error is rethrown; the version stays installed.
function Complete-CaelestiaInstallIntegration {
    param(
        [string]$Prefix,
        [string]$RuntimePrefix,
        [string]$Previous = '',
        [switch]$Restart,
        [switch]$Autostart,
        [string]$Shortcut = '',
        [string]$RunName = ''
    )
    if (-not $Shortcut -or -not $RunName) {
        $integration = Get-CaelestiaIntegration $Prefix
        if (-not $Shortcut) { $Shortcut = $integration.Shortcut }
        if (-not $RunName) { $RunName = $integration.RunName }
    }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-CaelestiaAutostartArguments $Prefix
    $autostartValue = Get-CaelestiaAutostartValue $Prefix
    $run = Get-CaelestiaAutostartKey
    $backup = $null
    $runExisted = $false
    $runValue = ''
    $runWriteAttempted = $false
    $shortcutExisted = $false
    $shortcutWriteAttempted = $false
    try {
        # Snapshot the Run value before any work that can fail. Otherwise a
        # failure during directory or shortcut setup would leave $runExisted
        # false and cleanup would remove an entry this transaction never wrote.
        if ($Autostart) {
            $existing = Get-ItemProperty -LiteralPath $run -Name $RunName -ErrorAction SilentlyContinue
            if ($null -ne $existing) { $runExisted = $true; $runValue = [string]$existing.$RunName }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Shortcut) | Out-Null
        $shortcutExisted = [IO.File]::Exists($Shortcut)
        if ($shortcutExisted) {
            $backupPath = $Shortcut + '.integration-' + [guid]::NewGuid().ToString('N')
            try { [IO.File]::Copy($Shortcut, $backupPath) }
            catch {
                # Without a snapshot a later failure cannot tell the original
                # from a half-written replacement, so abort before touching it.
                try { if ([IO.File]::Exists($backupPath)) { [IO.File]::Delete($backupPath) } } catch { }
                throw "Could not snapshot the existing shortcut; integration was aborted: $($_.Exception.Message)"
            }
            $backup = $backupPath
        }
        $shortcutWriteAttempted = $true
        New-CaelestiaShortcut $Shortcut $powershell $arguments $Prefix ($RuntimePrefix.TrimEnd('\') + '\qs.exe,0')
        if ($Autostart) {
            # Never New-Item -Force an existing registry key: it recreates the
            # key empty and deletes every other application's startup entry.
            if (-not (Test-Path -LiteralPath $run)) { New-Item -Path $run | Out-Null }
            $runWriteAttempted = $true
            New-ItemProperty -Path $run -Name $RunName -PropertyType String -Value $autostartValue -Force | Out-Null
        }
        # A backup that cannot be deleted is not an integration failure: never
        # roll back a completed install over a cleanup problem.
        if ($backup) { try { [IO.File]::Delete($backup) } catch { } }
    } catch {
        $failure = $_
        try {
            if ($backup -and [IO.File]::Exists($backup)) {
                [IO.File]::Copy($backup, $Shortcut, $true)
                [IO.File]::Delete($backup)
            } elseif ($shortcutWriteAttempted -and -not $shortcutExisted -and [IO.File]::Exists($Shortcut)) {
                # Only a shortcut this transaction created is removed; a
                # pre-existing one is restored from its snapshot or left alone.
                [IO.File]::Delete($Shortcut)
            }
        } catch { }
        try {
            if ($runWriteAttempted) {
                if ($runExisted) { New-ItemProperty -Path $run -Name $RunName -PropertyType String -Value $runValue -Force | Out-Null }
                else { Remove-ItemProperty -LiteralPath $run -Name $RunName -ErrorAction SilentlyContinue }
            }
        } catch { }
        if ($Previous) {
            try {
                Switch-CaelestiaVersion $Prefix $Previous -Restart:$Restart
                Write-Warning 'Installation integration failed; the previous version was selected again.'
            } catch {
                throw "Installation integration failed: $($failure.Exception.Message). Rollback to $Previous failed: $($_.Exception.Message)"
            }
        }
        throw $failure
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
            # A host from this retired payload holds its image; stop only this
            # version, never the shell's current host.
            Stop-CaelestiaHosts $Prefix $retired
            Assert-CaelestiaNoReparsePoints $retired
            Remove-Item -LiteralPath $retired -Recurse -Force
        } catch {
            # An app may still hold an old working directory or DLL. Cleanup
            # must not roll back a healthy update; retry on the next install.
            Write-Warning 'Kept a retired version; cleanup could not safely complete.'
        }
    }
}
