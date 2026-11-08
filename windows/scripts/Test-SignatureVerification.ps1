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
      * the checked-in inventory against the installer payload script lists and
        the native outputs the packager consumes;
      * completeness against the reviewed inventories and release.json,
        including deleted capture host, supervisor, bootstrap, script and Qt DLL;
      * exact publisher subjects, including lookalike and .NET-encoded quoted or
        escaped CN/O rejections;
      * the reviewed Qt publisher identity, including lookalike, prefix,
        impostor-field and .NET-encoded quoted or escaped CN/O rejections;
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

# Every PowerShell file either assembler deploys or requires. This reads the
# checked-in scripts, so it fails when a payload script is added or removed
# without updating windows/release/signing-inventory.json (and the reverse).
function Get-InstallerScriptNames([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        [IO.Path]::GetFullPath($Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse $Path for the payload script list." }
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($node in $ast.FindAll({
                param($item)
                $item -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true)) {
        $value = [string]$node.Value
        if ($value -cmatch '^payload/[A-Za-z0-9._-]+\.ps1$') { $names.Add($value.Substring('payload/'.Length)) }
        elseif ($value -cmatch '^[A-Za-z0-9._-]+\.ps1$') { $names.Add($value) }
    }
    return @($names | Sort-Object -CaseSensitive -Unique)
}

# Literal payload PE paths the release installer requires. Expandable strings
# such as "payload/$captureExecutable" are resolved by the inventory names below.
function Get-InstallerPayloadPePaths([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        [IO.Path]::GetFullPath($Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse $Path for the payload PE list." }
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($node in $ast.FindAll({
                param($item)
                $item -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true)) {
        $value = [string]$node.Value
        if ($value -cmatch '^payload/[A-Za-z0-9._/-]+\.(exe|dll)$') { $paths.Add($value) }
    }
    return @($paths | Sort-Object -CaseSensitive -Unique)
}

# The read-only native build outputs New-CaelestiaRelease.ps1 packages. They are
# the only source of the first-party PE files, so this list cannot drift without
# a deliberate inventory update.
function Get-NativePackagerInputs([string]$Path) {
    $raw = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path))
    $start = $raw.IndexOf('function Get-NativeReleaseInputs')
    $end = $raw.IndexOf('$nativeInputs = Get-NativeReleaseInputs')
    if ($start -lt 0 -or $end -le $start) { throw 'Native packaging inputs moved; update the signing fixtures and inventory.' }
    return @([regex]::Matches($raw.Substring($start, $end - $start), '\$BuildRoot\\([^"'']+)') |
        ForEach-Object { $_.Groups[1].Value.Replace('\', '/') } |
        Sort-Object -CaseSensitive -Unique)
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
    Assert-True (@($realExpected.signed).Count -eq 58) 'reviewed signed inventory has 58 entries'
    Assert-True (@($realExpected.qt).Count -eq 90) 'reviewed Qt supplier list has 90 entries'
    Assert-True (@($realExpected.signed) -contains 'payload/caelestia-capture.exe') 'reviewed inventory includes the capture host'
    Assert-True (@($realExpected.signed) -contains 'payload/DesktopTakeover.dll') 'reviewed inventory includes the supervisor'
    Assert-True (@($realExpected.signed) -contains 'payload/Caelestia-Update.ps1') 'reviewed inventory includes current maintenance scripts'
    $passed += 4

    # --- Checked-in inventory versus the real payload lists -----------------
    # The two installers deploy different sets on purpose, so each list is
    # compared separately. A script dropped from either list fails here even
    # while the other installer still deploys it. The developer assembler
    # deploys two support scripts the release installer omits; the release
    # installer deploys itself, which the assembler does not.
    $inventoryPayloadScripts = @($realExpected.signed | Where-Object { $_ -cmatch '^payload/[^/]+\.ps1$' } |
        ForEach-Object { ($_ -split '/')[-1] } | Sort-Object -CaseSensitive -Unique)
    $buildOnlyScripts = @('Caelestia-Support.ps1', 'Export-CaelestiaSupport.ps1')
    $releaseOnlyScripts = @('Install-CaelestiaRelease.ps1')
    $buildScripts = @(Get-InstallerScriptNames (Join-Path $PSScriptRoot 'Install-Caelestia.ps1'))
    $releaseScripts = @(Get-InstallerScriptNames (Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'))
    Assert-True (($buildScripts -join '|') -ceq ($inventoryPayloadScripts -join '|')) `
        "the developer assembler script list differs from the signed inventory: $($buildScripts -join ', ')"
    $expectedReleaseScripts = @(@($inventoryPayloadScripts | Where-Object { $buildOnlyScripts -cnotcontains $_ }) +
        $releaseOnlyScripts | Sort-Object -CaseSensitive -Unique)
    Assert-True (($releaseScripts -join '|') -ceq ($expectedReleaseScripts -join '|')) `
        "the release installer script list differs from the signed inventory: $($releaseScripts -join ', ')"
    Assert-True (@($realExpected.signed) -ccontains 'Install-CaelestiaRelease.ps1') `
        'the signed inventory includes the release bootstrap script'
    $passed += 3

    # The native build supplies the first-party PE files. This fixture has no
    # build root: Build-Prototype.ps1 writes it to a caller-chosen directory.
    # It therefore checks the packager's literal input list (including the
    # install/qml directory) rather than a real file listing. A native output
    # renamed or removed under install/qml is caught only when the inventory or
    # this expected list changes with it. Check a real build with
    # Test-AuthenticodeSignatures.ps1 -BundleRoot once the bundle exists.
    $nativeInputs = Get-NativePackagerInputs (Join-Path $PSScriptRoot 'New-CaelestiaRelease.ps1')
    $expectedNative = @('install/DesktopTakeover.dll', 'install/caelestia-capture.exe', 'install/qml', 'quickshell/qs.exe') |
        Sort-Object -CaseSensitive
    Assert-True (($nativeInputs -join '|') -ceq (@($expectedNative) -join '|')) `
        "native packaging inputs changed without a signed-inventory update: $($nativeInputs -join ', ')"
    $signedPe = @($realExpected.signed | Where-Object { $_ -cmatch '\.(exe|dll)$' })
    Assert-True (@($signedPe | Where-Object { $_ -cin @('payload/caelestia-capture.exe', 'payload/DesktopTakeover.dll') }).Count -eq 2) `
        'the native capture host and supervisor are signed'
    $rootHelpers = @($signedPe | Where-Object { $_ -cmatch '^payload/caelestia-[^/]+\.dll$' })
    $libHelpers = @($signedPe | Where-Object { $_ -cmatch '^payload/qml/Caelestia/lib/caelestia-[^/]+\.dll$' })
    Assert-True ($rootHelpers.Count -gt 0 -and $rootHelpers.Count -eq $libHelpers.Count) `
        'the payload-root helper DLLs and their qml lib copies are the same set size'
    foreach ($helper in $rootHelpers) {
        $twin = 'payload/qml/Caelestia/lib/' + ($helper -split '/')[-1]
        Assert-True ($libHelpers -ccontains $twin) "helper DLL $helper has no qml lib copy in the inventory"
    }
    Assert-True (@($signedPe | Where-Object { $_ -cmatch '^payload/qml/' -and $_ -cnotmatch '^payload/qml/Caelestia/' }).Count -eq 0) `
        'the signed inventory owns no DLL outside the Caelestia QML tree'
    Assert-True (@($signedPe | Where-Object {
                $_ -cmatch '^payload/qml/Caelestia/' -and
                $_ -cnotmatch '^payload/qml/Caelestia/(.+/)?caelestia-[A-Za-z0-9._-]+plugin\.dll$' -and
                $_ -cnotmatch '^payload/qml/Caelestia/lib/caelestia-[A-Za-z0-9._-]+\.dll$'
            }).Count -eq 0) 'every signed QML module is a first-party Caelestia plugin or helper library'
    Assert-True ($realExpected.signed -cnotcontains 'payload/qs.exe' -and
        $realExpected.signed -cnotcontains 'payload/m3shapes.dll') `
        'the inventory leaves the upstream binary and m3shapes unsigned'
    foreach ($path in @(Get-InstallerPayloadPePaths (Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'))) {
        if ((Get-CaelestiaSigningKind $path) -ceq 'owned-pe') {
            Assert-True ($realExpected.signed -ccontains $path) `
                "the release installer requires first-party $path but the inventory omits it"
        } else {
            Assert-True ($realExpected.signed -cnotcontains $path) `
                "the release installer requires third-party $path but the inventory signs it"
        }
    }
    $passed += 5

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
    # The project publisher is an exact literal subject too. .NET keeps quoted
    # and escaped CN/O renderings distinct, so a certificate that only reuses
    # the approved values in another encoding is a different subject and fails.
    $encodedProjectSubjects = @(
        'CN="SignPath Foundation", O=SignPath Foundation'
        'CN=SignPath Foundation, O="SignPath Foundation"'
        'CN=SignPath \Foundation, O=SignPath Foundation'
        'CN=SignPath Foundation, O=SignPath \Foundation'
        'CN="SignPath Foundation, Impostor", O=SignPath Foundation'
    ) | ForEach-Object {
        [Security.Cryptography.X509Certificates.X500DistinguishedName]::new($_).Name
    }
    foreach ($encodedSubject in $encodedProjectSubjects) {
        $encodedRecord = [pscustomobject]@{
            Status = 'Valid'
            SignerCertificate = [pscustomobject]@{ Subject = $encodedSubject }
            TimeStamperCertificate = $timestamp
        }
        $decision = Test-CaelestiaSignatureRecord $encodedRecord -ExpectedSignerSubject $projectSubject -RequireTimestamp
        Assert-True (-not [string]::Equals($encodedSubject, $projectSubject, [StringComparison]::OrdinalIgnoreCase)) `
            "the encoded project subject differs from the reviewed literal: $encodedSubject"
        Assert-True (-not $decision.ok -and ($decision.reasons -contains 'unexpected-signer')) `
            "the encoded project subject is rejected: $encodedSubject"
        $passed += 2
    }
    $wrongCaseProject = 'CN=signpath foundation, O=SignPath Foundation'
    $decision = Test-CaelestiaSignatureRecord ([pscustomobject]@{
            Status = 'Valid'
            SignerCertificate = [pscustomobject]@{ Subject = $wrongCaseProject }
            TimeStamperCertificate = $timestamp
        }) -ExpectedSignerSubject $projectSubject -RequireTimestamp
    Assert-True (-not $decision.ok -and ($decision.reasons -contains 'unexpected-signer')) `
        'a differently cased project subject is rejected'
    $passed++
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

    # --- Reviewed Qt publisher identity -------------------------------------
    # The approved subjects are the ones measured with Get-AuthenticodeSignature
    # on the 90 reviewed Qt DLLs. Matching is the exact literal subject only, so
    # a suffix, shared prefix, unrelated organization, duplicate field or a
    # quoted/escaped rendering of the approved CN and O never passes.
    $approvedQtSubjects = @(Get-CaelestiaQtSignerSubjects)
    Assert-True ($approvedQtSubjects.Count -ge 1) 'the reviewed Qt subject list is not empty'
    foreach ($qtSubject in $approvedQtSubjects) {
        $decision = Test-CaelestiaSignatureRecord ([pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = $qtSubject }
                TimeStamperCertificate = $timestamp
            }) -QtVendorSigner -RequireTimestamp
        Assert-True $decision.ok "the reviewed Qt subject is accepted: $qtSubject"
    }
    $qtLookalikes = @(
        'CN=The QT Company Oy Impostor, O=Example'
        'CN=The QT Company Oy, O=The QT Company Oy Impostor'
        'CN=The QT Company Oy, O=Nominally The QT Company Oy'
        'CN=The QT Company OyX, O=The QT Company Oy'
        'CN=Qt, O=The QT Company Oy'
        'CN=The QT Company Oy'
        'The QT Company Oy'
        'CN=the qt company oy, O=The QT Company Oy'
        'CN="The QT Company Oy, Impostor", O=The QT Company Oy'
        'CN=The QT Company Oy\, Impostor, O=The QT Company Oy'
    )
    foreach ($qtSubject in $qtLookalikes) {
        Assert-True (-not (Test-CaelestiaQtSignerSubject $qtSubject)) "the Qt lookalike is rejected: $qtSubject"
    }
    # .NET keeps quoted and escaped CN/O values in the rendered subject. These
    # certificates reuse the approved values but are not the measured literal,
    # so both the identity check and the signature decision reject them.
    $encodedQtSubjects = @(
        'CN="The ""QT"" Company Oy", O=The QT Company Oy'
        'CN=The Q\T Company Oy, O=The QT Company Oy'
        'CN=The QT Company Oy, O="The ""QT"" Company Oy"'
        'CN=The QT Company Oy, O=The Q\T Company Oy'
        'CN="The ""QT"" Company Oy", O="The ""QT"" Company Oy"'
        'CN=The Q\T Company Oy, O=The Q\T Company Oy'
    ) | ForEach-Object {
        [Security.Cryptography.X509Certificates.X500DistinguishedName]::new($_).Name
    }
    foreach ($qtSubject in $encodedQtSubjects) {
        Assert-True (-not (Test-CaelestiaQtSignerSubject $qtSubject)) `
            "the encoded Qt subject is rejected: $qtSubject"
        $decision = Test-CaelestiaSignatureRecord ([pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = $qtSubject }
                TimeStamperCertificate = $timestamp
            }) -QtVendorSigner -RequireTimestamp
        Assert-True (-not $decision.ok -and ($decision.reasons -contains 'unexpected-signer')) `
            "the encoded Qt subject fails the signature decision: $qtSubject"
        $passed += 2
    }
    # A renewed Qt certificate, even with the same CN and O, is a new literal.
    # It must fail until a reviewed change adds the measured subject above.
    $reissuedQtSubject = 'CN=The QT Company Oy, O=The QT Company Oy, C=FI, SERIALNUMBER=9999999-9'
    Assert-True (-not (Test-CaelestiaQtSignerSubject $reissuedQtSubject)) `
        'a re-issued Qt certificate fails until its literal is reviewed'
    $passed += 1 + $approvedQtSubjects.Count + $qtLookalikes.Count + 1

    # --- Policy decisions with an injected provider -------------------------
    $validProvider = {
        param($Path)
        $leaf = Split-Path -Leaf $Path
        $subject = switch -Regex ($leaf) {
            '^(Qt6.*\.dll|qwindows\.dll)$' { $approvedQtSubjects[0] }
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

    # A lookalike Qt publisher must fail exactly like an unsigned Qt DLL, and a
    # bare prefix must not pass either.
    foreach ($qtImpostor in @(
            'CN=The QT Company Oy Impostor, O=Example'
            'CN=The QT Company Oy'
        )) {
        $qtImpostorSubject = $qtImpostor
        $qtImpostorProvider = {
            param($Path)
            $leaf = Split-Path -Leaf $Path
            $subject = if ($leaf -like 'Qt6*' -or $leaf -eq 'qwindows.dll') {
                $qtImpostorSubject
            } else {
                'CN=SignPath Foundation, O=SignPath Foundation'
            }
            [pscustomobject]@{
                Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $subject }
                TimeStamperCertificate = [pscustomobject]@{ Subject = 'CN=Example Timestamp Authority' }
            }
        }
        $impostorResult = Test-CaelestiaSigningPolicy -Inventory $inventory -Channel preview `
            -SignatureProvider $qtImpostorProvider
        Assert-True (-not $impostorResult.ok) "preview policy rejects the Qt impostor: $qtImpostorSubject"
        Assert-True (@($impostorResult.failures | Where-Object {
                    $_.kind -ceq 'qt-pe' -and $_.reasons -contains 'unexpected-signer'
                }).Count -eq 2) "both Qt DLLs fail with an unexpected signer: $qtImpostorSubject"
        $passed += 2
    }

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

    Write-Output "PASS signing policy: $passed fixture assertions across channels, inventory completeness and payload-list drift, exact publisher and Qt vendor identities, signatures and CLI exit codes."
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
