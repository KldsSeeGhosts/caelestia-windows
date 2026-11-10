#requires -Version 5.1
# Publisher-signing policy for Caelestia Windows releases.
#
# Dot-source this file. Every function is either pure or reads only the bundle
# and reviewed inventory files it is given. The release policy it encodes is
# documented in windows/docs/CODE-SIGNING-POLICY.md and checked by
# windows/scripts/Test-AuthenticodeSignatures.ps1. Nothing here is wired into
# CI: the verifier is a standalone tool until a signing pipeline exists.

# Qt 6.11 Windows binaries are signed by The Qt Company. All 90 Qt DLLs in the
# reviewed supplier list (windows/release/vendor-privacy-review.json) carry this
# exact subject, read with Get-AuthenticodeSignature from the pinned
# Qt 6.11.3 msvc2022_64 toolchain:
#   CN=The QT Company Oy, O=The QT Company Oy, L=Espoo, S=Uusimaa, C=FI,
#   SERIALNUMBER=2637805-2, OID.2.5.4.15=Private Organization,
#   OID.1.3.6.1.4.1.311.60.2.1.3=FI
# Matching is the exact literal subject only. Do not parse CN and O and rebuild
# an identity from the fields: .NET renders quoted and escaped values as
# different strings, and normalising them would let an impostor that reuses the
# trusted CN and O values pass. A future Qt certificate renewal changes this
# subject, so verification fails with `unexpected-signer` until a reviewed
# update measures the new Qt DLLs and adds the new literal subject here.
$script:CaelestiaApprovedQtSubjects = @(
    'CN=The QT Company Oy, O=The QT Company Oy, L=Espoo, S=Uusimaa, C=FI, SERIALNUMBER=2637805-2, OID.2.5.4.15=Private Organization, OID.1.3.6.1.4.1.311.60.2.1.3=FI'
)

# $PSScriptRoot is the caller's script after this file is dot-sourced, so
# remember this file's own directory for the helper this module loads itself.
$script:CaelestiaSigningRoot = $PSScriptRoot
. (Join-Path $script:CaelestiaSigningRoot 'Caelestia-SemVer.ps1')

function Get-CaelestiaQtSignerSubjects {
    return @($script:CaelestiaApprovedQtSubjects)
}

# True only for a reviewed Qt subject literal. There is deliberately no parsed
# fallback: .NET can render quoted or escaped CN and O values, and reconstructing
# the identity from those fields would accept a certificate that is not the
# measured one. A renewal must be reviewed and its exact subject added above.
function Test-CaelestiaQtSignerSubject {
    param([AllowEmptyString()][string]$Subject)
    if ([string]::IsNullOrWhiteSpace($Subject)) { return $false }
    foreach ($approved in $script:CaelestiaApprovedQtSubjects) {
        if ([string]::Equals($Subject, $approved, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

# Classifies a release reference. `stable` is the only channel the policy signs.
# The grammar matches the code that produces and promotes releases:
#   windows/scripts/Caelestia-SemVer.ps1   (Test-CaelestiaDevVersion)
#   windows/ci/New-NexusCandidate.ps1      (identity and tag)
#   windows/ci/nexus_publish.py            (development publish, promote)
# Development is CORE-dev.EPOCH.RUN.ATTEMPT and is always a pre-release.
# Preview is any other pre-release alias (for example 0.1.0-preview.2).
# Stable is an unqualified core of 1.0.0 or newer: promotion requires the alias
# to equal the core and refuses a 0.x core, and published versions never carry
# build metadata.
function Get-CaelestiaReleaseChannel {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Reference)
    $result = [ordered]@{ channel = 'none'; releaseId = ''; tag = ''; core = '' }
    $value = $Reference.Trim()
    if ($value -match '^refs/heads/') { return [pscustomobject]$result }
    if ($value -match '^refs/tags/') { $value = $value.Substring('refs/tags/'.Length) }
    if ($value -cnotmatch '^v([0-9A-Za-z.+-]+)$') { return [pscustomobject]$result }
    $identity = $Matches[1]
    if ($identity -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') { return [pscustomobject]$result }
    try { $parsed = ConvertTo-CaelestiaSemVer $identity } catch { return [pscustomobject]$result }
    # The published grammar is narrower than SemVer: no build metadata.
    if ($parsed.Build) { return [pscustomobject]$result }
    $result.releaseId = $identity
    $result.tag = 'v' + $identity
    $result.core = $parsed.Core
    if (Test-CaelestiaDevVersion $identity) {
        $result.channel = 'development'
    } elseif ($parsed.Prerelease) {
        $result.channel = 'preview'
    } elseif (-not $parsed.Core.StartsWith('0.', [StringComparison]::Ordinal)) {
        $result.channel = 'stable'
    }
    return [pscustomobject]$result
}

# Shared ownership rules. Signing, verification and the reviewed inventory must
# agree, so they all classify through this function.
function Get-CaelestiaSigningKind {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = $RelativePath.Replace('\', '/')
    $extension = [IO.Path]::GetExtension($path)
    if ($extension -eq '.ps1') {
        if ($path -ceq 'Install-CaelestiaRelease.ps1' -or $path -cmatch '^payload/[^/]+\.ps1$') { return 'owned-ps1' }
        return 'other-script'
    }
    if ($extension -notin @('.exe', '.dll')) { return 'other' }
    # First-party PE: the capture host, the compiled desktop supervisor and every
    # Caelestia QML module or helper DLL built from this repository.
    if ($path -ceq 'payload/DesktopTakeover.dll' -or
        $path -cmatch '^payload/caelestia-[A-Za-z0-9._-]+\.(exe|dll)$' -or
        $path -cmatch '^payload/qml/Caelestia/.+\.dll$') { return 'owned-pe' }
    # Deployed Qt runtime, Qt plugins and Qt QML modules keep their vendor
    # signature. Caelestia and M3Shapes modules are excluded explicitly.
    if ($path -cmatch '^payload/Qt6[^/]*\.dll$' -or
        $path -cmatch '^payload/plugins/.+\.dll$' -or
        ($path -cmatch '^payload/qml/(?!Caelestia/|M3Shapes/).+\.dll$')) { return 'qt-pe' }
    # qs.exe (Quickshell), m3shapes.dll, Mesa/Microsoft redistributables and
    # anything else: present in the package, never signed with our certificate.
    return 'other-pe'
}

# Enumerates the bundle once and returns classified records plus the exact
# signed set. Fails on case collisions and reparse points, like the installer.
function Get-CaelestiaSigningInventory {
    param([Parameter(Mandatory)][string]$BundleRoot)
    $root = [IO.Path]::GetFullPath($BundleRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Signing inventory requires an extracted bundle.' }
    $seen = @{}
    $records = New-Object 'System.Collections.Generic.List[object]'
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release bundle must not contain reparse points.' }
            $relative = $item.FullName.Substring($root.Length + 1).Replace('\', '/')
            if ($seen.ContainsKey($relative)) { throw 'Release bundle contains case-colliding paths.' }
            $seen[$relative] = $true
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $records.Add([pscustomobject]@{
                path = $relative
                kind = Get-CaelestiaSigningKind $relative
                size = [long]$item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
    }
    $all = @($records | Sort-Object path)
    $ownedPe = @($all | Where-Object { $_.kind -eq 'owned-pe' })
    $ownedPs1 = @($all | Where-Object { $_.kind -eq 'owned-ps1' })
    $qtPe = @($all | Where-Object { $_.kind -eq 'qt-pe' })
    $otherPe = @($all | Where-Object { $_.kind -ceq 'other-pe' })
    if (-not $ownedPe.Count -or -not $ownedPs1.Count) { throw 'Bundle has no first-party PE or PowerShell files to classify.' }
    if (-not $qtPe.Count) { throw 'Bundle has no deployed Qt PE files; refusing to guess the release root.' }
    return [pscustomobject]@{
        root = $root
        files = $all
        ownedPe = $ownedPe
        ownedPs1 = $ownedPs1
        signed = @(@($ownedPe) + @($ownedPs1))
        qtPe = $qtPe
        otherPe = $otherPe
    }
}

# A bundle path from a reviewed inventory. Reject absolute paths, traversal,
# backslashes and duplicates so a malformed inventory cannot widen the set.
function Assert-CaelestiaInventoryPath {
    param([AllowEmptyString()][string]$Path, [string]$Description)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or
        $Path.StartsWith('/') -or $Path -match '^[A-Za-z]:' -or
        @($Path.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count) {
        throw "Invalid $Description path: '$Path'"
    }
}

# Reads the reviewed signed-file inventory and the reviewed Qt supplier list.
function Get-CaelestiaExpectedSigningInventory {
    param(
        [Parameter(Mandatory)][string]$SignedInventoryPath,
        [Parameter(Mandatory)][string]$VendorReviewPath
    )
    $signedDoc = Get-Content -LiteralPath $SignedInventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($signedDoc.schema -cne 'caelestia-signing-inventory' -or $signedDoc.version -ne 1 -or
        -not $signedDoc.signedFiles) {
        throw 'Invalid reviewed signing inventory.'
    }
    $signed = New-Object 'System.Collections.Generic.List[string]'
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($signedDoc.signedFiles)) {
        Assert-CaelestiaInventoryPath ([string]$path) 'signed inventory'
        if (-not $seen.Add([string]$path)) { throw "Duplicate signed inventory path: $path" }
        $kind = Get-CaelestiaSigningKind ([string]$path)
        if ($kind -notin @('owned-pe', 'owned-ps1')) {
            throw "Signed inventory lists a file the policy does not own: $path ($kind)"
        }
        $signed.Add([string]$path)
    }
    if (-not $signed.Count) { throw 'Signed inventory is empty.' }

    $vendorDoc = Get-Content -LiteralPath $VendorReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($vendorDoc.schema -cne 'caelestia-vendor-privacy-review' -or $vendorDoc.version -ne 1 -or
        -not $vendorDoc.files) {
        throw 'Invalid reviewed Qt supplier list.'
    }
    $qt = New-Object 'System.Collections.Generic.List[string]'
    $qtSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($vendorDoc.files)) {
        if ([string]$entry.origin -cne 'qt' -or [IO.Path]::GetExtension([string]$entry.path) -ne '.dll') { continue }
        Assert-CaelestiaInventoryPath ([string]$entry.path) 'Qt supplier'
        $path = 'payload/' + [string]$entry.path
        if (-not $qtSeen.Add($path)) { throw "Duplicate Qt supplier path: $path" }
        $qt.Add($path)
    }
    if (-not $qt.Count) { throw 'Qt supplier list has no deployed DLLs.' }
    return [pscustomobject]@{
        signed = @($signed | Sort-Object -CaseSensitive)
        qt = @($qt | Sort-Object -CaseSensitive)
    }
}

function Assert-CaelestiaFileSet {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [string]$MissingMessage,
        [string]$UnexpectedMessage
    )
    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Actual) { $null = $actualSet.Add($path) }
    $expectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Expected) { $null = $expectedSet.Add($path) }
    foreach ($path in @($Expected | Sort-Object -CaseSensitive)) {
        if (-not $actualSet.Contains($path)) { throw ($MissingMessage + $path) }
    }
    foreach ($path in @($Actual | Sort-Object -CaseSensitive)) {
        if (-not $expectedSet.Contains($path)) { throw ($UnexpectedMessage + $path) }
    }
}

# Checks the expected file set before any signature is examined. A missing capture
# exe, supervisor, bootstrap, maintenance script or Qt DLL fails here even when
# the bundle's own manifest was edited to match the deletion.
function Assert-CaelestiaReleaseCompleteness {
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$ManifestPath
    )
    Assert-CaelestiaFileSet `
        -Actual @($Inventory.signed | ForEach-Object { $_.path }) `
        -Expected @($Expected.signed) `
        -MissingMessage 'Release bundle is missing a reviewed signed file: ' `
        -UnexpectedMessage 'Release bundle contains a first-party file absent from the reviewed inventory: '
    Assert-CaelestiaFileSet `
        -Actual @($Inventory.qtPe | ForEach-Object { $_.path }) `
        -Expected @($Expected.qt) `
        -MissingMessage 'Release bundle is missing a reviewed Qt DLL: ' `
        -UnexpectedMessage 'Release bundle contains a Qt DLL absent from the reviewed supplier list: '

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'Release bundle is missing release.json.' }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -cne 'caelestia-windows-release' -or $manifest.version -ne 1 -or
        $null -eq $manifest.files) {
        throw 'Invalid release manifest for signature verification.'
    }
    $listed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files)) {
        $path = [string]$entry.path
        Assert-CaelestiaInventoryPath $path 'release manifest'
        if (-not $listed.Add($path)) { throw "Release manifest contains a duplicate file: $path" }
        if (-not (Test-Path -LiteralPath (Join-Path $Inventory.root $path.Replace('/', '\')) -PathType Leaf)) {
            throw "Release manifest lists a missing file: $path"
        }
    }
    foreach ($row in $Inventory.files) {
        if ($row.path -ceq 'release.json') { continue }
        if (-not $listed.Contains($row.path)) {
            throw "Release bundle contains a file absent from release.json: $($row.path)"
        }
    }
    return [pscustomobject]@{
        signedFiles = @($Expected.signed).Count
        qtFiles = @($Expected.qt).Count
        manifestFiles = $listed.Count
    }
}

# Pure decision for one signature record. The project publisher is the exact
# certificate subject recorded from the first accepted signing request, compared
# as a literal string. A certificate renewal with a new or differently rendered
# subject is rejected until a reviewed change records the new literal.
# QtVendorSigner is only for the reviewed Qt publisher identity; never pass a
# project publisher through it.
function Test-CaelestiaSignatureRecord {
    param(
        [Parameter(Mandatory)][AllowNull()]$Record,
        [string]$ExpectedSignerSubject,
        [switch]$QtVendorSigner,
        [switch]$RequireTimestamp
    )
    if ($ExpectedSignerSubject -and $QtVendorSigner) {
        throw 'A signature decision accepts a project subject or the Qt vendor identity, not both.'
    }
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Record -or -not $Record.SignerCertificate) {
        $reasons.Add('unsigned')
        return [pscustomobject]@{ ok = $false; reasons = $reasons.ToArray(); subject = ''; timestampSubject = '' }
    }
    $subject = [string]$Record.SignerCertificate.Subject
    $status = [string]$Record.Status
    if ($status -cne 'Valid') { $reasons.Add('signature-status-' + ($status -replace '[^A-Za-z0-9]', '')) }
    if ($QtVendorSigner) {
        if (-not (Test-CaelestiaQtSignerSubject $subject)) { $reasons.Add('unexpected-signer') }
    } elseif ($ExpectedSignerSubject -and
        -not [string]::Equals($subject, $ExpectedSignerSubject, [StringComparison]::Ordinal)) {
        $reasons.Add('unexpected-signer')
    }
    $timestampSubject = ''
    if ($RequireTimestamp) {
        $stamper = $Record.TimeStamperCertificate
        if ($null -eq $stamper) { $reasons.Add('missing-timestamp') }
        else {
            $timestampSubject = [string]$stamper.Subject
            if (-not $timestampSubject) { $reasons.Add('missing-timestamp') }
        }
    }
    return [pscustomobject]@{
        ok = ($reasons.Count -eq 0)
        reasons = $reasons.ToArray()
        subject = $subject
        timestampSubject = $timestampSubject
        status = $status
    }
}

# Stable mode: every first-party file is signed by the project and timestamped,
# every Qt file keeps a valid Qt signature, and no non-owned file carries the
# project identity. Preview mode: Qt signatures only.
function Test-CaelestiaSigningPolicy {
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][ValidateSet('stable', 'preview')][string]$Channel,
        [string]$ExpectedSignerSubject,
        [scriptblock]$SignatureProvider = { param($Path) Get-AuthenticodeSignature -LiteralPath $Path }
    )
    if ($Channel -eq 'stable' -and -not $ExpectedSignerSubject) { throw 'Stable signature verification requires the expected signer subject.' }
    $failures = New-Object 'System.Collections.Generic.List[object]'
    $signatures = @{}
    function Get-Record([string]$RelativePath) {
        if ($signatures.ContainsKey($RelativePath)) { return $signatures[$RelativePath] }
        $record = & $SignatureProvider (Join-Path $Inventory.root $RelativePath.Replace('/', '\'))
        $signatures[$RelativePath] = $record
        return $record
    }
    foreach ($row in $Inventory.qtPe) {
        $decision = Test-CaelestiaSignatureRecord (Get-Record $row.path) -QtVendorSigner -RequireTimestamp
        if (-not $decision.ok) {
            $failures.Add([ordered]@{ path = $row.path; kind = 'qt-pe'; reasons = $decision.reasons })
        }
    }
    if ($Channel -eq 'stable') {
        foreach ($row in $Inventory.signed) {
            $decision = Test-CaelestiaSignatureRecord (Get-Record $row.path) -ExpectedSignerSubject $ExpectedSignerSubject -RequireTimestamp
            if (-not $decision.ok) {
                $failures.Add([ordered]@{ path = $row.path; kind = $row.kind; reasons = $decision.reasons })
            }
        }
    }
    # No third-party file may carry the project publisher identity. This is the
    # m3shapes and modified-upstream rule: include them, never re-sign them.
    if ($ExpectedSignerSubject) {
        foreach ($row in $Inventory.otherPe) {
            $decision = Test-CaelestiaSignatureRecord (Get-Record $row.path) -ExpectedSignerSubject $null
            if ($decision.subject -and
                [string]::Equals($decision.subject, $ExpectedSignerSubject, [StringComparison]::Ordinal)) {
                $failures.Add([ordered]@{ path = $row.path; kind = 'other-pe'; reasons = @('third-party-file-signed-by-project') })
            }
        }
    }
    return [pscustomobject]@{
        ok = ($failures.Count -eq 0)
        failures = $failures.ToArray()
        checkedQt = @($Inventory.qtPe).Count
        checkedOwned = if ($Channel -eq 'stable') { @($Inventory.signed).Count } else { 0 }
        channel = $Channel
    }
}
