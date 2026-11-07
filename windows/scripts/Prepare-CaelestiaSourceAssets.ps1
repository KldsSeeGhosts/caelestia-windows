<#
.SYNOPSIS
Prepares public source and supplier notices, or checks an assembled bundle.
.DESCRIPTION
No build, installation, signing, publication, authentication or desktop work.
The public reference assets supply recorded provenance and approved derived
notice bytes. They do not identify the new candidate or certify its licensing.
#>
[CmdletBinding(DefaultParameterSetName = 'Prepare')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][string]$OutputDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][string]$CacheDirectory,
    [Parameter(ParameterSetName = 'Prepare')][string]$SourceRoot,
    [Parameter(ParameterSetName = 'Prepare')][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceRevision,
    [Parameter(ParameterSetName = 'Prepare')][ValidateSet('Pinned', 'Integrated')][string]$CaptureLayout = 'Pinned',
    [Parameter(ParameterSetName = 'Prepare')][string]$IntegratedCapturePath,
    [Parameter(ParameterSetName = 'Prepare')][switch]$Offline,
    [Parameter(ParameterSetName = 'Prepare')][switch]$FetchSuppliersFromOrigin,
    [Parameter(Mandatory, ParameterSetName = 'Coverage')][string]$AssetsRoot,
    [Parameter(Mandatory, ParameterSetName = 'Coverage')][string]$BundleRoot,
    [Parameter(Mandatory, ParameterSetName = 'Coverage')][string]$CoverageOutputDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Coverage')][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedInventorySha256,
    [Parameter(Mandatory, ParameterSetName = 'Coverage')][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedManifestSha256
)

. (Join-Path $PSScriptRoot 'Caelestia-SourceAssets.ps1')
$recipePath = Join-Path $PSScriptRoot '..\release\source-assets.json'
$recipe = Get-Content -LiteralPath $recipePath -Raw | ConvertFrom-Json
if ($recipe.schema -cne 'caelestia-source-recipe' -or $recipe.version -ne 1) { throw 'Unsupported source recipe.' }

if ($PSCmdlet.ParameterSetName -eq 'Coverage') {
    $AssetsRoot = [IO.Path]::GetFullPath($AssetsRoot).TrimEnd('\')
    $BundleRoot = [IO.Path]::GetFullPath($BundleRoot).TrimEnd('\')
    Assert-SourceNoLinks $AssetsRoot
    Assert-SourceNoLinks $BundleRoot
    $inventoryPath = Join-Path $AssetsRoot 'component-inventory.json'
    Assert-SourceHash $inventoryPath $ExpectedInventorySha256
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    if ($inventory.schema -cne 'caelestia-component-inventory' -or $inventory.version -ne 1) { throw 'Invalid component inventory.' }
    if ($inventory.recipeSha256 -cne (Get-SourceRecipeHash $recipePath)) { throw 'Coverage requires the matching reviewed recipe rules.' }
    foreach ($project in $inventory.projects) {
        Assert-SourceRelativePath $project.bundle
        Assert-SourceHash (Join-Path (Join-Path $AssetsRoot 'project-source') $project.bundle) $project.sha256
    }
    foreach ($archive in $inventory.suppliers | Where-Object includedInSourceAsset) {
        Assert-SourceRelativePath $archive.path
        Assert-SourceHash (Join-Path (Join-Path $AssetsRoot 'supplier-source') $archive.path) $archive.sha256
    }
    foreach ($notice in $inventory.notices) {
        Assert-SourceRelativePath $notice.path
        Assert-SourceHash (Join-Path (Join-Path $AssetsRoot 'notices') $notice.path) $notice.sha256
    }
    Assert-SourceHash (Join-Path $BundleRoot 'release.json') $ExpectedManifestSha256
    # Use the checkout's existing verifier, never execute downloaded scripts.
    $null = & (Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1') -BundleRoot $BundleRoot `
        -VerifyOnly -ExpectedManifestSha256 $ExpectedManifestSha256
    $manifest = Get-Content -LiteralPath (Join-Path $BundleRoot 'release.json') -Raw | ConvertFrom-Json
    $files = @(Assert-SourcePayloadCoverage $inventory $manifest)
    $stagingRecord = @(Get-Content -LiteralPath (Join-Path $BundleRoot 'payload/shell/sources.json') -Raw | ConvertFrom-Json)
    foreach ($entry in $inventory.payloadRules.staged) {
        $match = @($stagingRecord | Where-Object staged -CEQ $entry.path.Substring('payload/shell/'.Length))
        if ($match.Count -ne 1 -or $match[0].source -cne $entry.sourcePath -or
            $match[0].sourceSha256.ToLowerInvariant() -cne $entry.sourceSha256) {
            throw "Staged source provenance differs from candidate: $($entry.path)"
        }
    }
    $inventory.payloadState = 'verified-original-bundle'
    $inventory | Add-Member -NotePropertyName application -NotePropertyValue ([ordered]@{
        manifestSha256 = $ExpectedManifestSha256; files = $files
        preparationInventorySha256 = $ExpectedInventorySha256
        limitation = 'Original bundle integrity and recorded source/notice coverage only; no installed or legal qualification.'
    })
    $CoverageOutputDirectory = [IO.Path]::GetFullPath($CoverageOutputDirectory).TrimEnd('\')
    Assert-SourceNoLinks $CoverageOutputDirectory
    foreach ($inputRoot in @($AssetsRoot, $BundleRoot, [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\'))) {
        if ($CoverageOutputDirectory -eq $inputRoot -or $CoverageOutputDirectory.StartsWith($inputRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $inputRoot.StartsWith($CoverageOutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Coverage output must be separate from its read-only inputs and checkout.'
        }
    }
    if (Test-Path -LiteralPath $CoverageOutputDirectory) { throw 'Coverage output must be new.' }
    [IO.Directory]::CreateDirectory($CoverageOutputDirectory) | Out-Null
    $finalInventory = Join-Path $CoverageOutputDirectory 'component-inventory.json'
    Write-SourceJson $finalInventory $inventory
    [IO.File]::WriteAllText((Join-Path $CoverageOutputDirectory 'SHA256SUMS'),
        ((Get-SourceHash $finalInventory) + "  component-inventory.json`n"), [Text.Encoding]::ASCII)
    Write-Output "SOURCE_COVERAGE_PASS files=$($files.Count) notices=$($inventory.notices.Count)"
    return
}

if (-not $SourceRoot) { $SourceRoot = Join-Path $PSScriptRoot '..\..' }
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory).TrimEnd('\')
foreach ($pair in @(@($OutputDirectory, $SourceRoot), @($CacheDirectory, $SourceRoot), @($OutputDirectory, $CacheDirectory))) {
    if ($pair[0] -eq $pair[1] -or $pair[0].StartsWith($pair[1] + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $pair[1].StartsWith($pair[0] + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source, output and cache must be separate nonoverlapping directories.'
    }
}
Assert-SourceNoLinks $OutputDirectory
Assert-SourceNoLinks $CacheDirectory
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Source asset output must be new; failed outputs are retained.' }
if (-not $SourceRevision) { $SourceRevision = (Invoke-SourceGit $SourceRoot @('rev-parse', 'HEAD')) -join '' }
$null = Invoke-SourceGit $SourceRoot @('cat-file', '-e', "$SourceRevision^{commit}")
$lock = Get-SourceGitJson $SourceRoot $SourceRevision 'windows/sources.lock.json'
if (-not $PSBoundParameters.ContainsKey('CaptureLayout') -and
    $lock.glazier.PSObject.Properties['representation'] -and $lock.glazier.representation -ceq 'in-tree') {
    $CaptureLayout = 'Integrated'
    $IntegratedCapturePath = [string]$lock.glazier.path
}
$toolchain = Get-SourceGitJson $SourceRoot $SourceRevision 'windows/toolchain.json'
$stageMap = Get-SourceGitJson $SourceRoot $SourceRevision 'windows/shell/sources.json'
$projects = @([ordered]@{ id = 'shell'; repository = $recipe.shellRepository; revision = $SourceRevision; root = $SourceRoot })
foreach ($name in @('quickshell', 'm3shapes', 'glazier')) {
    if ($name -eq 'glazier' -and $CaptureLayout -eq 'Integrated') { continue }
    $pin = $lock.$name
    Assert-SourceRelativePath $pin.path
    if ($pin.repository -notmatch '^https://github\.com/[^/]+/[^/]+\.git$' -or $pin.revision -cnotmatch '^[a-f0-9]{40}$') {
        throw "Invalid public source pin: $name"
    }
    $tree = (Invoke-SourceGit $SourceRoot @('ls-tree', $SourceRevision, '--', $pin.path)) -join ''
    if ($tree -cne "160000 commit $($pin.revision)`t$($pin.path)") { throw "Gitlink and source lock differ: $name" }
    $projects += [ordered]@{
        id = $(if ($name -eq 'quickshell') { 'backend' } elseif ($name -eq 'glazier') { 'capture' } else { $name })
        repository = $pin.repository; revision = $pin.revision; root = (Join-Path $SourceRoot $pin.path)
    }
}
$capture = Get-SourceCaptureInput $SourceRoot $SourceRevision $lock $CaptureLayout $IntegratedCapturePath
$captureRoot = $capture.root
$captureRevision = $capture.revision
$cargoPath = $capture.cargoPath
$captureLicenseRoot = $capture.licenseRoot
$cargo = (Invoke-SourceGit $captureRoot @('show', "${captureRevision}:$cargoPath")) -join "`n"
[IO.Directory]::CreateDirectory($CacheDirectory) | Out-Null
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$scratch = Join-Path $OutputDirectory 'work'
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$supplierPath = Get-SourceDownload $recipe.referenceAssets.supplier.url $recipe.referenceAssets.supplier.sha256 $CacheDirectory -Offline:$Offline
$appPath = Get-SourceDownload $recipe.referenceAssets.application.url $recipe.referenceAssets.application.sha256 $CacheDirectory -Offline:$Offline
$supplierZip = Open-SourceZip $supplierPath
$appZip = Open-SourceZip $appPath
try {
    $reference = Read-SourceZipJson $supplierZip 'SOURCE-MANIFEST.json'
    $referenceApp = Read-SourceZipJson $appZip 'release.json'
    if ($reference.schema -cne 'caelestia-supplier-corresponding-source' -or $reference.version -ne 1 -or
        $referenceApp.schema -cne 'caelestia-windows-release' -or $referenceApp.version -ne 1) { throw 'Unexpected public reference schema.' }
    Assert-SourceToolchain $toolchain $reference.toolchain
    Assert-SourceCargoCoverage $cargo $reference.archives
    $supplierRoot = Join-Path $OutputDirectory 'supplier-source'
    $projectRoot = Join-Path $OutputDirectory 'project-source'
    $noticeRoot = Join-Path $OutputDirectory 'notices'
    foreach ($directory in @($supplierRoot, $projectRoot, $noticeRoot)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $archives = @()
    $archiveLookup = @{}
    foreach ($archive in @($reference.archives) + @($reference.unbundledNoticeProvenance)) {
        Assert-SourceRelativePath $archive.path
        if ($archiveLookup.ContainsKey($archive.path)) { throw 'Duplicate supplier archive rule.' }
        $cacheFile = Join-Path $CacheDirectory $archive.sha256
        if (-not (Test-Path -LiteralPath $cacheFile) -and -not $FetchSuppliersFromOrigin -and
            @($reference.archives | Where-Object path -CEQ $archive.path).Count) {
            Copy-SourceZipEntry $supplierZip $archive.path $cacheFile $archive.sha256
        }
        $cacheFile = Get-SourceDownload $archive.url $archive.sha256 $CacheDirectory -Offline:$Offline
        if ((Get-Item -LiteralPath $cacheFile).Length -ne $archive.bytes) { throw "Supplier archive length differs: $($archive.path)" }
        $included = @($reference.archives | Where-Object path -CEQ $archive.path).Count -eq 1
        if ($included) {
            $target = Join-Path $supplierRoot $archive.path
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            Copy-Item -LiteralPath $cacheFile -Destination $target
            Assert-SourceHash $target $archive.sha256
        }
        $archiveLookup[$archive.path] = $cacheFile
        $archives += [ordered]@{
            path = $archive.path; url = $archive.url; sha256 = $archive.sha256; bytes = $archive.bytes
            includedInSourceAsset = $included; component = (Get-SourceSupplierId $archive.path)
            recordedLicenses = @($archive.licenses)
        }
    }
    # Extract the verbatim portion of the recorded notice recipe once per
    # archive. Derived notices remain exact public reviewed data, not a new
    # HTML/legal interpretation. Their original provenance is retained below.
    $rawRoots = @{}
    foreach ($group in @($reference.noticeProvenance | Where-Object derivation -CEQ 'verbatim bytes from supplier archive' | Group-Object sourceArchive)) {
        if (-not $archiveLookup.ContainsKey($group.Name)) { throw "Notice has no recorded source archive: $($group.Name)" }
        $raw = Join-Path $scratch ('raw-' + $rawRoots.Count)
        Export-SourceTarMembers $archiveLookup[$group.Name] @($group.Group.sourceMember) $raw
        $rawRoots[$group.Name] = $raw
    }
    $provenanceByPath = @{}
    foreach ($entry in $reference.noticeProvenance) {
        if (-not $entry.originalNotice.StartsWith('notices/', [StringComparison]::Ordinal)) { throw 'Unexpected notice prefix.' }
        $relative = $entry.originalNotice.Substring(8)
        Assert-SourceRelativePath $relative
        if ($provenanceByPath.ContainsKey($relative)) { throw 'Duplicate notice provenance.' }
        $provenanceByPath[$relative] = $entry
    }
    $notices = @()
    foreach ($notice in $referenceApp.supplementalNotices) {
        Assert-SourceRelativePath $notice.path
        $entry = $null
        $lookupPath = $notice.path
        if ($lookupPath -match 'sqlite3\.[ch]\.LICENSE\.txt$') { $lookupPath = $lookupPath -replace '\.LICENSE\.txt$', '' }
        if ($provenanceByPath.ContainsKey($lookupPath)) { $entry = $provenanceByPath[$lookupPath] }
        if (-not $entry -and $notice.path -notin @('NOTICE-PROVENANCE.md', 'README.txt')) { throw "Notice lacks source provenance: $($notice.path)" }
        $target = Join-Path $noticeRoot $notice.path
        $verbatim = $entry -and $entry.derivation -ceq 'verbatim bytes from supplier archive' -and
            $entry.sha256 -ceq $notice.sha256 -and $lookupPath -ceq $notice.path
        if ($verbatim) {
            $source = Join-Path $rawRoots[$entry.sourceArchive] $entry.sourceMember
            Assert-SourceHash $source $notice.sha256
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            Copy-Item -LiteralPath $source -Destination $target
        } else {
            Copy-SourceZipEntry $appZip ('payload/licenses/supplemental/' + $notice.path) $target $notice.sha256
        }
        Assert-SourceHash $target $notice.sha256
        $notices += [ordered]@{
            path = $notice.path; sha256 = $notice.sha256; component = (Get-SourceSupplierId $notice.path)
            materialization = $(if ($verbatim) { 'extracted-verbatim' } else { 'preserved-public-derived-notice' })
            provenance = $entry
        }
    }
    # Each original source member, including inputs to derived notices, must
    # still belong to a pinned archive. No guessed license-file discovery.
    foreach ($entry in $reference.noticeProvenance | Where-Object { $_.PSObject.Properties['sourceArchive'] }) {
        if (-not $archiveLookup.ContainsKey($entry.sourceArchive)) { throw 'Unrecorded notice source archive.' }
        if ($entry.derivation -ceq 'verbatim bytes from supplier archive') {
            Assert-SourceHash (Join-Path $rawRoots[$entry.sourceArchive] $entry.sourceMember) $entry.sha256
        }
    }
    $projectRecords = @()
    foreach ($project in $projects) {
        $bundleName = $project.id + '.bundle'
        $bundle = Join-Path $projectRoot $bundleName
        New-SourceBundle $project.root $project.revision $bundle (Join-Path $scratch $project.id)
        $projectRecords += [ordered]@{
            id = $project.id; repository = $project.repository; revision = $project.revision
            bundle = $bundleName; sha256 = (Get-SourceHash $bundle)
            verification = 'standalone bundle verify and fetch in an empty repository; exact commit checked'
            archiveConfiguration = (Get-SourceArchiveConfiguration $project.root)
        }
    }
    $projectNotices = @()
    $noticePairs = @(
        @('shell', 'LICENSE', 'payload/licenses/LICENSE'),
        @('shell', 'THIRD-PARTY-NOTICES.md', 'payload/licenses/THIRD-PARTY-NOTICES.md'),
        @('shell', 'windows/sources.lock.json', 'payload/licenses/sources.lock.json'),
        @('shell', 'windows/services/clipboard/upstream/LICENSE-MIT.txt', 'payload/licenses/Clipboard-Overlay-MIT.txt'),
        @('backend', 'LICENSE', 'payload/licenses/Quickshell-LICENSE'),
        @('backend', 'LICENSE-GPL', 'payload/licenses/GPL-3.0.txt'),
        @('backend', 'src/windows/third_party/material_color/LICENSE', 'payload/licenses/MaterialColor-LICENSE'),
        @('backend', 'src/windows/third_party/virtual_desktop/LICENSE', 'payload/licenses/Quickshell-third-party/virtual_desktop/LICENSE'),
        @('m3shapes', 'LICENSE', 'payload/licenses/M3Shapes-LICENSE')
    )
    $captureProject = if ($CaptureLayout -eq 'Pinned') { 'capture' } else { 'shell' }
    $noticePairs += ,@($captureProject, ($captureLicenseRoot + 'LICENSE'), 'payload/licenses/Glazier-LICENSE')
    $noticePairs += ,@($captureProject, ($captureLicenseRoot + 'THIRD_PARTY_NOTICES.md'), 'payload/licenses/Glazier-THIRD_PARTY_NOTICES.md')
    if ($CaptureLayout -eq 'Integrated' -and $lock.glazier.PSObject.Properties['representation'] -and
        $lock.glazier.representation -ceq 'in-tree') {
        $noticePairs += ,@('shell', ($captureLicenseRoot + 'ORIGIN.md'), 'payload/licenses/Caelestia-Capture-ORIGIN.md')
    }
    foreach ($pair in $noticePairs) {
        $project = @($projects | Where-Object id -CEQ $pair[0])[0]
        $object = (Invoke-SourceGit $project.root @('rev-parse', "$($project.revision):$($pair[1])")) -join ''
        # Git archive preserves bytes including line endings; shell pipelines
        # must not transcode copyright or license text.
        $tar = Join-Path $scratch 'notice.tar'
        $null = Invoke-SourceGit $project.root @('archive', '--format=tar', "--output=$tar", $project.revision, '--', $pair[1])
        $raw = Join-Path $scratch ('project-notice-' + $projectNotices.Count)
        Export-SourceTarMembers $tar @($pair[1]) $raw
        $projectNotices += [ordered]@{
            component = $pair[0]; sourcePath = $pair[1]; gitBlob = $object
            payloadPath = $pair[2]; sha256 = (Get-SourceHash (Join-Path $raw $pair[1]))
        }
    }
    $stagedByPath = @{}
    foreach ($property in $stageMap.PSObject.Properties) {
        Assert-SourceRelativePath $property.Name
        Assert-SourceRelativePath $property.Value
        $path = 'payload/shell/' + $property.Value
        if ($stagedByPath.ContainsKey($path)) { throw 'Duplicate candidate staging destination.' }
        $stagedByPath[$path] = [ordered]@{ path = $path; component = 'shell'; sourcePath = $property.Name }
    }
    foreach ($font in $lock.fonts) {
        foreach ($file in $font.files) {
            $p = $file.path -replace '^windows/', ''
            $path = 'payload/shell/' + $p
            if ($stagedByPath.ContainsKey($path) -and $stagedByPath[$path].sourcePath -cne $file.path) { throw 'Conflicting font staging destination.' }
            $stagedByPath[$path] = [ordered]@{
                path = $path; component = 'font-' + ($p.Split('/')[1]); sourcePath = $file.path; sha256 = $file.sha256
            }
            if ($file.path -match '/(LICENSE|OFL\.txt)$') {
                $projectNotices += [ordered]@{
                    component = 'font-' + $p.Split('/')[1]; sourcePath = $file.path; gitBlob = $null
                    payloadPath = 'payload/licenses/fonts/' + $p.Substring('assets/'.Length); sha256 = $file.sha256
                }
            }
        }
    }
    $stageSources = Join-Path $scratch 'staged-source-inputs'
    Export-SourceGitMembers $SourceRoot $SourceRevision @($stagedByPath.Values | ForEach-Object sourcePath) $stageSources $scratch
    foreach ($entry in $stagedByPath.Values) {
        $hash = Get-SourceHash (Join-Path $stageSources $entry.sourcePath)
        if ($entry.Contains('sha256') -and $entry.sha256 -cne $hash) { throw "Committed font checksum mismatch: $($entry.sourcePath)" }
        $entry['sourceSha256'] = $hash
        if ($entry.path -notin @('payload/shell/shell.qml', 'payload/shell/modules/bar/components/workspaces/Workspace.qml')) {
            $entry['sha256'] = $hash
        }
    }
    $staged = @($stagedByPath.Values | Sort-Object path)
    $owners = Get-SourceReferenceOwners $referenceApp.files
    $referenceRules = @($referenceApp.files | ForEach-Object {
        [ordered]@{ path = $_.path; component = $owners[$_.path]; sha256 = $_.sha256 }
    })
    if ($CaptureLayout -eq 'Integrated') {
        # Explicit product rename rule, not a wildcard for unknown payloads.
        $referenceRules = @($referenceRules | Where-Object path -cne 'payload/glazier.exe')
        $referenceRules += [ordered]@{ path = 'payload/caelestia-capture.exe'; component = 'capture'; sha256 = $null }
        foreach ($notice in $projectNotices | Where-Object payloadPath -eq 'payload/licenses/Caelestia-Capture-ORIGIN.md') {
            $referenceRules += [ordered]@{ path = $notice.payloadPath; component = 'capture'; sha256 = $notice.sha256 }
        }
    }
    $components = @()
    foreach ($project in $projectRecords) {
        $components += [ordered]@{ id = $project.id; role = 'runtime'; version = $project.revision; source = $project.repository; shipped = $null }
    }
    if ($CaptureLayout -eq 'Integrated') {
        $components += [ordered]@{ id = 'capture'; role = 'runtime'; version = $SourceRevision; source = $recipe.shellRepository; shipped = $null }
    }
    $components += [ordered]@{ id = 'qt'; role = 'runtime'; version = $toolchain.qtVersion; source = 'https://download.qt.io/'; shipped = $null }
    $components += @(Get-SourceSupplierComponents $archives $toolchain)
    foreach ($font in $lock.fonts) {
        $id = 'font-' + (($font.files[0].path -replace '^windows/', '').Split('/')[1])
        $fontVersion = if ($font.PSObject.Properties['revision']) { $font.revision } else { $font.release }
        $components += [ordered]@{
            id = $id; role = 'runtime'; version = $fontVersion; source = $font.repository; recordedLicenses = @($font.license); shipped = $null
        }
    }
    foreach ($id in @('schemeCli', 'materialyoucolor', 'pillow', 'python', 'microsoft-vc-runtime')) {
        $components += [ordered]@{
            id = $id; role = $(if ($id -eq 'microsoft-vc-runtime') { 'external-prerequisite' } else { 'optional' })
            version = $(if ($id -eq 'schemeCli') { $lock.schemeCli.revision } elseif ($id -in @('materialyoucolor', 'pillow')) { $lock.schemeCli.pythonPackages.$id } elseif ($id -eq 'python') { $toolchain.pythonVersion } else { $toolchain.runtimeMinimum })
            source = $(switch ($id) {
                schemeCli { $lock.schemeCli.repository }
                materialyoucolor { 'https://github.com/T-Dynamos/materialyoucolor-python' }
                pillow { 'https://github.com/python-pillow/Pillow' }
                python { 'https://www.python.org/' }
                microsoft-vc-runtime { 'https://aka.ms/vc14/vc_redist.x64.exe' }
            })
            shipped = $false
        }
    }
    foreach ($tool in @(
        @('llvm', $toolchain.clangVersion, $toolchain.downloads.llvm.url),
        @('cmake', $toolchain.cmakeVersion, 'https://cmake.org/'),
        @('ninja', $toolchain.ninjaVersion, 'https://ninja-build.org/'),
        @('cargo', $toolchain.cargoVersion, 'https://www.rust-lang.org/'),
        @('aqt', $toolchain.downloads.aqt.sha256, $toolchain.downloads.aqt.url)
    )) {
        $components += [ordered]@{ id = $tool[0]; role = 'build-only'; version = $tool[1]; source = $tool[2]; shipped = $false }
    }
    $inventory = [ordered]@{
        schema = 'caelestia-component-inventory'; version = 1; sourceRevision = $SourceRevision
        captureLayout = $CaptureLayout; integratedCapturePath = $IntegratedCapturePath
        recipeSha256 = (Get-SourceRecipeHash $recipePath); recipeHashFormat = 'sha256-utf8-lf'; toolchain = $toolchain
        sourceMaterialization = 'Git archive of exact commits with recorded Git text conversion; source and payload hashes must agree.'
        payloadState = 'not-supplied'; referenceAssets = $recipe.referenceAssets
        projects = $projectRecords; suppliers = $archives; notices = $notices; projectNotices = $projectNotices
        components = $components
        payloadRules = [ordered]@{ reference = $referenceRules; staged = $staged }
        decisions = @(
            'Recorded supplier/license expressions are data, not a new legal applicability decision.',
            'Conservative supplier source/notice inclusion does not assert that every embedded dependency is deployed.',
            'Any changed supplier version, Cargo graph, unknown file, derived notice or Qt bytes requires a bounded reviewed rule update.',
            'Integrated capture is maintained in the shell source bundle; source preparation is not native capture acceptance.'
        )
    }
    Write-SourceJson (Join-Path $OutputDirectory 'component-inventory.json') $inventory
    $inventoryHash = Get-SourceHash (Join-Path $OutputDirectory 'component-inventory.json')
    # Asset manifests refer to one inventory, rather than maintaining parallel
    # component/version/license declarations.
    foreach ($root in @($projectRoot, $supplierRoot)) {
        Write-SourceJson (Join-Path $root 'SOURCE-MANIFEST.json') ([ordered]@{
            schema = 'caelestia-source-asset'; version = 1; sourceRevision = $SourceRevision
            inventoryFile = 'component-inventory.json'; inventorySha256 = $inventoryHash
            kind = $(if ($root -eq $projectRoot) { 'project' } else { 'supplier' })
        })
        Copy-Item -LiteralPath (Join-Path $OutputDirectory 'component-inventory.json') -Destination $root
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\docs\RELEASE-RECIPE.md') -Destination (Join-Path $root 'RELEASE-RECIPE.md')
    }
    # Preserve the useful published replacement/build guidance verbatim.
    foreach ($root in @($projectRoot, $supplierRoot)) {
        $readme = Get-SourceZipEntry $supplierZip 'README.md'
        $inputStream = $readme.Open()
        $outputStream = [IO.File]::Create((Join-Path $root 'SUPPLIER-BUILD-AND-REPLACEMENT.md'))
        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
    }
    New-SourceZip $projectRoot (Join-Path $OutputDirectory 'project-source.zip')
    New-SourceZip $supplierRoot (Join-Path $OutputDirectory 'supplier-source.zip')
    $hashes = @('component-inventory.json', 'project-source.zip', 'supplier-source.zip') | ForEach-Object {
        (Get-SourceHash (Join-Path $OutputDirectory $_)) + '  ' + $_
    }
    [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'SHA256SUMS'), [string[]]$hashes, [Text.Encoding]::ASCII)
    Write-SourceJson (Join-Path $OutputDirectory 'execution.json') ([ordered]@{
        schema = 'caelestia-source-execution'; version = 1; sourceRevision = $SourceRevision
        gitVersion = ((Invoke-SourceGit $SourceRoot @('--version')) -join '')
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        supplierTransport = $(if ($FetchSuppliersFromOrigin) { 'origin-or-verified-cache' } else { 'public-release-or-verified-cache' })
        bundleCount = $projectRecords.Count; sourceArchiveCount = @($archives | Where-Object includedInSourceAsset).Count
        noticeCount = $notices.Count; verbatimNoticeCount = @($notices | Where-Object materialization -EQ 'extracted-verbatim').Count
        payloadQualification = 'not-run'; installedQualification = 'not-run'; legalCertification = 'not-claimed'
    })
    Write-Output "SOURCE_ASSETS_PASS bundles=$($projectRecords.Count) sources=$(@($archives | Where-Object includedInSourceAsset).Count) notices=$($notices.Count)"
} finally {
    $supplierZip.Dispose()
    $appZip.Dispose()
    # Intentionally retain all disposable work and failures. No recursive delete
    # of caller-selected paths, even on a failed download/extraction.
}
