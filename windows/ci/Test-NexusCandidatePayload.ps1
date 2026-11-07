#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$SourceDataRoot,
    [Parameter(Mandatory)][string]$AssetsRoot
)
$ErrorActionPreference = 'Stop'
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
$doc = Read-CaelestiaStrictJsonFile "$CandidateDirectory\candidate.json" 1048576
$release = $doc.release
$trust = Read-CaelestiaStrictJsonFile "$PSScriptRoot\..\release\update-trust.json"
Assert-CaelestiaReleaseMetadata $release $trust 'development'
$bundle = $release.bundle
$zip = Join-Path $CandidateDirectory $bundle.name
if ((Get-Item -LiteralPath $zip).Length -ne $bundle.size -or
    (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant() -cne $bundle.sha256) { throw 'Candidate ZIP hash/size mismatch.' }
$root = Expand-CaelestiaUpdate $zip $OutputDirectory $bundle.root $bundle.entries $bundle.unpackedSize
# Execute only the checkout verifier, not a script supplied by the artifact.
$null = & "$PSScriptRoot\..\scripts\Install-CaelestiaRelease.ps1" -BundleRoot $root -VerifyOnly `
    -ExpectedManifestSha256 $release.manifestSha256
$manifest = Read-CaelestiaStrictJsonFile "$root\release.json" 16777216 -AllowUtf8Bom
$native = Read-CaelestiaStrictJsonFile "$CandidateDirectory\native-build.json" 1048576
$receipt = Read-CaelestiaStrictJsonFile "$CandidateDirectory\candidate-result.json" 1048576 -AllowUtf8Bom
$version = Read-CaelestiaVersion "$SourceDataRoot\windows\release\version.json"
if ($manifest.sourceRevision -cne $doc.sourceRevision -or $manifest.nativeSourceRevision -cne $doc.sourceRevision -or
    $manifest.releaseId -cne $release.buildVersion -or $manifest.backendRevision -cne $release.backendRevision -or
    $native.sourceRevision -cne $doc.sourceRevision -or $native.sourceDirty -ne $false -or
    $native.backendMode -cne 'pinned' -or $native.backendRevision -cne $release.backendRevision -or
    $native.nativeVersion -cne $version.version -or $manifest.appVersion -cne $version.version -or
    $native.versionFileSha256 -cne (Get-FileHash "$SourceDataRoot\windows\release\version.json").Hash.ToLowerInvariant() -or
    $manifest.profileSchema -ne 1 -or $native.publicRelease -ne $true -or $native.captureBundled -ne $true -or
    $native.pluginTests -ne $true) { throw 'Candidate native/source/version identity mismatch.' }
foreach ($field in $receipt.toolchain.actual.Keys) {
    if ($native.toolchain[$field] -cne $receipt.toolchain.actual[$field] -or
        $manifest.toolchain[$field] -cne $receipt.toolchain.actual[$field]) { throw 'Candidate toolchain differs from trusted receipt.' }
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
foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse -Force) {
    $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
    $flags = Get-ReleaseFilePrivacy ([IO.File]::ReadAllBytes($file.FullName)) $file.Extension @(
        $CandidateDirectory, $OutputDirectory, $SourceDataRoot, $env:USERPROFILE)
    $reviewed = $relative.StartsWith('payload/', [StringComparison]::Ordinal) -and $exceptions.ContainsKey($relative.Substring(8))
    if ($flags.Sensitive -or ($flags.GenericPath -and -not $reviewed)) { throw 'Candidate privacy scan refused publication.' }
}
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
Write-Output 'NEXUS_PAYLOAD_PASS same-tested-native/source/supplier/notice coverage; no install/native acceptance.'
