#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$SourceDataRoot,
    [Parameter(Mandatory)][string]$AssetsRoot,
    [switch]$Unsealed,
    [string]$NativeBuildRoot,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$payloadClock = [Diagnostics.Stopwatch]::StartNew()
$payloadTimings = [Collections.Generic.List[object]]::new()
$payloadTimingReady = $false
function Save-PayloadTiming([string]$Phase) {
    $payloadClock.Stop()
    $payloadTimings.Add([ordered]@{
        phase = $Phase; seconds = [Math]::Round($payloadClock.Elapsed.TotalSeconds, 6)
    })
    # Only fixed phase labels and wall times. Keep this outside the extracted
    # bundle and candidate assets, never in release metadata or verification.
    if ($payloadTimingReady -and (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        [ordered]@{ schemaVersion = 1; phases = @($payloadTimings.ToArray()) } |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $OutputDirectory 'verification-timing.json') -Encoding UTF8
    }
    $payloadClock.Restart()
}
. (Join-Path $PSScriptRoot '..\scripts\Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules
. "$PSScriptRoot\..\scripts\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\..\scripts\Caelestia-Update.ps1"
. "$PSScriptRoot\..\scripts\Caelestia-SourceAssets.ps1"
foreach ($name in @('CandidateDirectory', 'OutputDirectory', 'SourceDataRoot', 'AssetsRoot')) {
    Set-Variable -Name $name -Value (Resolve-CaelestiaDirectory (Get-Variable -Name $name -ValueOnly))
}
foreach ($path in @($CandidateDirectory, $OutputDirectory, $SourceDataRoot, $AssetsRoot)) {
    Assert-CaelestiaUpdatePath $path
    if (Test-Path -LiteralPath $path) { Assert-CaelestiaNoReparsePoints $path }
    elseif ($path -ne $OutputDirectory) { throw 'Missing payload verification input.' }
}
$documentName = if ($Unsealed) { 'unsealed.json' } else { 'candidate.json' }
$doc = Read-CaelestiaStrictJsonFile (Join-Path $CandidateDirectory $documentName) 1048576
$release = $doc.release
$trust = Read-CaelestiaStrictJsonFile "$PSScriptRoot\..\release\update-trust.json"
if ($Unsealed) {
    if (-not $NativeBuildRoot -or $doc.schema -cne 'caelestia-nexus-unsealed') { throw 'Missing early native inputs.' }
    Assert-CaelestiaFields $release.provenance @('runId', 'runAttempt')
    # Validate all static release fields with an in-memory copy. These two
    # placeholders never enter the handoff or signed metadata. Seal supplies
    # real evidence hashes only after independent exact-tested verification.
    $validationRelease = [Collections.Generic.Dictionary[string, object]]::new($release, [StringComparer]::Ordinal)
    $validationRelease['provenance'] = [Collections.Generic.Dictionary[string, object]]::new(
        $release.provenance, [StringComparer]::Ordinal)
    $validationRelease['provenance']['pairResultSha256'] = '0' * 64
    $validationRelease['provenance']['candidateReceiptSha256'] = '0' * 64
    Assert-CaelestiaReleaseMetadata $validationRelease $trust 'development'
} else {
    Assert-CaelestiaReleaseMetadata $release $trust 'development'
}
$bundle = $release.bundle
$zip = Join-Path $CandidateDirectory $bundle.name
if ((Get-Item -LiteralPath $zip).Length -ne $bundle.size -or
    (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant() -cne $bundle.sha256) { throw 'Candidate ZIP hash/size mismatch.' }
Save-PayloadTiming 'metadata-and-zip-hash'
$root = Expand-CaelestiaUpdate $zip $OutputDirectory $bundle.root $bundle.entries $bundle.unpackedSize
$payloadTimingReady = $true
Save-PayloadTiming 'zip-extraction'
# Execute only the checkout verifier, not a script supplied by the artifact.
$null = & "$PSScriptRoot\..\scripts\Install-CaelestiaRelease.ps1" -BundleRoot $root -VerifyOnly `
    -ExpectedManifestSha256 $release.manifestSha256
Save-PayloadTiming 'manifest-files'
$manifest = Read-CaelestiaStrictJsonFile "$root\release.json" 16777216 -AllowUtf8Bom
if ($Unsealed) {
    $NativeBuildRoot = Resolve-CaelestiaDirectory $NativeBuildRoot
    Assert-CaelestiaNoReparsePoints $NativeBuildRoot
    # build.json also contains local diagnostics. Read only for comparisons;
    # it is never copied to the public assets.
    $native = Read-CaelestiaStrictJsonFile "$NativeBuildRoot\logs\build.json" 1048576 -AllowUtf8Bom
    $receiptActual = $native.toolchain
} else {
$native = Read-CaelestiaStrictJsonFile "$CandidateDirectory\native-build.json" 1048576
# The producer receipt records fractional stage durations, which the
# integer-only strict reader rejects by design. Extract only the measured
# toolchain with the producer's own duplicate-key refusal, then compare that
# extract through the unchanged strict reader.
$receiptToolchain = Join-Path $OutputDirectory 'receipt-toolchain.json'
$extract = @'
import json, sys
def pairs(rows):
    seen = set()
    for key, _ in rows:
        if key.casefold() in seen:
            raise ValueError('ambiguous-json')
        seen.add(key.casefold())
    return dict(rows)
def constant(_):
    raise ValueError('invalid-json-number')
with open(sys.argv[1], encoding='utf-8-sig') as stream:
    receipt = json.load(stream, object_pairs_hook=pairs, parse_constant=constant)
actual = receipt['toolchain']['actual']
if not isinstance(actual, dict) or not actual or not all(
        type(value) is str or (type(value) is int and not isinstance(value, bool)) for value in actual.values()):
    raise ValueError('invalid-receipt-toolchain')
with open(sys.argv[2], 'x', encoding='utf-8') as output:
    json.dump(actual, output)
'@
& $Python -I -B -c $extract "$CandidateDirectory\candidate-result.json" $receiptToolchain
if ($LASTEXITCODE -ne 0) { throw 'Trusted receipt toolchain could not be read.' }
$receiptActual = Read-CaelestiaStrictJsonFile $receiptToolchain 1048576
}
$version = Read-CaelestiaVersion "$SourceDataRoot\windows\release\version.json"
$version.version = Get-CaelestiaSourceVersion (Resolve-Path "$PSScriptRoot\..\..").Path $doc.sourceRevision $Python
if ($manifest.sourceRevision -cne $doc.sourceRevision -or $manifest.nativeSourceRevision -cne $doc.sourceRevision -or
    $manifest.releaseId -cne $release.buildVersion -or $manifest.backendRevision -cne $release.backendRevision -or
    $native.sourceRevision -cne $doc.sourceRevision -or $native.sourceDirty -ne $false -or
    $native.backendMode -cne 'pinned' -or $native.backendRevision -cne $release.backendRevision -or
    $native.nativeVersion -cne $version.version -or $manifest.appVersion -cne $version.version -or
    $native.versionFileSha256 -cne (Get-FileHash "$SourceDataRoot\windows\release\version.json").Hash.ToLowerInvariant() -or
    $manifest.profileSchema -ne 1 -or $native.publicRelease -ne $true -or $native.captureBundled -ne $true -or
    $native.pluginTests -ne $true) { throw 'Candidate native/source/version identity mismatch.' }
foreach ($field in $receiptActual.Keys) {
    if ($native.toolchain[$field] -cne $receiptActual[$field] -or
        $manifest.toolchain[$field] -cne $receiptActual[$field]) { throw 'Candidate toolchain differs from trusted receipt.' }
}
if ($native.supervisor.sourceSha256 -ne (Get-FileHash "$root\payload\DesktopTakeover.cs").Hash -or
    $native.supervisor.assemblySha256 -ne (Get-FileHash "$root\payload\DesktopTakeover.dll").Hash) {
    throw 'Candidate supervisor differs from tested output/source.'
}
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if (-not $native.nativeInputs -or $native.nativeInputs.Count -ne $manifest.nativeInputs.Count) {
    throw 'Manifest differs from the pre-validation native output inventory.'
}
foreach ($inputRecord in $manifest.nativeInputs) {
    Assert-SourceRelativePath $inputRecord.path
    if (-not $seen.Add($inputRecord.path)) { throw 'Duplicate native input.' }
    $recorded = @($native.nativeInputs | Where-Object { $_.path -ceq $inputRecord.path })
    if ($recorded.Count -ne 1 -or $recorded[0].sha256 -cne $inputRecord.sha256) {
        throw 'Manifest differs from the pre-validation native output inventory.'
    }
    $relative = if ($inputRecord.path -ceq 'quickshell/qs.exe') { 'qs.exe' }
        elseif ($inputRecord.path -cin @('install/caelestia-capture.exe', 'install/DesktopTakeover.dll')) { $inputRecord.path.Substring(8) }
        elseif ($inputRecord.path.StartsWith('install/qml/', [StringComparison]::Ordinal)) { $inputRecord.path.Substring(8) }
        else { throw 'Unexpected native input ownership.' }
    if ((Get-FileHash -LiteralPath (Join-Path "$root\payload" $relative)).Hash.ToLowerInvariant() -cne $inputRecord.sha256) {
        throw 'Candidate differs from actual tested native input.'
    }
}
foreach ($required in @('quickshell/qs.exe', 'install/caelestia-capture.exe', 'install/DesktopTakeover.dll')) {
    if (-not $seen.Contains($required)) { throw 'Incomplete tested native inventory.' }
}
Save-PayloadTiming 'identity-and-native-inventory'
# Independently execute the existing assembler's pure privacy scanner. No
# artifact-supplied code or broad "supplier exemption" is loaded.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\scripts\New-CaelestiaRelease.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Privacy scanner source failed to parse.' }
$privacyFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ReleaseFilePrivacy'
}, $true)
if (-not $privacyFunction) { throw 'Missing reviewed privacy scanner.' }
. ([scriptblock]::Create($privacyFunction.Extent.Text))
$vendor = Read-CaelestiaStrictJsonFile "$SourceDataRoot\windows\release\vendor-privacy-review.json" 1048576 -AllowUtf8Bom
if ($vendor.schema -cne 'caelestia-vendor-privacy-review' -or $vendor.version -ne 1) { throw 'Invalid reviewed vendor privacy policy.' }
$exceptions = @{}
$nativeHashes = @($manifest.nativeInputs | ForEach-Object { $_.sha256.ToLowerInvariant() })
foreach ($entry in $vendor.files) {
    Assert-SourceRelativePath $entry.path
    $binary = $entry.path -cmatch '\A[A-Za-z0-9_./-]+\.(dll|exe)\z' -and $entry.origin -ceq 'qt'
    $sbom = $entry.path -cmatch '\Alicenses/Qt-sbom/[A-Za-z0-9_.-]+\.(json|spdx)\z' -and $entry.origin -ceq 'qt-sbom'
    if ((-not $binary -and -not $sbom) -or $exceptions.ContainsKey($entry.path) -or
        $entry.path -cmatch '\A(qs\.exe|caelestia-capture\.exe|glazier\.exe|m3shapes\.dll|DesktopTakeover\.dll|qml/(Caelestia|M3Shapes|Quickshell)/)' -or
        $entry.sha256 -cin $nativeHashes -or
        (Get-FileHash -LiteralPath (Join-Path "$root\payload" $entry.path)).Hash.ToLowerInvariant() -cne $entry.sha256) {
        throw 'Vendor privacy exemption differs from exact reviewed supplier bytes.'
    }
    $exceptions[$entry.path] = $true
}
. "$PSScriptRoot\..\scripts\Caelestia-ReleasePrivacy.ps1"
$privacyFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)
foreach ($flags in @(Invoke-CaelestiaReleasePrivacyScan -Files $privacyFiles -PrivateRoots @(
    $CandidateDirectory, $OutputDirectory, $SourceDataRoot, $env:USERPROFILE) `
    -ScannerDefinition ${function:Get-ReleaseFilePrivacy}.ToString())) {
    $relative = $flags.FullName.Substring($root.Length + 1).Replace('\', '/')
    $reviewed = $relative.StartsWith('payload/', [StringComparison]::Ordinal) -and $exceptions.ContainsKey($relative.Substring(8))
    if ($flags.Sensitive -or ($flags.GenericPath -and -not $reviewed)) { throw 'Candidate privacy scan refused publication.' }
}
Save-PayloadTiming 'privacy-scan'
$prepared = Read-CaelestiaStrictJsonFile "$CandidateDirectory\source-assets-inventory.json" 16777216 -AllowUtf8Bom
$final = Read-CaelestiaStrictJsonFile "$CandidateDirectory\component-inventory.json" 16777216 -AllowUtf8Bom
if ($prepared.recipeSha256 -cne (Get-SourceRecipeHash "$SourceDataRoot\windows\release\source-assets.json") -or
    $prepared.sourceRevision -cne $doc.sourceRevision -or $final.sourceRevision -cne $doc.sourceRevision -or
    $final.payloadState -cne 'verified-original-bundle' -or $final.application.manifestSha256 -cne $release.manifestSha256 -or
    $final.application.preparationInventorySha256 -cne (Get-FileHash "$CandidateDirectory\source-assets-inventory.json").Hash.ToLowerInvariant()) {
    throw 'Candidate source coverage provenance mismatch.'
}
# Existing coverage functions expect PSCustomObjects for their ordered
# provenance records, and run the same supplier/source/notice rules again.
$inventory = Get-Content "$CandidateDirectory\source-assets-inventory.json" -Raw | ConvertFrom-Json
$releaseManifest = Get-Content "$root\release.json" -Raw | ConvertFrom-Json
$files = @(Assert-SourcePayloadCoverage $inventory $releaseManifest)
if ($files.Count -ne $final.application.files.Count) { throw 'Final source coverage inventory mismatch.' }
for ($index = 0; $index -lt $files.Count; $index++) {
    $recorded = $final.application.files[$index]
    Assert-CaelestiaFields $recorded @('path', 'component', 'sha256', 'size')
    foreach ($field in @('path', 'component', 'sha256', 'size')) {
        if ($recorded[$field] -cne $files[$index][$field]) { throw 'Final source coverage row differs from original verified bundle.' }
    }
}
Save-PayloadTiming 'source-coverage'
foreach ($project in $prepared.projects) {
    Assert-SourceRelativePath $project.bundle
    $path = Join-Path "$AssetsRoot\project-source" $project.bundle
    Assert-SourceHash $path $project.sha256
    # Bundle verification is data validation, never checkout or supplied-code
    # execution. Run in an empty Git repository to reject prerequisites.
    $probe = Join-Path $AssetsRoot ('git-verify-' + [guid]::NewGuid().ToString('N'))
    & git init --quiet $probe
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize source bundle verifier.' }
    # Git emits its successful "is okay" diagnostic on stderr. Windows
    # PowerShell 5.1 turns redirected native stderr into ErrorRecords, so use
    # the exit code explicitly without a false terminating error on success.
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git -c core.hooksPath=NUL -C $probe bundle verify $path 2>&1 | Out-Null
        $bundleExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $priorPreference }
    if ($bundleExitCode -ne 0) { throw 'Source Git bundle is not self-contained.' }
    & git -C $probe fetch --quiet $path 'refs/heads/source:refs/heads/source'
    if ($LASTEXITCODE -ne 0 -or (& git -C $probe rev-parse refs/heads/source) -cne $project.revision) {
        throw 'Source Git bundle revision mismatch.'
    }
    $heads = @(& git bundle list-heads $path)
    if ($LASTEXITCODE -ne 0 -or $heads.Count -ne 1 -or $heads[0] -cne ($project.revision + ' refs/heads/source')) {
        throw 'Source Git bundle contains unreviewed extra refs.'
    }
}
Save-PayloadTiming 'project-git-bundles'
foreach ($supplier in $prepared.suppliers) {
    if ($supplier.includedInSourceAsset) {
        Assert-SourceRelativePath $supplier.path
        $path = Join-Path "$AssetsRoot\supplier-source" $supplier.path
        Assert-SourceHash $path $supplier.sha256
        if ((Get-Item -LiteralPath $path).Length -ne $supplier.bytes) { throw 'Supplier source size mismatch.' }
    }
}
foreach ($asset in @('project-source', 'supplier-source')) {
    $sourceManifest = Read-CaelestiaStrictJsonFile "$AssetsRoot\$asset\SOURCE-MANIFEST.json"
    if ($sourceManifest.sourceRevision -cne $doc.sourceRevision -or
        $sourceManifest.inventorySha256 -cne (Get-FileHash "$CandidateDirectory\source-assets-inventory.json").Hash.ToLowerInvariant()) {
        throw 'Source asset refers to a different prepared inventory.'
    }
}
Save-PayloadTiming 'supplier-hashes'
# Independently verify the release SBOM and sanitized package-lifecycle receipt
# that ship alongside the release ZIP as release assets.
$sbomPath = Join-Path $CandidateDirectory 'release.cdx.json'
$lifecyclePath = Join-Path $CandidateDirectory 'package-lifecycle-receipt.json'
foreach ($evidenceFile in @($sbomPath, $lifecyclePath)) {
    if (-not (Test-Path -LiteralPath $evidenceFile -PathType Leaf)) {
        throw "Missing required release evidence asset: $(Split-Path -Leaf $evidenceFile)"
    }
    Assert-CaelestiaNoReparsePoints $evidenceFile
}
$sbom = Read-CaelestiaStrictJsonFile $sbomPath 16777216 -AllowUtf8Bom
if ($sbom.bomFormat -cne 'CycloneDX' -or $sbom.specVersion -cne '1.6' -or
    $sbom.metadata.component.version -cne $release.buildVersion -or
    $sbom.metadata.component.hashes[0].content -cne $bundle.sha256) {
    throw 'Release SBOM does not match candidate release bundle.'
}
$lifecycle = Read-CaelestiaStrictJsonFile $lifecyclePath 1048576 -AllowUtf8Bom
if ($lifecycle.schema -cne 'caelestia-package-lifecycle-receipt' -or $lifecycle.version -ne 1 -or
    $lifecycle.package.name -cne $bundle.name -or $lifecycle.package.size -ne $bundle.size -or
    $lifecycle.package.sha256 -cne $bundle.sha256 -or
    $lifecycle.manifestSha256 -cne $release.manifestSha256 -or
    $lifecycle.qualification -cne 'component-offscreen-and-data-only-not-windows11-acceptance' -or
    -not $lifecycle.previousPackage -or -not $lifecycle.previousPackage.statement -or
    -not $lifecycle.cases -or @($lifecycle.cases | Where-Object { $_.outcome -cne 'pass' }).Count -gt 0) {
    throw 'Package lifecycle receipt does not match candidate release bundle.'
}
if ($lifecycle.previousPackage.synthesized) {
    if ($lifecycle.previousPackage.mode -cne 'synthesized-older-metadata-same-payload') {
        throw 'Synthesized previous-package lifecycle statement is invalid.'
    }
} else {
    if (-not $lifecycle.previousPackage.name -or -not ($lifecycle.previousPackage.size -gt 0) -or
        $lifecycle.previousPackage.sha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Previous-package lifecycle identity is incomplete.'
    }
}
foreach ($flags in @(Invoke-CaelestiaReleasePrivacyScan -Files @((Get-Item -LiteralPath $sbomPath), (Get-Item -LiteralPath $lifecyclePath)) `
    -PrivateRoots @($CandidateDirectory, $OutputDirectory, $SourceDataRoot, $env:USERPROFILE) `
    -ScannerDefinition ${function:Get-ReleaseFilePrivacy}.ToString())) {
    if ($flags.Sensitive -or $flags.GenericPath) {
        throw "Release evidence privacy scan refused publication: $(Split-Path -Leaf $flags.FullName)"
    }
}
Save-PayloadTiming 'release-evidence-receipts'
Write-Output 'NEXUS_PAYLOAD_PASS same-tested-native/source/supplier/notice coverage; no install/native acceptance.'
