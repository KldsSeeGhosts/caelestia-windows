#requires -Version 5.1
<#
.SYNOPSIS
    Regression fixtures for the standalone publisher-signing verifier.

.DESCRIPTION
    Nothing here trusts, installs or modifies machine certificates. A disposable
    code-signing certificate is created in a temporary CurrentUser certificate
    store, used to sign disposable fixture files, and removed in the cleanup
    block together with that store's registry key. The machine trusted root
    store is never touched, so real Get-AuthenticodeSignature calls report the
    fixture chain as untrusted; the positive policy paths are driven through the
    verifier's injectable signature provider instead.

    Cases cover:
      * release-channel classification for development, preview and stable;
      * the owned / Qt / third-party file classification;
      * the checked-in inventory against the reviewed Qt supplier list;
      * completeness against the reviewed inventories and release.json,
        including deleted capture host, supervisor, bootstrap, script and Qt DLL;
      * exact publisher subjects, including a lookalike rejection;
      * signature acceptance, missing timestamps and unexpected signers;
      * end-to-end exit codes of Test-AuthenticodeSignatures.ps1 on a synthetic
        bundle, including a rejected untrusted chain.

.PARAMETER OutputRoot
    Optional scratch directory. Defaults to a new directory under the temp path.

.EXAMPLE
    powershell -NoProfile -File windows/scripts/Test-SignatureVerification.ps1
#>
[CmdletBinding()]
param([string]$OutputRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Signing.ps1')

$scratch = if ($OutputRoot) {
    $value = [IO.Path]::GetFullPath($OutputRoot)
    if (Test-Path -LiteralPath $value) { throw 'Fixture output must be a new directory.' }
    [IO.Directory]::CreateDirectory($value) | Out-Null
    $value
} else {
    $created = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-signing-fixture-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($created) | Out-Null
    $created
}
$tempStoreName = 'CaelestiaSigningFixture-' + [guid]::NewGuid().ToString('N')
$tempStoreKey = "HKCU:\Software\Microsoft\SystemCertificates\$tempStoreName"
$store = $null
$certificate = $null
$passed = 0
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$releaseRoot = Split-Path -Parent $PSScriptRoot
$signedInventoryPath = Join-Path $releaseRoot 'release\signing-inventory.json'
$vendorReviewPath = Join-Path $releaseRoot 'release\vendor-privacy-review.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Fixture assertion failed: $Message" }
}

function New-FixtureText([string]$Path, [string]$Value) {
    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function New-FixturePe([string]$Path) {
    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    # A throwaway unsigned PE: the compiler emits it, nothing ever runs it.
    $type = 'public static class Fixture' + [guid]::NewGuid().ToString('N').Substring(0, 12) + ' { ' +
        'public static int Value = 1; public static void Main() { } }'
    $outputType = if ([IO.Path]::GetExtension($Path) -eq '.exe') { 'ConsoleApplication' } else { 'Library' }
    Add-Type -TypeDefinition $type -OutputAssembly $Path -OutputType $outputType
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Fixture PE compilation failed.' }
}

function Write-FixtureManifest([string]$BundleRoot) {
    $files = @(Get-ChildItem -LiteralPath $BundleRoot -File -Recurse -Force |
        Where-Object { $_.FullName -ne (Join-Path $BundleRoot 'release.json') } |
        Sort-Object FullName | ForEach-Object {
            [ordered]@{
                path = $_.FullName.Substring($BundleRoot.Length + 1).Replace('\', '/')
                size = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
    [ordered]@{
        schema = 'caelestia-windows-release'; version = 1; platform = 'windows-x64'
        releaseId = '1.0.0'; signing = 'unsigned-preview'; files = $files
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $BundleRoot 'release.json') -Encoding UTF8
}

function Write-FixtureInventories([string]$Directory, [string[]]$Signed, [string[]]$Qt) {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $signedPath = Join-Path $Directory 'signing-inventory.json'
    $vendorPath = Join-Path $Directory 'vendor-privacy-review.json'
    [ordered]@{
        schema = 'caelestia-signing-inventory'; version = 1; signedFiles = @($Signed)
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $signedPath -Encoding UTF8
    $vendorFiles = @($Qt | ForEach-Object { [ordered]@{ path = $_.Substring('payload/'.Length); origin = 'qt' } })
    [ordered]@{
        schema = 'caelestia-vendor-privacy-review'; version = 1; files = $vendorFiles
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $vendorPath -Encoding UTF8
    return [pscustomobject]@{ Signed = $signedPath; Vendor = $vendorPath }
}

function Remove-ManifestEntry([string]$BundleRoot, [string]$RelativePath) {
    $manifestPath = Join-Path $BundleRoot 'release.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.files = @($manifest.files | Where-Object { $_.path -cne $RelativePath })
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

try {
    # --- Release channel classification -------------------------------------
    $channels = @(
        @{ ref = 'refs/tags/v0.2.0-dev.1.23.4'; channel = 'development' }
        @{ ref = 'v0.2.0-dev.1.1.1'; channel = 'development' }
        @{ ref = 'refs/tags/v0.1.0-preview.2'; channel = 'preview' }
        @{ ref = 'refs/tags/v1.0.0-rc.1'; channel = 'preview' }
        @{ ref = 'refs/tags/v1.0.0'; channel = 'stable' }
        @{ ref = 'v10.20.30'; channel = 'stable' }
        @{ ref = 'refs/tags/v0.9.0'; channel = 'none' }
        @{ ref = 'refs/tags/v1.0.0+build.1'; channel = 'none' }
        @{ ref = 'refs/tags/release-1.0.0'; channel = 'none' }
        @{ ref = 'refs/heads/main'; channel = 'none' }
        @{ ref = 'refs/heads/v1.0.0'; channel = 'none' }
    )
    foreach ($case in $channels) {
        $actual = Get-CaelestiaReleaseChannel $case.ref
        Assert-True ($actual.channel -ceq $case.channel) "channel for $($case.ref) was '$($actual.channel)', expected '$($case.channel)'"
        $passed++
    }
    $stable = Get-CaelestiaReleaseChannel 'refs/tags/v1.2.3'
    Assert-True ($stable.releaseId -ceq '1.2.3' -and $stable.tag -ceq 'v1.2.3' -and $stable.core -ceq '1.2.3') 'stable identity fields'
    $passed++

    # --- Ownership classification -------------------------------------------
    $kinds = @(
        @{ path = 'Install-CaelestiaRelease.ps1'; kind = 'owned-ps1' }
        @{ path = 'payload/Start-Caelestia.ps1'; kind = 'owned-ps1' }
        @{ path = 'payload/Caelestia-Update.ps1'; kind = 'owned-ps1' }
        @{ path = 'payload/caelestia-capture.exe'; kind = 'owned-pe' }
        @{ path = 'payload/caelestia-coreplugin.dll'; kind = 'owned-pe' }
        @{ path = 'payload/DesktopTakeover.dll'; kind = 'owned-pe' }
        @{ path = 'payload/qml/Caelestia/Windows/caelestia-windowsplugin.dll'; kind = 'owned-pe' }
        @{ path = 'payload/Qt6Core.dll'; kind = 'qt-pe' }
        @{ path = 'payload/plugins/platforms/qwindows.dll'; kind = 'qt-pe' }
        @{ path = 'payload/qml/QtQuick/qtquick2plugin.dll'; kind = 'qt-pe' }
        @{ path = 'payload/qs.exe'; kind = 'other-pe' }
        @{ path = 'payload/m3shapes.dll'; kind = 'other-pe' }
        @{ path = 'payload/qml/M3Shapes/m3shapes.dll'; kind = 'other-pe' }
        @{ path = 'payload/opengl32sw.dll'; kind = 'other-pe' }
        @{ path = 'Install.cmd'; kind = 'other' }
        @{ path = 'release.json'; kind = 'other' }
    )
    foreach ($case in $kinds) {
        $actual = Get-CaelestiaSigningKind $case.path
        Assert-True ($actual -ceq $case.kind) "kind for $($case.path) was '$actual', expected '$($case.kind)'"
        $passed++
    }

    # --- Checked-in inventories parse and describe the reviewed set ---------
    $realExpected = Get-CaelestiaExpectedSigningInventory -SignedInventoryPath $signedInventoryPath `
        -VendorReviewPath $vendorReviewPath
    Assert-True (@($realExpected.signed).Count -eq 56) 'reviewed signed inventory has 56 entries'
    Assert-True (@($realExpected.qt).Count -eq 90) 'reviewed Qt supplier list has 90 entries'
    Assert-True (@($realExpected.signed) -contains 'payload/caelestia-capture.exe') 'reviewed inventory includes the capture host'
    Assert-True (@($realExpected.signed) -contains 'payload/DesktopTakeover.dll') 'reviewed inventory includes the supervisor'
    Assert-True (@($realExpected.signed) -contains 'payload/Caelestia-Update.ps1') 'reviewed inventory includes current maintenance scripts'
    $passed += 4

    # --- Synthetic bundle and disposable signing certificate ----------------
    $bundle = Join-Path $scratch 'caelestia-windows-fixture-windows-x64'
    $fixtureSigned = @(
        'Install-CaelestiaRelease.ps1',
        'payload/Start-Caelestia.ps1',
        'payload/caelestia-capture.exe',
        'payload/caelestia-coreplugin.dll',
        'payload/DesktopTakeover.dll',
        'payload/qml/Caelestia/Windows/caelestia-windowsplugin.dll'
    )
    $fixtureQt = @('payload/Qt6Core.dll', 'payload/plugins/platforms/qwindows.dll')
    New-FixtureText (Join-Path $bundle 'Install-CaelestiaRelease.ps1') 'Write-Output "fixture bootstrap"'
    New-FixtureText (Join-Path $bundle 'payload/Start-Caelestia.ps1') 'Write-Output "fixture launcher"'
    New-FixtureText (Join-Path $bundle 'payload/shell/shell.qml') '// fixture'
    foreach ($path in @('payload/caelestia-capture.exe', 'payload/caelestia-coreplugin.dll',
        'payload/DesktopTakeover.dll', 'payload/qml/Caelestia/Windows/caelestia-windowsplugin.dll',
        'payload/qs.exe', 'payload/m3shapes.dll', 'payload/Qt6Core.dll',
        'payload/plugins/platforms/qwindows.dll')) {
        New-FixturePe (Join-Path $bundle $path)
    }
    $fixtureInventories = Write-FixtureInventories (Join-Path $scratch 'reviewed') $fixtureSigned $fixtureQt
    Write-FixtureManifest $bundle
    $expected = Get-CaelestiaExpectedSigningInventory -SignedInventoryPath $fixtureInventories.Signed `
        -VendorReviewPath $fixtureInventories.Vendor
    $inventory = Get-CaelestiaSigningInventory $bundle
    Assert-True (@($inventory.ownedPe).Count -eq 4) 'inventory finds four first-party PE files'
    Assert-True (@($inventory.ownedPs1).Count -eq 2) 'inventory finds two first-party scripts'
    Assert-True (@($inventory.qtPe).Count -eq 2) 'inventory finds two Qt PE files'
    Assert-True (@($inventory.otherPe).Count -eq 2) 'inventory finds two third-party PE files'
    $completeness = Assert-CaelestiaReleaseCompleteness -Inventory $inventory -Expected $expected `
        -ManifestPath (Join-Path $bundle 'release.json')
    Assert-True ($completeness.signedFiles -eq 6 -and $completeness.qtFiles -eq 2) 'completeness reports the reviewed counts'
    Assert-True ($completeness.manifestFiles -eq (@($inventory.files).Count - 1)) 'manifest covers every bundle file except itself'
    $passed += 6

    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=Caelestia Fixture Publisher', $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
        $oids = [Security.Cryptography.OidCollection]::new()
        $null = $oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $true))
        $disposable = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
    } finally { $rsa.Dispose() }
    $pfx = $disposable.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'fixture')
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $pfx, 'fixture', [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    $store = [Security.Cryptography.X509Certificates.X509Store]::new($tempStoreName, 'CurrentUser')
    $store.Open('ReadWrite')
    $store.Add($certificate)
    Assert-True ($store.Certificates.Count -eq 1) 'disposable certificate is in the temporary store'
    $passed++

    foreach ($relative in $fixtureSigned) {
        $path = Join-Path $bundle $relative
        $null = Set-AuthenticodeSignature -LiteralPath $path -Certificate $certificate -HashAlgorithm SHA256
        $signed = Get-AuthenticodeSignature -LiteralPath $path
        Assert-True ($null -ne $signed.SignerCertificate) "fixture signature present on $relative"
        Assert-True ($signed.SignerCertificate.Subject -ceq 'CN=Caelestia Fixture Publisher') "fixture subject on $relative"
        # The disposable chain is untrusted by design: this proves the verifier
        # rejects a present-but-untrusted signature rather than accepting it.
        Assert-True ($signed.Status -cne 'Valid') "fixture chain is untrusted on $relative"
        $passed += 3
    }

    # --- Signature decisions ------------------------------------------------
    $timestamp = [pscustomobject]@{ Subject = 'CN=Example Timestamp Authority' }
    $projectSubject = 'CN=SignPath Foundation, O=SignPath Foundation'
    $good = [pscustomobject]@{
        Status = 'Valid'
        SignerCertificate = [pscustomobject]@{ Subject = $projectSubject }
        TimeStamperCertificate = $timestamp
    }
    $decision = Test-CaelestiaSignatureRecord $good -ExpectedSignerSubject $projectSubject -RequireTimestamp
    Assert-True $decision.ok 'valid timestamped publisher signature is accepted'
    $decision = Test-CaelestiaSignatureRecord $good -ExpectedSignerSubject 'CN=Someone Else' -RequireTimestamp
    Assert-True (-not $decision.ok -and ($decision.reasons -contains 'unexpected-signer')) 'wrong publisher is rejected'
    $lookalike = [pscustomobject]@{
        Status = 'Valid'
        SignerCertificate = [pscustomobject]@{ Subject = 'CN=SignPath Foundation Impostor, O=Example' }
        TimeStamperCertificate = $timestamp
    }
    $decision = Test-CaelestiaSignatureRecord $lookalike -ExpectedSignerSubject $projectSubject -RequireTimestamp
    Assert-True (-not $decision.ok -and ($decision.reasons -contains 'unexpected-signer')) 'lookalike publisher is rejected'
    $decision = Test-CaelestiaSignatureRecord $good -ExpectedSignerSubject 'CN=SignPath Foundation' -RequireTimestamp
    Assert-True (-not $decision.ok -and ($decision.reasons -contains 'unexpected-signer')) 'a subject prefix is not accepted'
    $noTimestamp = [pscustomobject]@{
        Status = 'Valid'
        SignerCertificate = [pscustomobject]@{ Subject = $projectSubject }
        TimeStamperCertificate = $null
    }
    $decision = Test-CaelestiaSignatureRecord $noTimestamp -ExpectedSignerSubject $projectSubject -RequireTimestamp
    Assert-True (-not $decision.ok -and ($decision.reasons -contains 'missing-timestamp')) 'missing timestamp is rejected'
    $decision = Test-CaelestiaSignatureRecord $null -ExpectedSignerSubject $projectSubject -RequireTimestamp
    Assert-True (-not $decision.ok -and ($decision.reasons -contains 'unsigned')) 'unsigned file is rejected'
    $passed += 6

    # --- Policy decisions with an injected provider -------------------------
    $validProvider = {
        param($Path)
        $leaf = Split-Path -Leaf $Path
        $subject = switch -Regex ($leaf) {
            '^(Qt6.*\.dll|qwindows\.dll)$' { 'CN=The QT Company Oy, O=The QT Company Oy, C=FI' }
            '^(caelestia-.*\.(dll|exe)|DesktopTakeover\.dll|Install-CaelestiaRelease\.ps1|Start-Caelestia\.ps1)$' { 'CN=SignPath Foundation, O=SignPath Foundation' }
            default { $null }
        }
        if (-not $subject) {
            return [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null; TimeStamperCertificate = $null }
        }
        [pscustomobject]@{
            Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $subject }
            TimeStamperCertificate = [pscustomobject]@{ Subject = 'CN=Example Timestamp Authority' }
        }
    }
    $stableResult = Test-CaelestiaSigningPolicy -Inventory $inventory -Channel stable `
        -ExpectedSignerSubject $projectSubject -SignatureProvider $validProvider
    Assert-True $stableResult.ok 'stable policy accepts signed first-party files and Qt signatures'
    Assert-True ($stableResult.checkedOwned -eq 6 -and $stableResult.checkedQt -eq 2) 'stable policy checked the expected file counts'
    $previewResult = Test-CaelestiaSigningPolicy -Inventory $inventory -Channel preview -SignatureProvider $validProvider
    Assert-True $previewResult.ok 'preview policy checks Qt signatures only'
    Assert-True ($previewResult.checkedOwned -eq 0) 'preview policy does not require first-party signatures'
    $passed += 4

    $unsignedQtProvider = {
        param($Path)
        $leaf = Split-Path -Leaf $Path
        if ($leaf -like 'Qt6*' -or $leaf -eq 'qwindows.dll') {
            return [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null; TimeStamperCertificate = $null }
        }
        [pscustomobject]@{
            Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=SignPath Foundation, O=SignPath Foundation' }
            TimeStamperCertificate = [pscustomobject]@{ Subject = 'CN=Example Timestamp Authority' }
        }
    }
    $previewFailure = Test-CaelestiaSigningPolicy -Inventory $inventory -Channel preview -SignatureProvider $unsignedQtProvider
    Assert-True (-not $previewFailure.ok) 'preview policy rejects a Qt DLL without a vendor signature'
    Assert-True (@($previewFailure.failures | Where-Object { $_.kind -eq 'qt-pe' }).Count -eq 2) 'both Qt files fail without a signature'
    $passed += 2

    $projectSignedThirdParty = {
        param($Path)
        [pscustomobject]@{
            Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=SignPath Foundation, O=SignPath Foundation' }
            TimeStamperCertificate = [pscustomobject]@{ Subject = 'CN=Example Timestamp Authority' }
        }
    }
    $thirdPartyFailure = Test-CaelestiaSigningPolicy -Inventory $inventory -Channel stable `
        -ExpectedSignerSubject $projectSubject -SignatureProvider $projectSignedThirdParty
    Assert-True (-not $thirdPartyFailure.ok) 'third-party file signed by the project is rejected'
    Assert-True (@($thirdPartyFailure.failures | Where-Object { $_.kind -eq 'other-pe' }).Count -eq 2) 'every third-party PE file is rejected'
    $passed += 2

    # --- Deleted reviewed files ---------------------------------------------
    $deletions = @(
        @{ name = 'capture'; path = 'payload/caelestia-capture.exe'; editManifest = $false }
        @{ name = 'supervisor'; path = 'payload/DesktopTakeover.dll'; editManifest = $true }
        @{ name = 'bootstrap'; path = 'Install-CaelestiaRelease.ps1'; editManifest = $true }
        @{ name = 'maintenance'; path = 'payload/Start-Caelestia.ps1'; editManifest = $true }
        @{ name = 'qt'; path = 'payload/Qt6Core.dll'; editManifest = $true }
    )
    foreach ($case in $deletions) {
        $copy = Join-Path $scratch ('deleted-' + $case.name)
        Copy-Item -LiteralPath $bundle -Destination $copy -Recurse
        Remove-Item -LiteralPath (Join-Path $copy $case.path.Replace('/', '\')) -Force
        if ($case.editManifest) { Remove-ManifestEntry $copy $case.path }
        $copyInventory = Get-CaelestiaSigningInventory $copy
        $threw = $false
        $message = ''
        try {
            $null = Assert-CaelestiaReleaseCompleteness -Inventory $copyInventory -Expected $expected `
                -ManifestPath (Join-Path $copy 'release.json')
        } catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        Assert-True $threw "missing $($case.name) fails completeness"
        Assert-True ($message.Contains($case.path)) "missing $($case.name) error names the file: $message"
        $passed += 2
    }

    # A file still on disk but removed from the manifest is also refused.
    $unlisted = Join-Path $scratch 'unlisted'
    Copy-Item -LiteralPath $bundle -Destination $unlisted -Recurse
    Remove-ManifestEntry $unlisted 'payload/shell/shell.qml'
    $threw = $false
    try {
        $null = Assert-CaelestiaReleaseCompleteness -Inventory (Get-CaelestiaSigningInventory $unlisted) `
            -Expected $expected -ManifestPath (Join-Path $unlisted 'release.json')
    } catch { $threw = $true }
    Assert-True $threw 'an unlisted bundle file fails completeness'
    $passed++

    # --- End-to-end verifier exit codes -------------------------------------
    $summary = Join-Path $scratch 'stable-summary.json'
    $ErrorActionPreference = 'Continue'
    $output = & $powershell -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-AuthenticodeSignatures.ps1') `
        -BundleRoot $bundle -Channel stable -ExpectedSignerSubject 'CN=Caelestia Fixture Publisher' `
        -SignedInventoryPath $fixtureInventories.Signed -VendorReviewPath $fixtureInventories.Vendor `
        -SummaryPath $summary 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-True ($code -eq 1) "stable verification exits 1 for an untrusted chain (was $code): $($output -join '; ')"
    Assert-True (($output -join "`n") -match 'signature-status') 'stable verification reports the signature status'
    Assert-True (Test-Path -LiteralPath $summary -PathType Leaf) 'verification writes a summary'
    $summaryDoc = Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
    Assert-True ($summaryDoc.passed -eq $false -and $summaryDoc.channel -ceq 'stable') 'summary records the failure'
    Assert-True ($summaryDoc.expectedSigned -eq 6 -and $summaryDoc.expectedQt -eq 2) 'summary records the reviewed file set'
    $passed += 5

    # A preview bundle with an unsigned Qt DLL must fail even though the
    # development channel does not require first-party signatures.
    $previewBundle = Join-Path $scratch 'preview'
    Copy-Item -LiteralPath $bundle -Destination $previewBundle -Recurse
    Set-Content -LiteralPath (Join-Path $previewBundle 'payload/Qt6Core.dll') -Value 'not a PE'
    $ErrorActionPreference = 'Continue'
    $output = & $powershell -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-AuthenticodeSignatures.ps1') `
        -BundleRoot $previewBundle -Channel preview `
        -SignedInventoryPath $fixtureInventories.Signed -VendorReviewPath $fixtureInventories.Vendor 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-True ($code -eq 1) "preview verification exits 1 for an unsigned Qt DLL (was $code): $($output -join '; ')"
    Assert-True (($output -join "`n") -match 'payload/Qt6Core\.dll') 'preview verification names the Qt file'
    $passed += 2

    Write-Output "PASS signing policy: $passed fixture assertions across channels, inventory completeness, exact publisher subjects, signatures and CLI exit codes."
} finally {
    if ($store) {
        try {
            foreach ($item in @($store.Certificates)) { $store.Remove($item) }
        } catch { }
        $store.Close()
    }
    if ($certificate) { $certificate.Dispose() }
    if ($null -ne $disposable) { $disposable.Dispose() }
    # The fixture store lives only in this user's registry. Delete only its own
    # key, never the trusted root or any other certificate store.
    if (Test-Path -LiteralPath $tempStoreKey) {
        if ($tempStoreKey -notmatch '^HKCU:\\Software\\Microsoft\\SystemCertificates\\CaelestiaSigningFixture-[0-9a-f]{32}$') {
            throw 'Unsafe fixture certificate store cleanup.'
        }
        Remove-Item -LiteralPath $tempStoreKey -Recurse -Force
    }
    $resolved = [IO.Path]::GetFullPath($scratch)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ($OutputRoot) {
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    } elseif ((Split-Path -Parent $resolved) -eq $parent -and (Split-Path -Leaf $resolved) -like 'caelestia-signing-fixture-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else {
        throw 'Unsafe signing fixture cleanup.'
    }
}
