# Support-only projection. Never dot-source installed management/launch scripts,
# execute a manifest-specified command, or open a profile/log directory.
$script:SupportProviderIds = @('shell', 'tiling', 'audio', 'battery', 'bluetooth', 'brightness',
    'network', 'media', 'notifications', 'desktop', 'capture', 'idleInhibit', 'keyboard', 'tray', 'wallpaper')
$script:SupportCategories = @('supported', 'unsupported', 'denied', 'unavailable', 'transient', 'failed', 'empty')
$script:SupportReasons = @('none', 'not-collected', 'missing', 'invalid', 'oversized', 'timeout',
    'permission-denied', 'provider-unavailable', 'operation-failed', 'unsupported', 'empty',
    'transient', 'disabled', 'completion-unobserved')

function Get-SupportField($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary] -and $Name -cin @($Object.Keys)) { return ,($Object[$Name]) }
    return $null
}

function Get-SupportToken($Value, [string]$Pattern) {
    if ($Value -is [string] -and $Value.Length -le 96 -and $Value -cmatch $Pattern) { return $Value }
    return $null
}

function Get-SupportNumber($Value, [long]$Maximum = 1000000000) {
    if (($Value -is [int] -or $Value -is [long]) -and $Value -ge 0 -and $Value -le $Maximum) { return $Value }
    return $null
}

function Get-SupportBoolean($Value) {
    if ($Value -is [bool]) { return $Value }
    return $null
}

function Test-SupportLiteral($Value, [string]$Expected) {
    return ($Value -is [string] -and $Value -ceq $Expected)
}

function Test-SupportVersion($Value, [int[]]$Allowed = @(1)) {
    return ($Value -is [int] -and $Value -in $Allowed)
}

function New-SupportSource([string]$Reason) {
    return [ordered]@{ category = $(if ($Reason -eq 'none') { 'supported' } else { 'unavailable' }); reason = $Reason }
}

function New-SupportProvider([string]$Id, [string]$Reason = 'not-collected') {
    return [ordered]@{
        id = $Id; category = 'unavailable'; reason = $Reason; ready = $null
        requested = $null; accepted = $null; completed = $null
        counters = [ordered]@{ failures = $null; recentFailures = $null; samples = $null }
        timing = [ordered]@{ lastDurationMs = $null; totalDurationMs = $null }
        errors = @()
    }
}

function New-SupportBundle([string]$Reason = 'none') {
    return [ordered]@{
        schema = 'caelestia-support-bundle'; version = 1
        collection = New-SupportSource $Reason
        sources = [ordered]@{
            install = New-SupportSource 'not-collected'
            release = New-SupportSource 'not-collected'
            snapshot = New-SupportSource 'not-collected'
        }
        identity = [ordered]@{
            trust = 'declared-unverified'; releaseId = $null; sourceRevision = $null
            nativeSourceRevision = $null; backendRevision = $null; glazierRevision = $null
            m3shapesRevision = $null; schemeRevision = $null; executableSha256 = $null
            releaseManifestSha256 = $null
        }
        modules = [ordered]@{ qt = $null; materialyoucolor = $null; pillow = $null }
        environment = [ordered]@{
            windowsVersion = $null; architecture = $null
            displayDriver = [ordered]@{ category = 'unavailable'; reason = 'not-collected'; version = $null }
        }
        providers = @($script:SupportProviderIds | ForEach-Object { New-SupportProvider $_ })
    }
}

# Refuse network/device paths and reparse points, including ancestor junctions.
# The deadline in the parent also bounds local filesystem/JSON provider stalls.
function Resolve-SupportLocalPath([string]$Path) {
    if ($Path -cnotmatch '\A[A-Za-z]:[\\/]' -or $Path.IndexOf(':', 2) -ge 0) { throw 'invalid' }
    foreach ($segment in ($Path.Substring(3) -split '[\\/]')) {
        if ($segment -match '[. ]\z' -or $segment -match '\A(CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(\.|\z)') { throw 'invalid' }
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { throw 'invalid' }
    $drive = [IO.DriveInfo]::new($full.Substring(0, 3))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'invalid' }
    # Inspect from the drive root down, refusing a junction before examining
    # anything below it (which could otherwise follow a network-backed target).
    $cursor = $full.Substring(0, 3)
    foreach ($segment in ($full.Substring(3) -split '[\\/]')) {
        if (-not $segment) { continue }
        $cursor = [IO.Path]::Combine($cursor, $segment)
        try { $attributes = [IO.File]::GetAttributes($cursor) }
        catch [IO.FileNotFoundException] { break }
        catch [IO.DirectoryNotFoundException] { break }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'invalid' }
    }
    return $full
}

function Read-SupportJson([string]$Path, [int]$Limit) {
    $stream = $null
    try {
        $full = Resolve-SupportLocalPath $Path
        if ([IO.Directory]::Exists($full)) { return @{ reason = 'invalid'; data = $null } }
        $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt $Limit) { return @{ reason = 'oversized'; data = $null } }
        # Limit+1 also detects growth after the size check.
        $buffer = [byte[]]::new($Limit + 1)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt $Limit) { return @{ reason = 'oversized'; data = $null } }
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $text = $utf8.GetString($buffer, 0, $count).TrimStart([char]0xfeff)
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $parser = [Web.Script.Serialization.JavaScriptSerializer]::new()
        $parser.MaxJsonLength = $Limit
        $parser.RecursionLimit = 24
        $data = $parser.DeserializeObject($text)
        if ($data -isnot [Collections.IDictionary]) { throw 'invalid' }
        return @{ reason = 'none'; data = $data }
    } catch [IO.FileNotFoundException] {
        return @{ reason = 'missing'; data = $null }
    } catch [IO.DirectoryNotFoundException] {
        return @{ reason = 'missing'; data = $null }
    } catch [UnauthorizedAccessException] {
        return @{ reason = 'permission-denied'; data = $null }
    } catch [IO.IOException] {
        return @{ reason = 'provider-unavailable'; data = $null }
    } catch {
        return @{ reason = 'invalid'; data = $null }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function ConvertTo-SupportProvider([string]$Id, $InputProvider) {
    $row = New-SupportProvider $Id 'invalid'
    $category = Get-SupportField $InputProvider 'category'
    if ($category -isnot [string] -or $category -cnotin $script:SupportCategories) { return $row }
    $row.category = $category
    $reason = Get-SupportField $InputProvider 'reason'
    $row.reason = if ($reason -is [string] -and $reason -cin $script:SupportReasons) { $reason } elseif ($category -in @('supported', 'empty')) { 'none' } else { 'provider-unavailable' }
    $row.ready = Get-SupportBoolean (Get-SupportField $InputProvider 'ready')
    $row.requested = Get-SupportBoolean (Get-SupportField $InputProvider 'requested')
    $row.accepted = Get-SupportBoolean (Get-SupportField $InputProvider 'accepted')
    $row.completed = Get-SupportBoolean (Get-SupportField $InputProvider 'completed')
    # Missing observation is unknown, never success inferred from dispatch.
    if ($row.requested -ne $true) { $row.accepted = $null }
    if ($row.accepted -ne $true) { $row.completed = $null }
    if ($row.category -notin @('supported', 'empty') -and $row.completed -eq $true) { $row.completed = $null }
    $counters = Get-SupportField $InputProvider 'counters'
    foreach ($name in @('failures', 'recentFailures', 'samples')) {
        $row.counters[$name] = Get-SupportNumber (Get-SupportField $counters $name)
    }
    $timing = Get-SupportField $InputProvider 'timing'
    $row.timing.lastDurationMs = Get-SupportNumber (Get-SupportField $timing 'lastDurationMs') 600000
    $row.timing.totalDurationMs = Get-SupportNumber (Get-SupportField $timing 'totalDurationMs') 86400000
    $errors = Get-SupportField $InputProvider 'errors'
    if ($errors -is [array]) {
        # Only four categorized records per provider; never any message/trace.
        foreach ($errorRow in @($errors | Select-Object -First 4)) {
            $errorCategory = Get-SupportField $errorRow 'category'
            $errorReason = Get-SupportField $errorRow 'reason'
            $row.errors += [ordered]@{
                category = $(if ($errorCategory -is [string] -and $errorCategory -cin @('denied', 'unavailable', 'transient', 'failed')) { $errorCategory } else { 'unavailable' })
                reason = $(if ($errorReason -is [string] -and $errorReason -cin $script:SupportReasons) { $errorReason } else { 'provider-unavailable' })
                count = Get-SupportNumber (Get-SupportField $errorRow 'count')
            }
        }
    }
    return $row
}

function Get-CaelestiaSupportBundle([string]$Prefix, [string]$SnapshotPath) {
    $bundle = New-SupportBundle
    $sha = '\A[a-f0-9]{40}\z'
    $digest = '\A[a-fA-F0-9]{64}\z'
    $version = '\A[0-9]{1,5}(\.[0-9]{1,5}){1,3}\z'
    $releaseId = '\Av?[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}(-(preview|alpha|beta|rc)\.[0-9]{1,6})?\z'
    $install = Read-SupportJson (Join-Path $Prefix 'install.json') 65536
    $record = $install.data
    if ($install.reason -eq 'none' -and (-not (Test-SupportLiteral (Get-SupportField $record 'product') 'caelestia-windows') -or
        -not (Test-SupportVersion (Get-SupportField $record 'version') @(1, 2)))) { $install = @{ reason = 'invalid'; data = $null } }
    $runtime = $Prefix
    if ($install.reason -eq 'none' -and (Get-SupportField $record 'version') -eq 2) {
        $id = Get-SupportToken (Get-SupportField $record 'current') '\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}\z'
        if ($id) {
            # Selector is used only to open this fixed metadata child, not exported.
            $runtime = Join-Path $Prefix ('versions\' + $id)
            $install = Read-SupportJson (Join-Path $runtime 'install.json') 65536
            $payload = $install.data
            if ($install.reason -eq 'none' -and (-not (Test-SupportLiteral (Get-SupportField $payload 'product') 'caelestia-windows') -or
                -not (Test-SupportVersion (Get-SupportField $payload 'version')) -or
                -not (Test-SupportLiteral (Get-SupportField $payload 'versionId') $id) -or
                -not (Test-SupportLiteral (Get-SupportField $payload 'sourceRevision') (Get-SupportField $record 'sourceRevision')))) {
                $install = @{ reason = 'invalid'; data = $null }
            }
        } else { $install = @{ reason = 'invalid'; data = $null } }
    }
    $bundle.sources.install = New-SupportSource $install.reason
    if ($install.data) {
        foreach ($name in @('sourceRevision', 'backendRevision', 'glazierRevision')) {
            $bundle.identity[$name] = Get-SupportToken (Get-SupportField $install.data $name) $sha
        }
        foreach ($name in @('executableSha256', 'releaseManifestSha256')) {
            $bundle.identity[$name] = Get-SupportToken (Get-SupportField $install.data $name) $digest
        }
        $bundle.identity.releaseId = Get-SupportToken (Get-SupportField $install.data 'releaseId') $releaseId
    }
    $release = Read-SupportJson (Join-Path $runtime 'release-manifest.json') 4194304
    if ($release.reason -eq 'none' -and (-not (Test-SupportLiteral (Get-SupportField $release.data 'schema') 'caelestia-windows-release') -or
        -not (Test-SupportVersion (Get-SupportField $release.data 'version')) -or
        -not (Test-SupportLiteral (Get-SupportField $release.data 'platform') 'windows-x64') -or
        -not $install.data -or -not $bundle.identity.sourceRevision -or
        -not (Test-SupportLiteral (Get-SupportField $release.data 'sourceRevision') $bundle.identity.sourceRevision) -or
        ($bundle.identity.backendRevision -and
            -not (Test-SupportLiteral (Get-SupportField $release.data 'backendRevision') $bundle.identity.backendRevision)))) {
        $release = @{ reason = 'invalid'; data = $null }
    }
    $bundle.sources.release = New-SupportSource $release.reason
    if ($release.data) {
        $manifestReleaseId = Get-SupportToken (Get-SupportField $release.data 'releaseId') $releaseId
        if ($manifestReleaseId) { $bundle.identity.releaseId = $manifestReleaseId }
        $bundle.identity.nativeSourceRevision = Get-SupportToken (Get-SupportField $release.data 'nativeSourceRevision') $sha
        $dependencies = Get-SupportField $release.data 'dependencies'
        foreach ($pair in @(@('m3shapes', 'm3shapesRevision'), @('schemeCli', 'schemeRevision'))) {
            $bundle.identity[$pair[1]] = Get-SupportToken (Get-SupportField (Get-SupportField $dependencies $pair[0]) 'revision') $sha
        }
        $bundle.modules.qt = Get-SupportToken (Get-SupportField $release.data 'qtVersion') $version
        $packages = Get-SupportField (Get-SupportField $dependencies 'schemeCli') 'pythonPackages'
        foreach ($name in @('materialyoucolor', 'pillow')) {
            $bundle.modules[$name] = Get-SupportToken (Get-SupportField $packages $name) $version
        }
    }
    $bundle.environment.windowsVersion = Get-SupportToken ([Environment]::OSVersion.Version.ToString()) $version
    # Read exactly one architecture token, never enumerate the environment.
    $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $architecture) { $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }
    $bundle.environment.architecture = switch ($architecture) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } 'x86' { 'x86' } default { $null } }
    if ($SnapshotPath) {
        $snapshot = Read-SupportJson $SnapshotPath 65536
        if ($snapshot.reason -eq 'none' -and (-not (Test-SupportLiteral (Get-SupportField $snapshot.data 'schema') 'caelestia-support-input') -or
            -not (Test-SupportVersion (Get-SupportField $snapshot.data 'version')))) { $snapshot = @{ reason = 'invalid'; data = $null } }
        $bundle.sources.snapshot = New-SupportSource $snapshot.reason
        if ($snapshot.data) {
            $providers = Get-SupportField $snapshot.data 'providers'
            for ($index = 0; $index -lt $script:SupportProviderIds.Count; $index++) {
                $id = $script:SupportProviderIds[$index]
                $value = Get-SupportField $providers $id
                if ($null -ne $value) { $bundle.providers[$index] = ConvertTo-SupportProvider $id $value }
            }
            # Existing shell.state contains paths and keyboard/screen names.
            # Only lifecycle.ready is accepted, never the surrounding object.
            $state = Get-SupportField $snapshot.data 'shellState'
            $ready = Get-SupportBoolean (Get-SupportField (Get-SupportField $state 'lifecycle') 'ready')
            if ($null -ne $ready) {
                $bundle.providers[0] = New-SupportProvider 'shell'
                $bundle.providers[0].category = if ($ready) { 'supported' } else { 'unavailable' }
                $bundle.providers[0].reason = if ($ready) { 'none' } else { 'completion-unobserved' }
                $bundle.providers[0].ready = $ready
            }
            # Existing shell.tilingState is content-free, but still project it.
            $tiling = Get-SupportField $snapshot.data 'tilingState'
            $loaded = Get-SupportBoolean (Get-SupportField $tiling 'backendLoaded')
            if ($null -ne $loaded) {
                $bundle.providers[1] = New-SupportProvider 'tiling'
                $bundle.providers[1].category = if ($loaded) { 'supported' } else { 'unavailable' }
                $bundle.providers[1].reason = if ($loaded) { 'none' } else { 'provider-unavailable' }
                $bundle.providers[1].ready = $loaded
                $bundle.providers[1].counters.failures = Get-SupportNumber (Get-SupportField $tiling 'failedCount')
                $bundle.providers[1].counters.recentFailures = Get-SupportNumber (Get-SupportField $tiling 'recentFailureCount')
            }
            $driver = Get-SupportToken (Get-SupportField $snapshot.data 'displayDriverVersion') $version
            if ($driver) { $bundle.environment.displayDriver = [ordered]@{ category = 'supported'; reason = 'none'; version = $driver } }
        }
    }
    return $bundle
}
