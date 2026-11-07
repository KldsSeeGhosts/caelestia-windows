[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $env:TEMP ('caelestia-source-test-' + [guid]::NewGuid().ToString('N'))))

. (Join-Path $PSScriptRoot 'Caelestia-SourceAssets.ps1')
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
Assert-SourceNoLinks $OutputDirectory
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Fixture output must be new.' }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$script:assertions = 0
$script:cases = 0
function Assert-Recipe([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
function Assert-RecipeRefused([scriptblock]$Action, [string]$Expected) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = "$_" }
    Assert-Recipe ($null -ne $caught -and $caught -match $Expected) "Expected refusal '$Expected'; got '$caught'"
}
function New-RecipeFixtureZip([string]$Path, [string[]]$Names) {
    $stream = [IO.File]::Create($Path)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Names) {
            $entry = $zip.CreateEntry($name)
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('disposable supplier fixture') } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}

foreach ($path in @('../escape', '/root', 'C:/escape', 'a\b', 'a//b', 'a/./b', 'CON.txt', 'a/NUL', 'a/trailing.', 'a/trailing ', 'a:stream', 'a/*')) {
    Assert-RecipeRefused { Assert-SourceRelativePath $path } 'Unsafe'
}
$script:cases++
foreach ($path in @('a/LICENSE', 'rust-src-1.0/library/vendor/a+b/LICENSE-MIT', 'font/Unicode-name.txt')) {
    Assert-SourceRelativePath $path
    Assert-Recipe $true 'Valid relative path'
}
$script:cases++

$file = Join-Path $OutputDirectory 'fixture.txt'
[IO.File]::WriteAllText($file, 'fixture', [Text.UTF8Encoding]::new($false))
$hash = Get-SourceHash $file
Assert-SourceHash $file $hash
Assert-RecipeRefused { Assert-SourceHash $file ('0' * 64) } 'wrong SHA256'
Assert-RecipeRefused { Assert-SourceHash (Join-Path $OutputDirectory 'missing') $hash } 'Missing'
$cache = Join-Path $OutputDirectory 'cache'
[IO.Directory]::CreateDirectory($cache) | Out-Null
Assert-RecipeRefused { Get-SourceDownload 'https://static.crates.io/missing' $hash $cache -Offline } 'offline cache'
Assert-RecipeRefused { Get-SourceDownload 'http://static.crates.io/missing' $hash $cache } 'HTTPS'
Assert-RecipeRefused { Get-SourceDownload 'https://user:secret@github.com/file' $hash $cache } 'HTTPS'
Copy-Item -LiteralPath $file -Destination (Join-Path $cache $hash)
Assert-Recipe ((Get-SourceDownload 'https://static.crates.io/fixture' $hash $cache -Offline) -eq (Join-Path $cache $hash)) 'Verified cache not reused'
[IO.File]::WriteAllText((Join-Path $cache $hash), 'changed cache')
Assert-RecipeRefused { Get-SourceDownload 'https://static.crates.io/fixture' $hash $cache -Offline } 'wrong SHA256'
$script:cases++

foreach ($test in @(@('traversal.zip', @('../escape')), @('duplicate.zip', @('a/LICENSE', 'a/LICENSE')),
    @('case-duplicate.zip', @('a/LICENSE', 'a/license')), @('separator-duplicate.zip', @('a/LICENSE', 'a\LICENSE')))) {
    $path = Join-Path $OutputDirectory $test[0]
    New-RecipeFixtureZip $path $test[1]
    Assert-RecipeRefused { $zip = Open-SourceZip $path; $zip.Dispose() } 'Unsafe|Duplicate'
}
$validZip = Join-Path $OutputDirectory 'valid.zip'
New-RecipeFixtureZip $validZip @('root/LICENSE')
$zip = Open-SourceZip $validZip
try {
    Assert-Recipe ((Get-SourceZipEntry $zip 'LICENSE').FullName -ceq 'root/LICENSE') 'Wrong ZIP member'
    Assert-RecipeRefused { Get-SourceZipEntry $zip 'NOTICE' } 'Missing'
    Assert-RecipeRefused { Copy-SourceZipEntry $zip 'LICENSE' (Join-Path $OutputDirectory 'wrong-notice') ('0' * 64) } 'wrong SHA256'
} finally { $zip.Dispose() }
$script:cases++

$linkedZipPath = Join-Path $OutputDirectory 'linked.zip'
New-RecipeFixtureZip $linkedZipPath @('root/LICENSE')
$linkedZip = [IO.Compression.ZipFile]::Open($linkedZipPath, [IO.Compression.ZipArchiveMode]::Update)
try { $linkedZip.Entries[0].ExternalAttributes = -1577123840 } finally { $linkedZip.Dispose() }
Assert-RecipeRefused { $zip = Open-SourceZip $linkedZipPath; $zip.Dispose() } 'Linked ZIP'
$script:cases++

$cargo = @'
version = 4
[[package]]
name = "fixture"
version = "1.2.3"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
'@
$archives = @([pscustomobject]@{ path = 'sources/crates/fixture-1.2.3.crate'; sha256 = 'a' * 64 })
Assert-SourceCargoCoverage $cargo $archives
Assert-RecipeRefused { Assert-SourceCargoCoverage $cargo @() } 'inventory differs'
Assert-RecipeRefused { Assert-SourceCargoCoverage ($cargo.Replace(('a' * 64), ('b' * 64))) $archives } 'not reviewed'
Assert-RecipeRefused { Assert-SourceCargoCoverage ($cargo.Replace('registry+https://github.com/rust-lang/crates.io-index', 'git+https://example.com/private')) $archives } 'Unreviewed Cargo'
$toolchain = [pscustomobject]@{ qtVersion = '1'; rustVersion = '2'; cli11Version = '3'; clangVersion = '4' }
$reference = [pscustomobject]@{ qt = '1'; rust = '2'; cli11 = '3'; llvm = '4' }
Assert-SourceToolchain $toolchain $reference
$toolchain.qtVersion = 'unreviewed'
Assert-RecipeRefused { Assert-SourceToolchain $toolchain $reference } 'rule update'
$script:cases++

$known = @{ 'payload/qs.exe' = 'backend'; 'payload/glazier.exe' = 'capture' }
$staged = @{ 'payload/shell/new.qml' = 'shell' }
Assert-Recipe ((Get-SourcePayloadOwner 'payload/qs.exe' $known $staged) -eq 'backend') 'Backend ownership'
Assert-Recipe ((Get-SourcePayloadOwner 'payload/shell/new.qml' $known $staged) -eq 'shell') 'New mapped QML ownership'
Assert-RecipeRefused { Get-SourcePayloadOwner 'payload/Qt6Unknown.dll' $known $staged } 'Unknown payload'
Assert-RecipeRefused { Get-SourcePayloadOwner 'payload/scheme/venv/python.exe' $known $staged } 'Unknown payload'
Assert-Recipe ((Get-SourceSupplierId 'sources/crates/a-b-1.2+spec.crate') -ceq 'crate-a-b-1.2+spec') 'Crate identity'
$supplierComponents = @(Get-SourceSupplierComponents @(
    [ordered]@{ component = 'crate-a-b-1.2+spec'; path = 'sources/crates/a-b-1.2+spec.crate'; url = 'https://static.crates.io/a'; recordedLicenses = @('MIT') },
    [ordered]@{ component = 'rust'; path = 'sources/rust/source.tar.xz'; url = 'https://static.rust-lang.org/a'; recordedLicenses = @('MIT', 'Apache-2.0') },
    [ordered]@{ component = 'rust'; path = 'sources/rust/std.tar.xz'; url = 'https://static.rust-lang.org/b'; recordedLicenses = @('MIT') }
) ([pscustomobject]@{ rustVersion = '1.0' }))
Assert-Recipe ($supplierComponents.Count -eq 2 -and $supplierComponents[0].id -ceq 'crate-a-b-1.2+spec' -and
    $supplierComponents[0].version -ceq '1.2+spec' -and $supplierComponents[1].source.Count -eq 2) 'Ordered supplier records lost their identity/version'
$script:cases++

$inventory = [pscustomobject]@{
    sourceRevision = 'a' * 40; projects = @([pscustomobject]@{ id = 'backend'; revision = 'b' * 40 })
    toolchain = [pscustomobject]@{ qtVersion = '6.0.0' }
    components = @(
        [pscustomobject]@{ id = 'backend'; role = 'runtime'; shipped = $null },
        [pscustomobject]@{ id = 'shell'; role = 'runtime'; shipped = $null },
        [pscustomobject]@{ id = 'qt'; role = 'runtime'; shipped = $null },
        [pscustomobject]@{ id = 'python'; role = 'optional'; shipped = $false }
    )
    notices = @([pscustomobject]@{ path = 'LICENSE'; sha256 = 'c' * 64 })
    projectNotices = @([pscustomobject]@{ payloadPath = 'payload/licenses/LICENSE'; sha256 = 'd' * 64 })
    payloadRules = [pscustomobject]@{
        reference = @(
            [pscustomobject]@{ path = 'payload/qs.exe'; component = 'backend'; sha256 = '0' * 64 },
            [pscustomobject]@{ path = 'payload/Qt6Core.dll'; component = 'qt'; sha256 = 'e' * 64 },
            [pscustomobject]@{ path = 'payload/licenses/LICENSE'; component = 'shell'; sha256 = 'd' * 64 },
            [pscustomobject]@{ path = 'payload/licenses/supplemental/LICENSE'; component = 'shell'; sha256 = 'c' * 64 },
            [pscustomobject]@{ path = 'payload/shell/stale.qml'; component = 'shell'; sha256 = 'f' * 64 }
        )
        staged = @([pscustomobject]@{ path = 'payload/shell/new.qml'; component = 'shell'; sha256 = 'f' * 64 })
    }
}
$manifest = [pscustomobject]@{
    sourceRevision = 'a' * 40; qtVersion = '6.0.0'
    dependencies = [pscustomobject]@{ quickshell = [pscustomobject]@{ revision = 'b' * 40 } }
    files = @(
        [pscustomobject]@{ path = 'payload/qs.exe'; sha256 = '1' * 64; size = 1 },
        [pscustomobject]@{ path = 'payload/Qt6Core.dll'; sha256 = 'e' * 64; size = 1 },
        [pscustomobject]@{ path = 'payload/licenses/LICENSE'; sha256 = 'd' * 64; size = 1 },
        [pscustomobject]@{ path = 'payload/licenses/supplemental/LICENSE'; sha256 = 'c' * 64; size = 1 },
        [pscustomobject]@{ path = 'payload/shell/new.qml'; sha256 = 'f' * 64; size = 1 }
    )
}
$covered = @(Assert-SourcePayloadCoverage $inventory $manifest)
Assert-Recipe ($covered.Count -eq 5) 'Coverage lost application files'
Assert-Recipe ($inventory.components[0].shipped -and -not $inventory.components[3].shipped) 'Optional absent component falsely shipped'
$manifest.sourceRevision = '0' * 40
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'candidate revisions differ'
$manifest.sourceRevision = 'a' * 40
$manifest.dependencies.quickshell.revision = '0' * 40
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'source mismatch'
$manifest.dependencies.quickshell.revision = 'b' * 40
$manifest.files[1].sha256 = '0' * 64
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'Unreviewed Qt'
$manifest.files[1].sha256 = 'e' * 64
$manifest.files[3].sha256 = '0' * 64
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'wrong packaged notice'
$manifest.files[3].sha256 = 'c' * 64
$manifest.files[2].sha256 = '0' * 64
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'wrong project notice'
$manifest.files[2].sha256 = 'd' * 64
$savedFiles = $manifest.files
$manifest.files = @($savedFiles | Where-Object path -notlike '*supplemental/*')
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'Missing.*packaged notice'
$manifest.files = @($savedFiles | Where-Object path -ne 'payload/shell/new.qml')
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'Missing candidate staged'
$manifest.files = $savedFiles + [pscustomobject]@{ path = 'payload/shell/stale.qml'; sha256 = 'f' * 64; size = 1 }
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'not in candidate staging map'
$manifest.files = $savedFiles + [pscustomobject]@{ path = 'payload/unknown.dll'; sha256 = 'f' * 64; size = 1 }
Assert-RecipeRefused { Assert-SourcePayloadCoverage $inventory $manifest } 'Unknown payload'
$manifest.files = $savedFiles
$script:cases++

$tarRoot = Join-Path $OutputDirectory 'supplier'
[IO.Directory]::CreateDirectory($tarRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $tarRoot 'LICENSE'), 'supplier legal text')
$tar = Join-Path $OutputDirectory 'supplier.tar'
& tar.exe -cf $tar -C $tarRoot LICENSE
if ($LASTEXITCODE -ne 0) { throw 'Fixture tar creation failed.' }
$extract = Join-Path $OutputDirectory 'extracted'
Export-SourceTarMembers $tar @('LICENSE') $extract
Assert-Recipe ((Get-SourceHash (Join-Path $extract 'LICENSE')) -eq (Get-SourceHash (Join-Path $tarRoot 'LICENSE'))) 'Verbatim notice extraction'
Assert-RecipeRefused { Export-SourceTarMembers $tar @('NOTICE') (Join-Path $OutputDirectory 'missing-tar') } 'Missing'
$linkTar = Join-Path $OutputDirectory 'linked.tar'
$tarBytes = [byte[]]::new(1536)
foreach ($field in @(@(0, 'NOTICE'), @(100, "0000777`0"), @(108, "0000000`0"), @(116, "0000000`0"),
    @(124, "00000000000`0"), @(136, "00000000000`0"), @(148, '        '), @(156, '2'), @(157, '../../outside'))) {
    $fieldBytes = [Text.Encoding]::ASCII.GetBytes($field[1])
    [Array]::Copy($fieldBytes, 0, $tarBytes, $field[0], $fieldBytes.Length)
}
$sum = 0
foreach ($byte in $tarBytes[0..511]) { $sum += $byte }
$check = [Text.Encoding]::ASCII.GetBytes([Convert]::ToString($sum, 8).PadLeft(6, '0') + "`0 ")
[Array]::Copy($check, 0, $tarBytes, 148, 8)
[IO.File]::WriteAllBytes($linkTar, $tarBytes)
Assert-RecipeRefused { Export-SourceTarMembers $linkTar @('NOTICE') (Join-Path $OutputDirectory 'linked-tar') } 'nonregular'
Assert-Recipe (-not (Test-Path -LiteralPath (Join-Path $OutputDirectory 'outside'))) 'Link fixture escaped'
$script:cases++

$gitRoot = Join-Path $OutputDirectory 'repo'
$null = & git init --quiet $gitRoot
if ($LASTEXITCODE -ne 0) { throw 'Fixture repository initialization failed.' }
[IO.File]::WriteAllText((Join-Path $gitRoot 'LICENSE'), 'disposable source')
$null = Invoke-SourceGit $gitRoot @('add', 'LICENSE')
$null = Invoke-SourceGit $gitRoot @('-c', 'user.name=Recipe Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'fixture')
$revision = (Invoke-SourceGit $gitRoot @('rev-parse', 'HEAD')) -join ''
$bundle = Join-Path $OutputDirectory 'fixture.bundle'
New-SourceBundle $gitRoot $revision $bundle (Join-Path $OutputDirectory 'bundle-work')
Assert-Recipe ((Get-Item -LiteralPath $bundle).Length -gt 0) 'Empty source bundle'
Assert-RecipeRefused { New-SourceBundle $gitRoot ('0' * 40) (Join-Path $OutputDirectory 'wrong.bundle') (Join-Path $OutputDirectory 'wrong-work') } 'Git operation failed'
$script:cases++

$captureRoot = Join-Path $gitRoot 'windows\capture'
[IO.Directory]::CreateDirectory($captureRoot) | Out-Null
foreach ($name in @('Cargo.lock', 'LICENSE', 'THIRD_PARTY_NOTICES.md')) {
    [IO.File]::WriteAllText((Join-Path $captureRoot $name), 'future integrated fixture')
}
$null = Invoke-SourceGit $gitRoot @('add', 'windows/capture')
$null = Invoke-SourceGit $gitRoot @('-c', 'user.name=Recipe Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'integrated capture fixture')
$integratedRevision = (Invoke-SourceGit $gitRoot @('rev-parse', 'HEAD')) -join ''
$pinLock = [pscustomobject]@{ glazier = [pscustomobject]@{ path = 'windows/deps/glazier'; revision = $revision } }
$pinned = Get-SourceCaptureInput $gitRoot $integratedRevision $pinLock 'Pinned' ''
Assert-Recipe ($pinned.revision -eq $revision -and $pinned.cargoPath -ceq 'Cargo.lock') 'Existing capture pin form changed'
$integrated = Get-SourceCaptureInput $gitRoot $integratedRevision $pinLock 'Integrated' 'windows/capture'
Assert-Recipe ($integrated.revision -eq $integratedRevision -and $integrated.cargoPath -ceq 'windows/capture/Cargo.lock') 'Future integrated source form failed'
Assert-RecipeRefused { Get-SourceCaptureInput $gitRoot $integratedRevision $pinLock 'Pinned' 'windows/capture' } 'explicit Integrated'
Assert-RecipeRefused { Get-SourceCaptureInput $gitRoot $revision $pinLock 'Integrated' 'windows/capture' } 'committed source directory'
$script:cases++

# Exercise the actual read-only entry point plus the existing release verifier.
# Files named .exe/.dll below contain inert generated text, never programs.
$bundleFixture = Join-Path $OutputDirectory 'coverage-bundle'
$assetFixture = Join-Path $OutputDirectory 'coverage-assets'
[IO.Directory]::CreateDirectory($bundleFixture) | Out-Null
[IO.Directory]::CreateDirectory($assetFixture) | Out-Null
$parseErrors = $null
$parseTokens = $null
$verifierAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'), [ref]$parseTokens, [ref]$parseErrors)
$requiredLoop = @($verifierAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'required'
}, $true))
Assert-Recipe ($parseErrors.Count -eq 0 -and $requiredLoop.Count -eq 1) 'Cannot read verifier required-file contract'
$requiredNames = @($requiredLoop[0].Condition.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -or
    $node -is [Management.Automation.Language.ExpandableStringExpressionAst]
}, $true) | ForEach-Object {
    if ($_ -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
        # Read the one known product-name seam without evaluating bundle code.
        Assert-Recipe ($_.Value -ceq 'payload/$captureExecutable' -and
            $_.NestedExpressions.Count -eq 1 -and
            $_.NestedExpressions[0] -is [Management.Automation.Language.VariableExpressionAst] -and
            $_.NestedExpressions[0].VariablePath.UserPath -ceq 'captureExecutable') 'Unknown dynamic required-file expression'
        'payload/glazier.exe'
    } else { $_.Value }
}) + @('payload/licenses/supplemental/fixture-LICENSE')
$header = "//@ pragma DataDir @CAELESTIA_PROFILE@/data`n//@ pragma StateDir @CAELESTIA_PROFILE@/state`n//@ pragma CacheDir @CAELESTIA_PROFILE@/cache`n"
foreach ($name in $requiredNames) {
    $target = Join-Path $bundleFixture $name
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    [IO.File]::WriteAllText($target, $(if ($name -ceq 'payload/shell/shell.qml') { $header + 'fixture' } else { 'inert generated fixture' }), [Text.UTF8Encoding]::new($false))
}
$shellHash = Get-SourceHash (Join-Path $bundleFixture 'payload/shell/shell.qml')
Write-SourceJson (Join-Path $bundleFixture 'payload/shell/sources.json') @([ordered]@{
    source = 'shell.qml'; staged = 'shell.qml'; sourceSha256 = $shellHash; stagedSha256 = $shellHash
})
$fixtureManifest = [ordered]@{
    schema = 'caelestia-windows-release'; version = 1; platform = 'windows-x64'; releaseId = 'source-fixture'
    sourceRevision = 'a' * 40; nativeSourceRevision = 'a' * 40; backendRevision = 'b' * 40; qtVersion = '6.0.0'
    dependencies = [ordered]@{
        quickshell = @{ revision = 'b' * 40 }; glazier = @{ revision = 'c' * 40 }; m3shapes = @{ revision = 'd' * 40 }
    }
    prerequisites = @{ visualCppRuntime = @{
        deployment = 'system'; architecture = 'x64'; minimumVersion = '14.44.35211.0'
        downloadUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
    } }
    relocation = 'profile-pragmas-v1'
    files = @($requiredNames | ForEach-Object {
        $item = Get-Item -LiteralPath (Join-Path $bundleFixture $_)
        [ordered]@{ path = $_; size = $item.Length; sha256 = (Get-SourceHash $item.FullName) }
    })
}
$fixtureOwners = Get-SourceReferenceOwners $fixtureManifest.files
$captureOwners = Get-SourceReferenceOwners @(
    @{ path = 'payload/caelestia-capture.exe' },
    @{ path = 'payload/licenses/Caelestia-Capture-ORIGIN.md' })
Assert-Recipe ($captureOwners['payload/caelestia-capture.exe'] -ceq 'capture' -and
    $captureOwners['payload/licenses/Caelestia-Capture-ORIGIN.md'] -ceq 'capture') 'First-party capture ownership was lost'
$fixtureProjects = @()
foreach ($id in @('shell', 'backend', 'capture', 'm3shapes')) {
    $fixtureBundle = Join-Path $assetFixture ('project-source/' + $id + '.bundle')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $fixtureBundle)) | Out-Null
    Copy-Item -LiteralPath $bundle -Destination $fixtureBundle
    $fixtureProjects += [ordered]@{
        id = $id; revision = $(switch ($id) { shell { 'a' * 40 } backend { 'b' * 40 } capture { 'c' * 40 } m3shapes { 'd' * 40 } })
        bundle = $id + '.bundle'; sha256 = (Get-SourceHash $fixtureBundle)
    }
}
$fixtureNotice = Join-Path $assetFixture 'notices/fixture-LICENSE'
[IO.Directory]::CreateDirectory((Split-Path -Parent $fixtureNotice)) | Out-Null
Copy-Item -LiteralPath (Join-Path $bundleFixture 'payload/licenses/supplemental/fixture-LICENSE') -Destination $fixtureNotice
$fixtureInventory = [ordered]@{
    schema = 'caelestia-component-inventory'; version = 1; sourceRevision = 'a' * 40
    recipeSha256 = (Get-SourceRecipeHash (Join-Path $PSScriptRoot '../release/source-assets.json'))
    payloadState = 'not-supplied'; projects = $fixtureProjects; suppliers = @()
    toolchain = @{ qtVersion = '6.0.0' }
    notices = @(@{ path = 'fixture-LICENSE'; sha256 = (Get-SourceHash $fixtureNotice) })
    projectNotices = @(@{ payloadPath = 'payload/licenses/LICENSE'; sha256 = (Get-SourceHash (Join-Path $bundleFixture 'payload/licenses/LICENSE')) })
    components = @(@('shell', 'backend', 'capture', 'm3shapes', 'qt', 'python') | ForEach-Object {
        [ordered]@{ id = $_; role = $(if ($_ -eq 'python') { 'optional' } else { 'runtime' }); shipped = $null }
    })
    payloadRules = [ordered]@{
        reference = @($fixtureManifest.files | ForEach-Object {
            [ordered]@{ path = $_.path; component = $fixtureOwners[$_.path]; sha256 = $_.sha256 }
        })
        staged = @(@{ path = 'payload/shell/shell.qml'; component = 'shell'; sourcePath = 'shell.qml'; sourceSha256 = $shellHash; sha256 = $shellHash })
    }
}
$fixtureManifestPath = Join-Path $bundleFixture 'release.json'
$fixtureInventoryPath = Join-Path $assetFixture 'component-inventory.json'
Write-SourceJson $fixtureManifestPath $fixtureManifest
Write-SourceJson $fixtureInventoryPath $fixtureInventory
$coverageArguments = @{
    AssetsRoot = $assetFixture; BundleRoot = $bundleFixture
    ExpectedManifestSha256 = (Get-SourceHash $fixtureManifestPath)
    ExpectedInventorySha256 = (Get-SourceHash $fixtureInventoryPath)
    CoverageOutputDirectory = (Join-Path $OutputDirectory 'coverage-result')
}
& (Join-Path $PSScriptRoot 'Prepare-CaelestiaSourceAssets.ps1') @coverageArguments
$coverageResult = Get-Content -LiteralPath (Join-Path $coverageArguments.CoverageOutputDirectory 'component-inventory.json') -Raw | ConvertFrom-Json
Assert-Recipe ($coverageResult.payloadState -ceq 'verified-original-bundle' -and $coverageResult.application.files.Count -eq $requiredNames.Count) 'Read-only coverage entry point failed'
Assert-Recipe (-not @($coverageResult.components | Where-Object id -eq 'python')[0].shipped) 'Read-only coverage falsely shipped Python'
$coverageArguments.CoverageOutputDirectory = Join-Path $OutputDirectory 'coverage-refused'
[IO.File]::WriteAllText($fixtureNotice, 'changed notice')
Assert-RecipeRefused { & (Join-Path $PSScriptRoot 'Prepare-CaelestiaSourceAssets.ps1') @coverageArguments } 'wrong SHA256'
Assert-Recipe (-not (Test-Path -LiteralPath $coverageArguments.CoverageOutputDirectory)) 'Rejected coverage created a final receipt'
$script:cases++

$zipRoot = Join-Path $OutputDirectory 'zip-input'
[IO.Directory]::CreateDirectory($zipRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $zipRoot 'a.txt'), 'stable')
$zipOne = Join-Path $OutputDirectory 'one.zip'
$zipTwo = Join-Path $OutputDirectory 'two.zip'
New-SourceZip $zipRoot $zipOne
[IO.File]::SetLastWriteTimeUtc((Join-Path $zipRoot 'a.txt'), [DateTime]::UtcNow.AddYears(-1))
New-SourceZip $zipRoot $zipTwo
Assert-Recipe ((Get-SourceHash $zipOne) -ceq (Get-SourceHash $zipTwo)) 'ZIP timestamp normalization failed'
$script:cases++
Write-SourceJson (Join-Path $OutputDirectory 'receipt.json') ([ordered]@{
    cases = $script:cases; assertions = $script:assertions; outcome = 'pass'
    scope = 'Disposable source, cache, extraction, manifest-rule and bundle fixtures; no installation or desktop.'
})
Write-Output "SOURCE_ASSETS_TEST_PASS cases=$script:cases assertions=$script:assertions"
