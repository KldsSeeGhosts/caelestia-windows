# Private helpers for the source recipe and its disposable fixtures.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-SourceRelativePath([string]$Path) {
    if (-not $Path -or $Path -match '[\\:\x00-\x1f\x7f*?"<>|]' -or $Path.StartsWith('/') -or
        @($Path.Split('/') | Where-Object {
            $_ -in @('', '.', '..') -or $_ -match '[. ]$|^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(?:\.|$)'
        }).Count) { throw "Unsafe source asset path: $Path" }
}

function Assert-SourceNoLinks([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Source recipe paths must not traverse reparse points.'
            }
        }
        $current = Split-Path -Parent $current
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        foreach ($child in Get-ChildItem -LiteralPath $full -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked source asset refused.' }
            if ($child.PSIsContainer) { Assert-SourceNoLinks $child.FullName }
        }
    }
}

function Get-SourceHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SourceRecipeHash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-SourceArchiveConfiguration([string]$Root) {
    $settings = [ordered]@{}
    foreach ($key in @('core.autocrlf', 'core.eol')) {
        $value = @(& git -C $Root config --get $key)
        if ($LASTEXITCODE -notin @(0, 1)) { throw 'Cannot record Git archive line-ending configuration.' }
        $settings[$key] = $(if ($value.Count) { $value -join '' } else { 'unspecified' })
    }
    return $settings
}

function Assert-SourceHash([string]$Path, [string]$Hash) {
    if ($Hash -cnotmatch '^[a-f0-9]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-SourceHash $Path) -cne $Hash) { throw "Missing or wrong SHA256: $(Split-Path -Leaf $Path)" }
}

function Write-SourceJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 32) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Invoke-SourceGit([string]$Root, [string[]]$Arguments) {
    $result = @(& git -c core.hooksPath=NUL -C $Root @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Source Git operation failed: $($Arguments[0])" }
    return $result
}

function Get-SourceGitJson([string]$Root, [string]$Revision, [string]$Path) {
    return ((Invoke-SourceGit $Root @('show', "${Revision}:$Path")) -join "`n") | ConvertFrom-Json
}

function Get-SourceDownload([string]$Url, [string]$Hash, [string]$CacheRoot, [switch]$Offline) {
    $uri = [uri]$Url
    if ($uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.Host -notin @('github.com', 'codeload.github.com', 'static.crates.io', 'static.rust-lang.org', 'download.qt.io') -or
        $Hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Only recorded anonymous public HTTPS origins are allowed.' }
    $target = Join-Path $CacheRoot $Hash
    Assert-SourceNoLinks $target
    if (Test-Path -LiteralPath $target) {
        Assert-SourceHash $target $Hash
        return $target
    }
    if ($Offline) { throw "Missing archive in offline cache: $($uri.AbsolutePath)" }
    $temporary = Join-Path $CacheRoot ($Hash + '.' + [guid]::NewGuid().ToString('N') + '.partial')
    # --disable is deliberately first: no curlrc, account cookies, credentials,
    # provider configuration, persistent authentication, or retry after denial.
    & curl.exe --disable --fail --location --proto '=https' --proto-redir '=https' `
        --connect-timeout 20 --max-time 300 --silent --show-error --output $temporary $Url
    if ($LASTEXITCODE -ne 0) { throw "Anonymous download failed; partial retained, no authentication retry: $($uri.Host)" }
    Assert-SourceHash $temporary $Hash
    Move-Item -LiteralPath $temporary -Destination $target
    return $target
}

function Open-SourceZip([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @{}
        foreach ($entry in $zip.Entries) {
            # .NET Framework's published Windows ZIPs use backslashes.
            # Normalize before validation/collision checks, never before a
            # whole-tree extraction (we only copy selected entry streams).
            $name = $entry.FullName.Replace('\', '/').TrimEnd('/')
            if (-not $name) { continue }
            Assert-SourceRelativePath $name
            if ($names.ContainsKey($name)) { throw "Duplicate ZIP member: $name" }
            $names[$name] = $true
            $mode = ($entry.ExternalAttributes -shr 16) -band 0xf000
            if ($mode -eq 0xa000) { throw "Linked ZIP member: $name" }
        }
        return $zip
    } catch { $zip.Dispose(); throw }
}

function Get-SourceZipEntry($Zip, [string]$Suffix) {
    Assert-SourceRelativePath $Suffix
    $matches = @($Zip.Entries | Where-Object {
        $_.FullName.Replace('\', '/') -ceq $Suffix -or
            $_.FullName.Replace('\', '/').EndsWith('/' + $Suffix, [StringComparison]::Ordinal)
    })
    if ($matches.Count -ne 1) { throw "Missing or ambiguous ZIP member: $Suffix" }
    return $matches[0]
}

function Read-SourceZipJson($Zip, [string]$Suffix) {
    $reader = [IO.StreamReader]::new((Get-SourceZipEntry $Zip $Suffix).Open())
    try { return $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
}

function Copy-SourceZipEntry($Zip, [string]$Suffix, [string]$Target, [string]$Hash) {
    $entry = Get-SourceZipEntry $Zip $Suffix
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Target)) | Out-Null
    $inputStream = $entry.Open()
    $outputStream = [IO.File]::Create($Target)
    try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
    Assert-SourceHash $Target $Hash
}

function Assert-SourceCargoCoverage([string]$Text, [object[]]$Archives) {
    $expected = @{}
    foreach ($block in [regex]::Split($Text, '(?m)^\[\[package\]\]\s*$') | Select-Object -Skip 1) {
        $name = [regex]::Match($block, '(?m)^name = "([^"]+)"').Groups[1].Value
        $version = [regex]::Match($block, '(?m)^version = "([^"]+)"').Groups[1].Value
        $origin = [regex]::Match($block, '(?m)^source = "([^"]+)"').Groups[1].Value
        if (-not $origin) { continue }
        if ($origin -cne 'registry+https://github.com/rust-lang/crates.io-index') {
            throw "Unreviewed Cargo source: $name"
        }
        $hash = [regex]::Match($block, '(?m)^checksum = "([a-f0-9]{64})"').Groups[1].Value
        $path = "sources/crates/$name-$version.crate"
        if ($expected.ContainsKey($path) -or -not $hash) { throw "Invalid Cargo package: $name" }
        $expected[$path] = $hash
    }
    $actual = @($Archives | Where-Object path -like 'sources/crates/*')
    if (-not $expected.Count -or $expected.Count -ne $actual.Count) { throw 'Cargo supplier inventory differs from the candidate lockfile.' }
    foreach ($archive in $actual) {
        if (-not $expected.ContainsKey($archive.path) -or $expected[$archive.path] -cne $archive.sha256) {
            throw "Cargo source/checksum not reviewed: $($archive.path)"
        }
    }
}

function Assert-SourceToolchain($Toolchain, $Reference) {
    foreach ($pair in @(@('qtVersion', 'qt'), @('rustVersion', 'rust'), @('cli11Version', 'cli11'), @('clangVersion', 'llvm'))) {
        if ($Toolchain.($pair[0]) -cne $Reference.($pair[1])) {
            throw "Supplier rule update required for $($pair[0]); do not reuse stale notices."
        }
    }
}

function Export-SourceTarMembers([string]$Archive, [string[]]$Members, [string]$Destination) {
    $membersUnique = @($Members | Sort-Object -Unique)
    foreach ($member in $membersUnique) { Assert-SourceRelativePath $member }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    # Select only recorded members. Never unpack a whole supplier tree or
    # follow archive symlinks/hardlinks. Batch below Windows' command-line limit.
    for ($offset = 0; $offset -lt $membersUnique.Count; $offset += 40) {
        $last = [Math]::Min($membersUnique.Count - 1, $offset + 39)
        $batch = @($membersUnique[$offset..$last])
        $listing = @(& tar.exe -tvf $Archive -- @batch)
        if ($LASTEXITCODE -ne 0 -or $listing.Count -ne $batch.Count -or
            @($listing | Where-Object { $_ -notmatch '^-' -or $_ -match ' link to | -> ' }).Count) {
            throw 'Missing, nonregular, or linked supplier notice member.'
        }
        & tar.exe -xf $Archive -C $Destination -- @batch
        if ($LASTEXITCODE -ne 0) { throw 'Supplier notice extraction failed.' }
    }
    Assert-SourceNoLinks $Destination
}

function New-SourceBundle([string]$Source, [string]$Revision, [string]$Destination, [string]$Scratch) {
    if ($Revision -cnotmatch '^[a-f0-9]{40}$') { throw 'A full source commit is required.' }
    # Work only in a disposable bare repository. Never add refs to the caller's
    # checkout, consume its branches/tags, or bundle unrelated/private refs.
    $null = & git init --bare --quiet $Scratch
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize source bundle repository.' }
    $null = Invoke-SourceGit $Scratch @('fetch', '--quiet', '--no-tags', $Source, $Revision)
    $null = Invoke-SourceGit $Scratch @('update-ref', 'refs/heads/source', $Revision)
    $null = Invoke-SourceGit $Scratch @('bundle', 'create', $Destination, 'refs/heads/source')
    # Verify in an empty repo, so missing prerequisites cannot hide in a clone.
    $verifyRoot = $Scratch + '-verify'
    $null = & git init --bare --quiet $verifyRoot
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize bundle verifier.' }
    $null = Invoke-SourceGit $verifyRoot @('bundle', 'verify', $Destination)
    $heads = (Invoke-SourceGit $verifyRoot @('bundle', 'list-heads', $Destination)) -join "`n"
    if ($heads -cne "$Revision refs/heads/source") { throw 'Bundle does not declare the exact source revision.' }
    $null = Invoke-SourceGit $verifyRoot @('fetch', '--quiet', $Destination, 'refs/heads/source')
    $actual = (Invoke-SourceGit $verifyRoot @('rev-parse', 'FETCH_HEAD^{commit}')) -join ''
    if ($actual -cne $Revision) { throw 'Bundle does not contain its declared commit.' }
    $null = Invoke-SourceGit $verifyRoot @('update-ref', 'refs/heads/source', $Revision)
    $null = Invoke-SourceGit $verifyRoot @('fsck', '--full', '--no-reflogs')
}

function Export-SourceGitMembers([string]$Root, [string]$Revision, [string[]]$Members, [string]$Destination, [string]$Scratch) {
    $membersUnique = @($Members | Sort-Object -Unique)
    for ($offset = 0; $offset -lt $membersUnique.Count; $offset += 40) {
        $last = [Math]::Min($membersUnique.Count - 1, $offset + 39)
        $batch = @($membersUnique[$offset..$last])
        $tar = Join-Path $Scratch 'git-members.tar'
        $null = Invoke-SourceGit $Root (@('archive', '--format=tar', "--output=$tar", $Revision, '--') + $batch)
        Export-SourceTarMembers $tar $batch $Destination
    }
}

function Get-SourceCaptureInput([string]$Root, [string]$Revision, $Lock, [string]$Layout, [string]$IntegratedPath) {
    if ($Layout -eq 'Integrated') {
        Assert-SourceRelativePath $IntegratedPath
        $tree = (Invoke-SourceGit $Root @('ls-tree', $Revision, '--', $IntegratedPath)) -join ''
        if ($tree -notmatch '^040000 tree ') { throw 'Integrated capture must be a real committed source directory, not a gitlink.' }
        return [pscustomobject]@{ root = $Root; revision = $Revision; cargoPath = "$IntegratedPath/Cargo.lock"; licenseRoot = "$IntegratedPath/" }
    }
    if ($IntegratedPath) { throw 'IntegratedCapturePath requires the explicit Integrated layout.' }
    return [pscustomobject]@{
        root = (Join-Path $Root $Lock.glazier.path); revision = $Lock.glazier.revision
        cargoPath = 'Cargo.lock'; licenseRoot = ''
    }
}

function New-SourceZip([string]$Root, [string]$Target) {
    $stream = [IO.File]::Create($Target)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName) {
            $relative = $file.FullName.Substring($Root.Length + 1).Replace('\', '/')
            Assert-SourceRelativePath $relative
            $entry = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $inputStream = $file.OpenRead()
            $outputStream = $entry.Open()
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}

function Get-SourceSupplierId([string]$Path) {
    if ($Path -match '^(?:sources/crates/|Cargo/)([^/]+?)(?:\.crate)?(?:/.*)?$') { return 'crate-' + $Matches[1] }
    if ($Path -match '^(?:sources/qt/|Qt-[^/]+/)(qt[a-z]+)') { return 'qt-' + $Matches[1] }
    if ($Path -match '^(?:sources/rust/|Rust-)') { return 'rust' }
    if ($Path -match '^(?:sources/CLI11|CLI11-)') { return 'cli11' }
    return 'shell'
}

function Get-SourceSupplierComponents([object[]]$Archives, $Toolchain) {
    # A scriptblock is required for ordered dictionaries on Windows PowerShell
    # 5.1. Group-Object component silently groups their missing CLR property.
    foreach ($group in $Archives | Group-Object { $_.component }) {
        $version = switch -Wildcard ($group.Name) {
            'qt-*' { $Toolchain.qtVersion }
            'rust' { $Toolchain.rustVersion }
            'cli11' { $Toolchain.cli11Version }
            'crate-*' {
                if ($group.Group[0].path -notmatch '^sources/crates/.+?-(\d[^/]*)\.crate$') { throw 'Unrecognized recorded crate version.' }
                $Matches[1]
            }
            default { throw "Unrecognized supplier component: $($group.Name)" }
        }
        [ordered]@{
            id = $group.Name; role = 'supplier-conservative'; version = $version
            source = @($group.Group | ForEach-Object { $_.url })
            recordedLicenses = @($group.Group | ForEach-Object { $_.recordedLicenses } | Sort-Object -Unique)
            shipped = $null
        }
    }
}

function Get-SourcePayloadOwner([string]$Path, [hashtable]$Known, [hashtable]$Staged) {
    Assert-SourceRelativePath $Path
    if ($Staged.ContainsKey($Path)) { return $Staged[$Path] }
    if ($Path -like 'payload/shell/*' -and $Path -cne 'payload/shell/sources.json') {
        throw "Unknown payload component (not in candidate staging map): $Path"
    }
    if (-not $Known.ContainsKey($Path)) { throw "Unknown payload component: $Path" }
    return $Known[$Path]
}

function Assert-SourcePayloadCoverage($Inventory, $Manifest) {
    if ($Manifest.sourceRevision -cne $Inventory.sourceRevision) { throw 'Application and source candidate revisions differ.' }
    foreach ($project in $Inventory.projects | Where-Object id -ne 'shell') {
        $key = if ($project.id -eq 'backend') { 'quickshell' } elseif ($project.id -eq 'capture') { 'glazier' } else { $project.id }
        if ($Manifest.dependencies.$key.revision -cne $project.revision) { throw "Application source mismatch: $key" }
    }
    if ($Manifest.qtVersion -cne $Inventory.toolchain.qtVersion) { throw 'Application Qt version differs from supplier sources.' }
    $known = @{}
    $referenceHashes = @{}
    foreach ($entry in $Inventory.payloadRules.reference) {
        if ($known.ContainsKey($entry.path)) { throw 'Duplicate payload reference rule.' }
        $known[$entry.path] = $entry.component
        $referenceHashes[$entry.path] = $entry.sha256
    }
    $staged = @{}
    foreach ($entry in $Inventory.payloadRules.staged) {
        if ($staged.ContainsKey($entry.path)) { throw 'Duplicate candidate staging target.' }
        $staged[$entry.path] = $entry.component
    }
    $components = @{}
    foreach ($component in $Inventory.components) {
        if ($components.ContainsKey($component.id)) { throw 'Duplicate component identity.' }
        $components[$component.id] = $component
    }
    $files = @()
    $actual = @{}
    foreach ($file in $Manifest.files) {
        if ($actual.ContainsKey($file.path)) { throw 'Duplicate application file.' }
        $owner = Get-SourcePayloadOwner $file.path $known $staged
        if (-not $components.ContainsKey($owner)) { throw "Unrecorded component: $owner" }
        if ($owner -eq 'qt' -and $referenceHashes[$file.path] -cne $file.sha256) {
            throw "Unreviewed Qt supplier bytes: $($file.path)"
        }
        $record = [ordered]@{ path = $file.path; component = $owner; sha256 = $file.sha256; size = $file.size }
        $files += $record
        $actual[$file.path] = $record
    }
    foreach ($notice in $Inventory.notices) {
        $target = 'payload/licenses/supplemental/' + $notice.path
        if (-not $actual.ContainsKey($target) -or $actual[$target].sha256 -cne $notice.sha256) {
            throw "Missing or wrong packaged notice: $($notice.path)"
        }
    }
    foreach ($notice in $Inventory.projectNotices) {
        if (-not $actual.ContainsKey($notice.payloadPath) -or $actual[$notice.payloadPath].sha256 -cne $notice.sha256) {
            throw "Missing or wrong project notice: $($notice.payloadPath)"
        }
    }
    foreach ($entry in $Inventory.payloadRules.staged) {
        if (-not $actual.ContainsKey($entry.path)) { throw "Missing candidate staged file: $($entry.path)" }
        if ($entry.PSObject.Properties['sha256'] -and $entry.sha256 -and $actual[$entry.path].sha256 -cne $entry.sha256) {
            throw "Wrong staged source bytes: $($entry.path)"
        }
    }
    foreach ($component in $Inventory.components) {
        $codeFiles = @($files | Where-Object { $_.component -eq $component.id -and $_.path -notlike 'payload/licenses/*' })
        $noticeFiles = @($files | Where-Object { $_.component -eq $component.id -and $_.path -like 'payload/licenses/*' })
        # A notice for an SDK/proc-macro crate is not evidence that its code
        # ships. Aggregate Qt runtime mapping is explicit; transitive linkage
        # and module-level legal applicability remain separate review work.
        $component.shipped = if ($component.role -eq 'supplier-conservative') { $null } else { $codeFiles.Count -gt 0 }
        $component | Add-Member -Force -NotePropertyName payloadEvidence -NotePropertyValue ([ordered]@{
            directCodeFiles = $codeFiles.Count; noticeFiles = $noticeFiles.Count
            transitiveLinkage = $(if ($component.role -eq 'supplier-conservative') { 'not-inferred-from-source-or-notice-inclusion' } else { 'not-applicable' })
        })
        if ($component.role -eq 'optional' -and $component.shipped) { throw "Optional payload requires a reviewed recipe rule: $($component.id)" }
    }
    return $files
}

function Get-SourceReferenceOwners($Files) {
    $owners = @{}
    foreach ($file in $Files) {
        $p = [string]$file.path
        $owner = 'shell'
        if ($p -eq 'payload/qs.exe' -or $p -like 'payload/qml/Quickshell/*' -or $p -like 'payload/licenses/Quickshell*' -or
            $p -match '^payload/licenses/(MaterialColor-LICENSE|LGPL-3.0.txt|GPL-3.0.txt)$') { $owner = 'backend' }
        elseif ($p -eq 'payload/glazier.exe' -or $p -like 'payload/licenses/Glazier-*') { $owner = 'capture' }
        elseif ($p -eq 'payload/m3shapes.dll' -or $p -like 'payload/qml/M3Shapes/*' -or $p -eq 'payload/licenses/M3Shapes-LICENSE') { $owner = 'm3shapes' }
        elseif ($p -like 'payload/licenses/fonts/*') { $owner = 'font-' + $p.Split('/')[3] }
        elseif ($p -like 'payload/licenses/supplemental/*') { $owner = Get-SourceSupplierId $p.Substring('payload/licenses/supplemental/'.Length) }
        elseif ($p -like 'payload/Qt6*' -or $p -like 'payload/plugins/*' -or
            ($p -like 'payload/qml/*' -and $p -notlike 'payload/qml/Caelestia/*') -or $p -like 'payload/licenses/Qt/*' -or
            $p -like 'payload/licenses/Qt-sbom/*' -or $p -eq 'payload/qt.conf') { $owner = 'qt' }
        $owners[$p] = $owner
    }
    return $owners
}
