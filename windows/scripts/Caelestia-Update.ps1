#requires -Version 5.1
. (Join-Path $PSScriptRoot 'Caelestia-UpdateTrust.ps1')

function Assert-CaelestiaUpdatePath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Contains('/') -or
        [IO.Path]::GetFullPath($Path).TrimEnd('\') -cne $Path.TrimEnd('\') -or
        $Path.TrimEnd('\') -eq [IO.Path]::GetPathRoot($Path).TrimEnd('\')) { throw 'Unsafe update path.' }
    foreach ($part in $Path.Substring(3).TrimEnd('\').Split('\')) { Assert-CaelestiaZipComponent $part }
    for ($ancestor = $Path; $ancestor; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
        # Check every ancestor on every call. Native metadata reads avoid
        # repeated PowerShell provider lookup for each extracted ZIP entry.
        # Missing descendants are normal before extraction creates them;
        # access failures and other errors must still fail closed.
        try {
            if ([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Linked update path refused.'
            }
        } catch [IO.FileNotFoundException] {
        } catch [IO.DirectoryNotFoundException] {
        }
    }
}
function Assert-CaelestiaZipComponent([string]$Part) {
    if (-not $Part -or $Part.Length -gt 255 -or $Part -in @('.', '..') -or $Part -match
        '[\x00-\x1f\x7f\\/:*?"<>|]|[. ]$|^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(\.|$)') {
        throw 'Unsafe ZIP component.'
    }
}

function New-CaelestiaUpdateArchive([string]$Directory, [string]$Zip) {
    Assert-CaelestiaUpdatePath $Directory
    Assert-CaelestiaUpdatePath $Zip
    Assert-CaelestiaNoReparsePoints $Directory
    $root = Split-Path -Leaf $Directory
    Assert-CaelestiaZipComponent $root
    Add-Type -AssemblyName System.IO.Compression
    $output = [IO.File]::Open($Zip, [IO.FileMode]::CreateNew)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new($output, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse -Force | Sort-Object FullName) {
            $relative = $file.FullName.Substring($Directory.TrimEnd('\').Length + 1).Replace('\', '/')
            foreach ($part in $relative.Split('/')) { Assert-CaelestiaZipComponent $part }
            $entry = $archive.CreateEntry($root + '/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $inputStream = [IO.File]::OpenRead($file.FullName)
            $entryStream = $entry.Open()
            try { $inputStream.CopyTo($entryStream) } finally { $entryStream.Dispose(); $inputStream.Dispose() }
        }
    } finally {
        if ($archive) { $archive.Dispose() }
        $output.Dispose()
    }
}

function Expand-CaelestiaUpdate([string]$Zip, [string]$Destination, [string]$Root, [long]$Entries, [long]$UnpackedSize,
    [scriptblock]$Progress) {
    Assert-CaelestiaZipComponent $Root
    Assert-CaelestiaUpdatePath $Zip
    Assert-CaelestiaUpdatePath $Destination
    if (Test-Path -LiteralPath $Destination) { throw 'Extraction requires a fresh directory.' }
    if ($Entries -lt 1 -or $Entries -gt 50000 -or $UnpackedSize -lt 1 -or $UnpackedSize -gt 4294967296) { throw 'Invalid ZIP bounds.' }
    Add-Type -AssemblyName System.IO.Compression
    $file = [IO.File]::Open($Zip, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $archive = $null
    $created = $false
    try {
        $archive = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Read)
        if ($archive.Entries.Count -ne $Entries) { throw 'ZIP entry count mismatch.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            $directory = $name.EndsWith('/', [StringComparison]::Ordinal)
            $relative = if ($directory) { $name.Substring(0, $name.Length - 1) } else { $name }
            $parts = $relative.Split('/')
            foreach ($part in $parts) { Assert-CaelestiaZipComponent $part }
            Assert-CaelestiaUpdatePath (Join-Path $Destination $relative.Replace('/', '\'))
            if ($parts[0] -cne $Root -or ($parts.Count -eq 1 -and -not $directory) -or
                -not $seen.Add($relative) -or ($directory -and $entry.Length -ne 0) -or
                $entry.Length -lt 0 -or $entry.Length -gt $UnpackedSize) { throw 'Unsafe ZIP inventory.' }
            $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
            $unixType = ($attributes -shr 16) -band 61440
            if ($unixType -notin @(0, 16384, 32768) -or ($attributes -band 1088) -ne 0 -or
                ($unixType -eq 16384 -and -not $directory)) { throw 'ZIP link/device refused.' }
            $total += $entry.Length
            if ($total -gt $UnpackedSize) { throw 'ZIP exceeds signed unpacked size.' }
            if (-not $directory) { $null = $files.Add($relative) }
        }
        if ($total -ne $UnpackedSize) { throw 'ZIP unpacked size mismatch.' }
        foreach ($name in $seen) {
            $parent = $name
            while ($parent.Contains('/')) {
                $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
                if ($files.Contains($parent)) { throw 'ZIP file/directory collision.' }
            }
        }
        # No arbitrary compression ratio cap: real source/QML archives may be
        # extremely compressible. Authenticated absolute size/count caps and
        # counting every byte bound disk use without rejecting legitimate zeros.
        Assert-CaelestiaUpdatePath $Destination
        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        $created = $true
        $completed = 0L
        $progressClock = [Diagnostics.Stopwatch]::StartNew()
        if ($Progress) { & $Progress 'verifying' 0L $Entries 'entries' }
        foreach ($entry in $archive.Entries) {
            $target = Join-Path $Destination $entry.FullName.Replace('/', '\')
            Assert-CaelestiaUpdatePath $target.TrimEnd('\')
            if ($entry.FullName.EndsWith('/')) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
                $completed++
                continue
            }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            Assert-CaelestiaUpdatePath $target
            $inputStream = $entry.Open()
            $outputStream = $null
            try {
                $outputStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                [Caelestia.Update.Transport]::CopyBounded($inputStream, $outputStream, $entry.Length,
                    $entry.Length, $null, [Threading.CancellationToken]::None)
            } finally {
                if ($outputStream) { $outputStream.Dispose() }
                $inputStream.Dispose()
            }
            $completed++
            if ($Progress -and $progressClock.ElapsedMilliseconds -ge 250) {
                & $Progress 'verifying' $completed $Entries 'entries'
                $progressClock.Restart()
            }
        }
        if ($Progress) { & $Progress 'verifying' $completed $Entries 'entries' }
        return Join-Path $Destination $Root
    } catch {
        if ($created) {
            Assert-CaelestiaUpdatePath $Destination
            Assert-CaelestiaNoReparsePoints $Destination
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        throw
    } finally {
        if ($archive) { $archive.Dispose() }
        $file.Dispose()
    }
}

function Get-CaelestiaUpdateChannel([string]$Profile, [string]$AppVersion = '') {
    $path = Join-Path $Profile 'state\updates\settings.json'
    Assert-CaelestiaUpdatePath $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AppVersion) {
            $parsed = ConvertTo-CaelestiaSemVer $AppVersion
            if ($parsed.Major -cne '0') { return 'stable' }
        }
        return 'preview'
    }
    $settings = Read-CaelestiaStrictJsonFile $path
    Assert-CaelestiaFields $settings @('schema', 'channel')
    if ($settings.schema -ne 1 -or $settings.channel -cnotin @('development', 'preview', 'stable')) { throw 'Invalid channel settings.' }
    return $settings.channel
}

function Invoke-CaelestiaUpdateCheck($Trust, [string]$Channel, [string]$CurrentVersion,
    [string]$StatePath, [scriptblock]$Fetch = {
        param($Address, $Milliseconds)
        return ,([Caelestia.Update.Transport]::Fetch($Address, @('raw.githubusercontent.com'), 0, 65536, -1, $null, $null, $Milliseconds))
    }) {
    $result = [ordered]@{ schema = 1; state = 'not-configured'; channel = $Channel; current = $CurrentVersion
        available = $null; checkedAt = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    if (-not (Test-CaelestiaTrustConfigured $Trust)) { return [pscustomobject]$result }
    $mutex = $null
    $held = $false
    try {
        Assert-CaelestiaTrust $Trust
        if ($Channel -cnotin @('development', 'preview', 'stable')) { throw 'bad-metadata' }
        Assert-CaelestiaUpdatePath $StatePath
        $mutex = [Threading.Mutex]::new($false, 'Global\CaelestiaUpdateTrust-' +
            [Caelestia.Update.Security]::Hash([Text.Encoding]::UTF8.GetBytes($StatePath.ToLowerInvariant())))
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'busy' }
        $highwater = if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            Read-CaelestiaStrictJsonFile $StatePath
        } else { $null }
        if ($highwater) {
            Assert-CaelestiaFields $highwater @('schema', 'rootVersion', 'rootSha256', 'keysVersion', 'keysSha256', 'channels')
            if ($highwater.schema -ne 1) { throw 'bad-metadata' }
            Assert-CaelestiaInteger $highwater.rootVersion 1 ([long]::MaxValue)
            Assert-CaelestiaInteger $highwater.keysVersion 1 ([long]::MaxValue)
            if ($Trust.rootVersion -lt $highwater.rootVersion -or ($Trust.rootVersion -eq $highwater.rootVersion -and
                (Get-CaelestiaRootDigest $Trust) -cne $highwater.rootSha256)) { throw 'replay' }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $keys = & $Fetch ($Trust.metadataBase + 'keys.dsse.json') 30000
        $remaining = 45000 - [int]$clock.ElapsedMilliseconds
        if ($remaining -le 0) { throw 'offline' }
        $pointer = & $Fetch ($Trust.metadataBase + $Channel + '.dsse.json') ([Math]::Min(30000, $remaining))
        $verified = Test-CaelestiaMetadata $keys $pointer $Trust $Channel $highwater
        $release = $verified.Release
        if ($CurrentVersion) {
            try { $comparison = Compare-CaelestiaSemVer $release.buildVersion $CurrentVersion }
            catch { throw 'unsupported' }
        } else { throw 'unsupported' } # Legacy bootstrap is manual, never guessed.
        $channels = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        if ($highwater) {
            foreach ($key in $highwater.channels.Keys) { $channels.Add($key, $highwater.channels[$key]) }
        }
        $channels[$Channel] = @{
            sequence = $verified.Sequence; sha256 = $verified.Sha256; buildVersion = $release.buildVersion
            bundleSha256 = $release.bundle.sha256; manifestSha256 = $release.manifestSha256
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($StatePath)) | Out-Null
        Write-CaelestiaJsonAtomic $StatePath @{
            schema = 1; keysVersion = $verified.KeysVersion; keysSha256 = $verified.KeysSha256; channels = $channels
            rootVersion = $Trust.rootVersion; rootSha256 = Get-CaelestiaRootDigest $Trust
        }
        $result.state = if ($comparison -gt 0) { 'available' } else { 'not-newer' }
        if ($comparison -gt 0) { $result.available = $release }
    } catch {
        $code = $_.Exception.Message
        $result.state = if ($code -cin @('bad-signature', 'expired', 'clock', 'replay', 'unsupported', 'not-configured', 'busy', 'offline')) { $code }
            elseif ($_.Exception -is [Net.Http.HttpRequestException] -or $_.Exception.InnerException -is [Net.Http.HttpRequestException] -or
                $_.Exception.InnerException -is [OperationCanceledException]) { 'offline' } else { 'bad-metadata' }
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
    return [pscustomobject]$result
}

function Save-CaelestiaUpdateBundle($Release, $Trust, [string]$Directory, [scriptblock]$Fetch = {
    param($Address, $Hosts, $Redirects, $Cap, $Size, $Hash, $Destination, $Milliseconds, $Report)
    [Caelestia.Update.Transport]::Fetch($Address, $Hosts, $Redirects, $Cap, $Size, $Hash, $Destination, $Milliseconds,
        [Action[long,long]]$Report)
}, [scriptblock]$Progress) {
    Assert-CaelestiaUpdatePath $Directory
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $bundle = $Release.bundle
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Directory))
    if ($drive.AvailableFreeSpace -lt ($bundle.size + 2 * $bundle.unpackedSize)) { throw 'Insufficient update space.' }
    $partial = Join-Path $Directory ($bundle.sha256 + '-' + [guid]::NewGuid().ToString('N') + '.partial')
    $zip = $partial + '.zip'
    try {
        Assert-CaelestiaUpdatePath $partial
        $report = {
            param([long]$Completed, [long]$Total)
            if ($Progress) { & $Progress 'downloading' $Completed $Total 'bytes' }
        }
        $null = & $Fetch $bundle.url (@('github.com') + @($Trust.redirectHosts)) `
            3 $bundle.size $bundle.size $bundle.sha256 $partial 1200000 $report
        Assert-CaelestiaUpdatePath $partial
        [IO.File]::Move($partial, $zip)
        return $zip
    } finally {
        if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
    }
}

function Get-CaelestiaUpdateStatePath {
    # Deliberately outside install/profile. Rollback and even profile purge
    # must not erase revocation/freshness highwater.
    return Join-Path $env:LOCALAPPDATA 'caelestia-update-trust\github-KldsSeeGhosts-caelestia-windows.json'
}

function Invoke-CaelestiaUpdateInstall([string]$Prefix, [string]$ExpectedCurrent, [string]$ExpectedBuild,
    [string]$Channel, $Trust, [scriptblock]$Progress) {
    # Caller holds BOTH installation mutexes continuously. Installer is invoked
    # on this same PowerShell thread, so its nested named-mutex acquisition is
    # recursive, not a child-process deadlock. Never release through activation.
    $workerLock = Enter-CaelestiaInstallLock $Prefix
    if (-not $workerLock) { throw 'An installation, rollback or uninstall is already in progress.' }
    try {
    $record = Read-CaelestiaInstall $Prefix
    if ($record.version -ne 2 -or $record.current -cne $ExpectedCurrent) { throw 'The selected version changed.' }
    $current = Read-CaelestiaInstall (Get-CaelestiaVersionPrefix $Prefix $record.current)
    if ((Get-CaelestiaUpdateChannel $record.profile $current.appVersion) -cne $Channel) { throw 'The selected channel changed.' }
    & $Progress 'checking'
    $check = Invoke-CaelestiaUpdateCheck $Trust $Channel $current.releaseId (Get-CaelestiaUpdateStatePath)
    if ($check.state -cne 'available' -or $check.available.buildVersion -cne $ExpectedBuild) {
        throw 'The requested authenticated update is no longer available.'
    }
    $release = $check.available
    $base = Join-Path $env:LOCALAPPDATA 'caelestia-windows-updates'
    $stage = Join-Path $base ('staging-' + [guid]::NewGuid().ToString('N'))
    $zip = ''
    try {
        & $Progress 'downloading'
        $zip = Save-CaelestiaUpdateBundle $release $Trust (Join-Path $base 'downloads') -Progress $Progress
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.bundle.sha256) {
            throw 'Authenticated bundle mismatch.'
        }
        & $Progress 'verifying'
        $bundle = Expand-CaelestiaUpdate $zip $stage $release.bundle.root $release.bundle.entries $release.bundle.unpackedSize -Progress $Progress
        & $Progress 'verifying'
        # No supplied code before BOTH signed bundle and manifest digests match.
        $manifest = Join-Path $bundle 'release.json'
        if ((Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.manifestSha256) {
            throw 'Authenticated manifest mismatch.'
        }
        $manifestValue = Read-CaelestiaStrictJsonFile $manifest 16777216 -AllowUtf8Bom
        if ($manifestValue.releaseId -cne $release.buildVersion -or
            $manifestValue.sourceRevision -cne $release.sourceRevision -or
            $manifestValue.backendRevision -cne $release.backendRevision -or
            $manifestValue.profileSchema -ne 1) { throw 'Authenticated release identity mismatch.' }
        # Only schema 1 is supported. No silent settings migration, snapshot of
        # unrelated profile files or restoration of old settings is performed.
        $integration = Get-CaelestiaIntegration $Prefix
        $autostart = $null -ne (Get-ItemProperty -LiteralPath (Get-CaelestiaAutostartKey) -Name $integration.RunName -ErrorAction SilentlyContinue)
        & $Progress 'installing'
        $selected = Read-CaelestiaInstall $Prefix
        if ($selected.installId -cne $record.installId -or $selected.current -cne $ExpectedCurrent -or
            (Get-CaelestiaUpdateChannel $record.profile $current.appVersion) -cne $Channel) {
            throw 'The selected version, owner or channel changed before activation.'
        }
        & (Join-Path $bundle 'Install-CaelestiaRelease.ps1') -BundleRoot $bundle -Prefix $Prefix `
            -ExpectedManifestSha256 $release.manifestSha256 -Restart -Autostart:$autostart | Out-Null
        $after = Read-CaelestiaInstall $Prefix
        $runtime = Get-CaelestiaVersionPrefix $Prefix $after.current
        $installed = Read-CaelestiaInstall $runtime
        if ($after.current -ceq $ExpectedCurrent -or $installed.releaseId -cne $ExpectedBuild -or
            $installed.releaseManifestSha256.ToLowerInvariant() -cne $release.manifestSha256) {
            throw 'The authenticated update was not activated.'
        }
        # Deployment alias is separate from immutable artifact/release identity.
        $installed | Add-Member -NotePropertyName displayVersion -NotePropertyValue $release.displayVersion -Force
        $installed | Add-Member -NotePropertyName installedChannel -NotePropertyValue $Channel -Force
        Write-CaelestiaJsonAtomic (Join-Path $runtime 'install.json') $installed
        & $Progress 'restarting'
    } finally {
        if ($zip -and [IO.File]::Exists($zip)) {
            Assert-CaelestiaUpdatePath $zip
            [IO.File]::Delete($zip)
        }
        if (Test-Path -LiteralPath $stage) {
            Assert-CaelestiaUpdatePath $stage
            Assert-CaelestiaNoReparsePoints $stage
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
    } finally { Exit-CaelestiaInstallLock $workerLock }
}
