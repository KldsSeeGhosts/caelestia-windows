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
    if ($record.version -ne 1 -or -not (Test-CaelestiaSamePath $record.installRoot $Prefix) -or $record.versionId -ne $Id) {
        throw 'Version payload does not belong to this installation.'
    }
    if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) {
        $owner = Read-CaelestiaInstall $Prefix
        if (-not (Test-CaelestiaSamePath $owner.profile $record.profile) -or $owner.installId -ne $record.installId) {
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
        @('Caelestia-Versions.ps1', 'Caelestia-Versions.ps1'),
        @('Switch-CaelestiaToWindows.ps1', 'Switch-CaelestiaToWindows.ps1'),
        @('Caelestia-Launcher.ps1', 'Caelestia-Launcher.ps1')
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

function Install-CaelestiaVersion([string]$Prefix, [string]$Payload, [switch]$Restart, [switch]$Autostart, [switch]$NoIntegration) {
    $old = if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) { Read-CaelestiaInstall $Prefix } else { $null }
    if ($old -and $old.installRoot -and -not (Test-CaelestiaSamePath $old.installRoot $Prefix)) {
        throw 'Do not install into an immutable version directory. Use its stable installRoot.'
    }
    $legacy = $old -and $old.version -eq 1
    $previous = if ($old -and -not $legacy) { [string]$old.current } else { '' }
    $candidate = Get-Content -LiteralPath (Join-Path $Payload 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($candidate.product -ne 'caelestia-windows' -or $candidate.version -ne 1 -or
        ($old -and (-not (Test-CaelestiaSamePath $old.profile $candidate.profile) -or $old.installId -ne $candidate.installId))) {
        throw 'Prepared payload does not match this installation and profile.'
    }
    # A Run value that cannot fit must fail before publication, not after a new
    # version directory and new root scripts already exist. An existing install
    # already has the launcher, whose 8.3 name can shorten the command. A
    # baseline install (the layout main still writes) has none, so copy the
    # prepared launcher into place just long enough to build the exact command,
    # then remove it again. A refusal leaves the prefix unchanged, and the
    # command checked here is the one Copy-CaelestiaRootEntries makes possible.
    if (-not $NoIntegration) {
        $launcher = Join-Path $Prefix 'Caelestia-Launcher.ps1'
        $probeLauncher = $false
        $probeRoot = $false
        # A fresh prefix has no registration yet, so its first install only
        # needs the probe when autostart was requested. An existing prefix may
        # own a Run value, which the helper below refreshes on an upgrade.
        if (-not (Test-Path -LiteralPath $launcher -PathType Leaf) -and
            ($Autostart -or (Test-Path -LiteralPath $Prefix -PathType Container))) {
            $launcherSource = Join-Path $Payload 'Caelestia-Launcher.ps1'
            if (Test-Path -LiteralPath $launcherSource -PathType Leaf) {
                if (-not (Test-Path -LiteralPath $Prefix -PathType Container)) {
                    [IO.Directory]::CreateDirectory($Prefix) | Out-Null
                    $probeRoot = $true
                }
                [IO.File]::Copy($launcherSource, $launcher, $false)
                $probeLauncher = $true
            }
        }
        try {
            Assert-CaelestiaRunValuePreflight $Prefix -Autostart:$Autostart
        } finally {
            if ($probeLauncher) {
                try { [IO.File]::Delete($launcher) }
                catch { Write-Warning "Could not remove the launcher preflight probe: $($_.Exception.Message)" }
            }
            if ($probeRoot) {
                try {
                    if (@(Get-ChildItem -LiteralPath $Prefix -Force).Count -eq 0) { [IO.Directory]::Delete($Prefix) }
                } catch { Write-Warning "Could not remove the empty preflight prefix: $($_.Exception.Message)" }
            }
        }
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

function Switch-CaelestiaVersion([string]$Prefix, [string]$Id, [switch]$Restart, [switch]$SkipIntegration) {
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
        # Existing integration entries follow the selected version: the
        # Apps & features DisplayVersion and the shortcut icon must name the
        # payload the user is actually running, not the one just replaced.
        # A rollback from a failed integration passes -SkipIntegration: that
        # transaction restored its snapshot, so the previous version's entries
        # are already in place and rebuilding them would repeat the command
        # that was just refused.
        if (-not $SkipIntegration) { Update-CaelestiaIntegrationRecords $Prefix $runtime }
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
            # The integration refresh itself may have failed, or the restart
            # after it did. Put the previous version's entries back before the
            # reported failure, so Apps & features never describes a version
            # that is no longer selected. A skipped refresh has nothing to put
            # back: the failed transaction already restored its snapshot.
            if (-not $SkipIntegration) {
                try { Update-CaelestiaIntegrationRecords $Prefix $previousRuntime }
                catch { Write-Warning 'The previous version was selected again, but its Apps & features entry could not be refreshed.' }
            }
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

# Test seam: writes one integration shortcut. A throw reports an integration
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
    $testRoots = Get-CaelestiaIntegrationTestRoots
    if ($testRoots) { return $testRoots.Registry + '\Run' }
    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
}

# Autostart contract: this is the only function that builds the complete HKCU
# Run value. Test-CaelestiaAutostart detects and Set-CaelestiaAutostart
# writes/removes it, always through Get-CaelestiaIntegration and
# Get-CaelestiaAutostartKey. Install and the shell's switch-back path share this
# function. The command itself comes from Get-CaelestiaLaunchCommand, the same
# no-window conhost helper the Start-menu shortcut and Apps & features entry use,
# so a future signed launcher (#20) changes in one place. A Run value is limited
# to 260 characters, so the builder enforces that limit and throws before any
# write when even the launcher's 8.3 path does not fit.
function Get-CaelestiaAutostartValue([string]$Prefix) {
    return (Get-CaelestiaLaunchCommand $Prefix 'start' -MaxLength 260).CommandLine
}

# Fail before the selector changes when the Run value this install would write
# cannot fit Windows' 260-character limit. An upgrade refreshes an existing
# owned value even without -Autostart, so that case is checked too. The caller
# runs this before activation: a refusal leaves the selected version and every
# integration entry untouched.
function Assert-CaelestiaRunValuePreflight([string]$Prefix, [switch]$Autostart) {
    $integration = Get-CaelestiaIntegration $Prefix
    if (-not $integration.RunName) { return }
    if (-not $Autostart) {
        $existing = Get-ItemProperty -LiteralPath (Get-CaelestiaAutostartKey) `
            -Name $integration.RunName -ErrorAction SilentlyContinue
        if ($null -eq $existing) { return }
    }
    $null = Get-CaelestiaAutostartValue $Prefix
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
# Start-Caelestia reports a removal error through a native dialog and a nonzero
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
        # Build the value before creating or writing anything. A prefix whose
        # command cannot fit a Run value fails here with no change at all.
        $autostartValue = Get-CaelestiaAutostartValue $Prefix
        if (-not (Test-Path -LiteralPath $run)) { New-Item -Path $run -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $run -Name $integration.RunName -PropertyType String `
            -Value $autostartValue -Force -ErrorAction Stop | Out-Null
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

# Native report for a failed autostart removal. It cannot depend on Windows
# notifications: those can be disabled, unregistered or silently dropped, and
# the detached launcher discards stdout and stderr. Quit has already restored
# the desktop when the caller shows this, so a modal box is the only report the
# user is guaranteed to see. No settings, permissions or consent are changed.
# Test seam: fixture scripts replace this function to record the message.
# The launcher is hidden and has no window, so the box would have no owner and
# foreground-lock rules could leave it behind whatever the user activated while
# the desktop was restored. Both presenters keep the box topmost. The native
# user32 path needs Add-Type compilation; if that is denied, the Windows Forms
# path needs none. Fully Constrained Language Mode blocks both, and then only
# the caller's Write-Warning and nonzero exit remain.
function Show-CaelestiaHandoffDialog([string]$Message) {
    try {
        Show-CaelestiaTopmostNativeBox $Message
        return
    } catch { }
    try {
        Show-CaelestiaTopmostFormsBox $Message
    } catch {
        # Presentation must never change the caller's exit status or recovery.
    }
}

# MB_OK | MB_ICONWARNING | MB_SETFOREGROUND | MB_TOPMOST. Throws if Add-Type is
# blocked so the caller can fall back.
function Show-CaelestiaTopmostNativeBox([string]$Message) {
    if (-not ('Caelestia.HandoffDialog' -as [type])) {
        Add-Type -Namespace Caelestia -Name HandoffDialog -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int MessageBoxW(System.IntPtr owner, string text, string caption, uint type);
'@
    }
    $null = [Caelestia.HandoffDialog]::MessageBoxW([IntPtr]::Zero, $Message, 'Caelestia autostart', [uint32]0x00050030)
}

# Compiler-free fallback: a hidden topmost owner keeps the owned box topmost.
function Show-CaelestiaTopmostFormsBox([string]$Message) {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $owner = New-Object System.Windows.Forms.Form
    try {
        $owner.TopMost = $true
        $owner.ShowInTaskbar = $false
        $null = [System.Windows.Forms.MessageBox]::Show($owner, $Message, 'Caelestia autostart',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    } finally {
        $owner.Dispose()
    }
}

# Stable-root and payload launchers share one Quit autostart policy: remove only
# this installation's entry, let Quit continue, and return the failure text. The
# caller reports it after the supervisor restores the desktop, because the shell
# has exited by then and cannot report anything itself.
function Disable-CaelestiaAutostartForQuit([string]$Prefix) {
    $failure = ''
    try {
        $result = Set-CaelestiaAutostart -Prefix $Prefix -Enabled:$false
        if ($result.ok -ne $true -or $result.present -eq $true) {
            $failure = "Caelestia could not remove its Windows autostart entry, so it will start again at the next sign-in. "
            if ($result.error) { $failure += $result.error + ' ' }
            $failure += "Remove the '$($result.valueName)' entry in Settings > Apps > Startup."
        }
    } catch {
        $failure = "Caelestia could not remove its Windows autostart entry, so it may start again at the next sign-in. " +
            "Remove this installation's Caelestia entry in Settings > Apps > Startup. $($_.Exception.Message)"
    }
    if ($failure) { Write-Warning $failure }
    return $failure
}

# The Start-menu launch and switch-back entries, the optional desktop entry,
# the optional HKCU Run value and the Apps & features key are part of the
# activation transaction: a failure here must not leave a selector claiming a
# replacement the user was told failed, or a half-written integration behind.
# Set-CaelestiaUserIntegration snapshots every artifact before writing and
# restores only what this transaction changed. Then select the previous version
# again (and restart when the install did). A first install has no previous
# payload, so only the integration is removed and the error is rethrown; the
# version stays installed.
function Complete-CaelestiaInstallIntegration {
    param(
        [string]$Prefix,
        [string]$RuntimePrefix,
        [string]$Previous = '',
        [switch]$Restart,
        [switch]$Autostart,
        [switch]$DesktopShortcut,
        [string]$Shortcut = '',
        [string]$RunName = ''
    )
    $integration = Get-CaelestiaIntegration $Prefix
    if ($Shortcut) { $integration['Shortcut'] = $Shortcut }
    if ($RunName) { $integration['RunName'] = $RunName }
    try {
        Set-CaelestiaUserIntegration $Prefix $RuntimePrefix -Integration $integration `
            -Autostart:$Autostart -DesktopShortcut:$DesktopShortcut
    } catch {
        $failure = $_
        if ($Previous) {
            # The failed transaction restored every entry it snapshotted, so the
            # previous version's integration is untouched. Select it without
            # rebuilding the command that was just refused.
            #
            # An integration retry after an earlier rollback can arrive when the
            # previous version is already selected. Switching would throw
            # "That version is already selected" and replace the real failure
            # with a misleading rollback error, so treat that state as restored.
            $selected = ''
            try { $selected = [string](Read-CaelestiaInstall $Prefix).current } catch { }
            if ($selected -eq $Previous) {
                Write-Warning 'Installation integration failed; the previous version was selected again.'
            } else {
                try {
                    Switch-CaelestiaVersion $Prefix $Previous -Restart:$Restart -SkipIntegration
                    # Do not report a rollback that did not reach the real
                    # previous version.
                    $restored = [string](Read-CaelestiaInstall $Prefix).current
                    if ($restored -ne $Previous) { throw "the selector still names $restored." }
                    Write-Warning 'Installation integration failed; the previous version was selected again.'
                } catch {
                    throw "Installation integration failed: $($failure.Exception.Message). Rollback to $Previous failed: $($_.Exception.Message)"
                }
            }
        }
        throw $failure
    }
}

function Remove-CaelestiaRetiredVersions([string]$Prefix) {
    $record = Read-CaelestiaInstall $Prefix
    if ($record.version -ne 2) { return }
    $running = @(Get-CaelestiaProcesses $Prefix | ForEach-Object { Get-CaelestiaLongPath ([IO.Path]::GetDirectoryName($_.Path)) })
    foreach ($directory in Get-ChildItem -LiteralPath (Join-Path $Prefix 'versions') -Directory) {
        if ($directory.Name -in @($record.current, $record.previous) -or
            (Get-CaelestiaLongPath $directory.FullName) -in $running) { continue }
        try {
            # A prior recursive removal can remove install.json before a cwd
            # lock prevents deleting the directory itself. Retry only a plain,
            # valid-id, empty child without adopting an unknown payload.
            Assert-CaelestiaVersionId $directory.Name
            # The resolver refuses reparse points in this path and its parents.
            $retired = Resolve-CaelestiaDirectory $directory.FullName
            if (@(Get-ChildItem -LiteralPath $retired -Force -ErrorAction Stop).Count -eq 0) {
                # Non-recursive deletion also refuses anything created since
                # enumeration, or a directory still held as a process cwd.
                [IO.Directory]::Delete($retired, $false)
                continue
            }
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
