[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')][string]$ReleaseId,
    # Must not exist. Contains the extracted bundle, ZIP and external digests.
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$QtPrefix,
    [string]$VCRuntimeRoot
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Packaging requires 64-bit Windows PowerShell and the existing native build tools.'
}
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = Resolve-CaelestiaDirectory $BuildRoot
$OutputDirectory = Resolve-CaelestiaDirectory $OutputDirectory
foreach ($source in @($repoRoot, $BuildRoot)) {
    if ($OutputDirectory -eq $source -or $OutputDirectory.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $source.StartsWith($OutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release output must be separate from the checkout and read-only build.'
    }
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Release output already exists; choose a new directory.' }
Assert-CaelestiaNoReparsePoints $BuildRoot

function Invoke-ReleaseGit([string]$Root, [string[]]$Arguments) {
    $result = @(& git -C $Root @Arguments)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot establish exact release source provenance.' }
    return $result
}
if (Invoke-ReleaseGit $repoRoot @('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none')) {
    throw 'Release packaging requires a clean committed checkout, including initialized dependency worktrees.'
}
$revision = (Invoke-ReleaseGit $repoRoot @('rev-parse', 'HEAD')) -join ''
$build = Get-Content -LiteralPath "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json
if ($build.sourceDirty -ne $false -or $build.publicRelease -ne $true -or $build.sourceRevision -notmatch '^[a-f0-9]{40}$' -or
    -not $build.glazierBundled -or $build.qtVersion -notmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9._-]+)?$') {
    throw 'An exact clean production build record is required.'
}
$lock = Get-Content -LiteralPath "$repoRoot\windows\sources.lock.json" -Raw | ConvertFrom-Json
$dependencies = [ordered]@{}
foreach ($name in @('quickshell', 'm3shapes', 'glazier')) {
    $pin = $lock.$name
    $root = Join-Path $repoRoot $pin.path
    $actual = (Invoke-ReleaseGit $root @('rev-parse', 'HEAD')) -join ''
    if ($actual -ne $pin.revision -or (Invoke-ReleaseGit $root @('status', '--porcelain', '--untracked-files=all'))) {
        throw "Dependency $name must be clean at its production pin."
    }
    $recorded = if ($name -eq 'quickshell') { $build.backendRevision } else { $build.($name + 'Revision') }
    if ($recorded -ne $actual) { throw "The build and source disagree about $name." }
    $dependencies[$name] = [ordered]@{ repository = $pin.repository; revision = $actual }
}
$dependencies['schemeCli'] = [ordered]@{ repository = $lock.schemeCli.repository; revision = $lock.schemeCli.revision; pythonPackages = $lock.schemeCli.pythonPackages }
$dependencies['fonts'] = $lock.fonts
if ($revision -ne $build.sourceRevision) {
    # A later QML/docs/packaging-only commit may reuse the tested binaries.
    # Require ancestry and independently recheck the native-input exclusion;
    # the developer installer applies the same exclusion during assembly.
    $null = Invoke-ReleaseGit $repoRoot @('merge-base', '--is-ancestor', $build.sourceRevision, $revision)
    $changed = @(Invoke-ReleaseGit $repoRoot @('diff', '--name-only', $build.sourceRevision, $revision))
    if (@($changed | Where-Object {
        $_ -match '^plugin/|^cmake/|^windows/deps/|^windows/scripts/Build-|\.(cpp|hpp|h|c|cc|cmake|qrc)$|(^|/)(CMakeLists\.txt|Cargo\.toml|Cargo\.lock)$'
    }).Count) { throw 'Native inputs changed since this build; rebuild before packaging.' }
}
if (-not $QtPrefix) { $QtPrefix = [string]$build.qtPrefix }
if (-not $QtPrefix) { throw 'The matching Qt deployment prefix is required only on the packaging machine.' }
$QtPrefix = Resolve-CaelestiaDirectory $QtPrefix
if (-not $VCRuntimeRoot) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsRoot) { throw 'Cannot establish the matching Visual C++ runtime origin.' }
    $version = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $version) { throw 'Supply the matching x64 Visual C++ runtime directory.' }
    $VCRuntimeRoot = Join-Path $version.FullName 'x64\Microsoft.VC143.CRT'
}
$VCRuntimeRoot = Resolve-CaelestiaDirectory $VCRuntimeRoot
foreach ($source in @($QtPrefix, $VCRuntimeRoot) | Where-Object { $_ }) {
    if ($OutputDirectory -eq $source -or $OutputDirectory.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $source.StartsWith($OutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release output must be separate from deployment SDKs.'
    }
}

# Snapshot only the inputs consumed by the existing assembler. Never mutate,
# install into or copy raw build.json from the supplied read-only build tree.
function Get-NativeReleaseInputs {
    $files = @((Get-Item -LiteralPath "$BuildRoot\quickshell\qs.exe"),
        (Get-Item -LiteralPath "$BuildRoot\install\glazier.exe"))
    $files += @(Get-ChildItem -LiteralPath "$BuildRoot\install\qml" -File -Recurse)
    return @($files | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($BuildRoot.Length + 1).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
}
$nativeInputs = Get-NativeReleaseInputs
function Get-ReleaseVendorPrivacyExceptions([string]$PayloadRoot, [string]$ReviewPath,
    [string]$QtRoot, [string]$CrtRoot, [object[]]$NativeInputs) {
    $review = Get-Content -LiteralPath $ReviewPath -Raw | ConvertFrom-Json
    if ($review.schema -ne 'caelestia-vendor-privacy-review' -or $review.version -ne 1 -or -not $review.files) {
        throw 'Invalid vendor privacy review.'
    }
    $nativeHashes = @{}
    foreach ($inputRecord in $NativeInputs) { $nativeHashes[[string]$inputRecord.sha256] = $true }
    $exceptions = @{}
    foreach ($entry in $review.files) {
        $relative = [string]$entry.path
        $binaryReview = $relative -match '^[A-Za-z0-9_./-]+\.(dll|exe)$' -and $entry.origin -in @('qt', 'vcruntime')
        $sbomReview = $relative -match '^licenses/Qt-sbom/[A-Za-z0-9_.-]+\.(json|spdx)$' -and $entry.origin -eq 'qt-sbom'
        if ((-not $binaryReview -and -not $sbomReview) -or
            @($relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -or
            $entry.sha256 -notmatch '^[a-f0-9]{64}$' -or
            $exceptions.ContainsKey($relative) -or $nativeHashes.ContainsKey([string]$entry.sha256) -or
            $relative -match '^(qs\.exe|glazier\.exe|m3shapes\.dll|caelestia-windows\.dll|DesktopTakeover\.dll)$|^qml/(Caelestia|M3Shapes|Quickshell)(/|$)') {
            throw 'Vendor exceptions cannot cover project binaries or unsafe review entries.'
        }
        $deployed = Join-Path $PayloadRoot $relative
        if (-not (Test-Path -LiteralPath $deployed -PathType Leaf) -or
            (Get-FileHash -LiteralPath $deployed -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Vendor privacy review no longer matches deployed bytes: $relative"
        }
        $candidates = if ($entry.origin -eq 'qt') {
            @((Join-Path $QtRoot ('bin\' + (Split-Path -Leaf $relative))), (Join-Path $QtRoot $relative))
        } elseif ($entry.origin -eq 'qt-sbom') {
            @(Join-Path $QtRoot ('sbom\' + $relative.Substring('licenses/Qt-sbom/'.Length)))
        } elseif (-not $relative.Contains('/')) {
            @(Join-Path $CrtRoot $relative)
        } else { @() }
        $matchingOrigin = $false
        foreach ($candidate in $candidates | Select-Object -Unique) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $null = Resolve-CaelestiaDirectory (Split-Path -Parent $candidate)
            if ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Vendor privacy provenance must not traverse a linked file.'
            }
            if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq $entry.sha256) {
                $matchingOrigin = $true
                break
            }
        }
        if (-not $matchingOrigin) { throw "Vendor privacy exception has no matching SDK origin: $relative" }
        $exceptions[$relative] = $true
    }
    return $exceptions
}
function Get-ReleaseFilePrivacy([byte[]]$Bytes, [string]$Extension, [string[]]$PrivateRoots) {
    $texts = @([Text.Encoding]::UTF8.GetString($Bytes), [Text.Encoding]::Unicode.GetString($Bytes))
    if ($Bytes.Length -gt 1) { $texts += [Text.Encoding]::Unicode.GetString($Bytes, 1, $Bytes.Length - 1) }
    $sensitive = $false
    $genericPath = $false
    $keyWhitespace = '(?:\s|\\+[rn])*'
    $keyMaterial = '(?i)-----BEGIN (?:(?:RSA|EC|DSA|OPENSSH|ENCRYPTED) )?PRIVATE KEY-----' +
        $keyWhitespace + '(?:(?:[A-Za-z0-9+/=]' + $keyWhitespace + '){32,}|Proc-Type:' + $keyWhitespace + '4,ENCRYPTED)'
    foreach ($text in $texts) {
        # PEM format labels occur in public TLS parsers. Require key material
        # (or an encrypted-key preamble), including JSON-escaped newlines.
        if ($text -match $keyMaterial -or $text -match '(?i)(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}') {
            $sensitive = $true
        }
        if ($text -match '(?i)[A-Z]:[\\/]+Users[\\/]|/(Users|home)/[^/\s]+/|[A-Z]:[\\/][^\x00\r\n]*\.pdb\b') {
            $genericPath = $true
        }
        if ($Extension -in @('.dll', '.exe')) {
            foreach ($candidate in [regex]::Matches($text, '(?i)(?<![A-Za-z0-9])[A-Z]:[\\/][^\x00\r\n]{2,}')) {
                # Opaque instructions can decode to a drive prefix followed by
                # replacement/control characters. Still flag readable strings
                # and structured directory/file paths with an undecodable tail.
                if ($candidate.Value -notmatch '[\p{C}\ufffd]' -or
                    $candidate.Value -match '^(?i)[A-Z]:[\\/](?:[\p{L}\p{N}_. -]+[\\/]|[^<>:"|?*\x00-\x1f]*\.[A-Za-z0-9]{1,8}(?:$|[^\w]))') {
                    $genericPath = $true
                }
            }
        }
        foreach ($privateRoot in $PrivateRoots) {
            foreach ($spelling in @($privateRoot, $privateRoot.Replace('\', '/'), $privateRoot.Replace('\', '\\'))) {
                if ($text.IndexOf($spelling, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $sensitive = $true }
            }
        }
    }
    return [pscustomobject]@{ Sensitive = $sensitive; GenericPath = $genericPath }
}
$nativeBefore = $nativeInputs | ConvertTo-Json -Depth 6 -Compress
$scratch = Resolve-CaelestiaDirectory (Join-Path $env:TEMP ('caelestia-release-' + [guid]::NewGuid().ToString('N')))
$assemblyPrefix = Join-Path $scratch 'app'
$assemblyProfile = Join-Path $scratch 'profile'
$bundleName = "caelestia-windows-$ReleaseId-windows-x64"
$bundle = Join-Path $OutputDirectory $bundleName
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $arguments = @{
        BuildRoot = $BuildRoot; QtPrefix = $QtPrefix; Prefix = $assemblyPrefix
        ProfileRoot = $assemblyProfile; SourceRoot = $repoRoot
        NoIntegration = $true; SkipSchemeRuntime = $true
    }
    if ($VCRuntimeRoot) { $arguments.VCRuntimeRoot = $VCRuntimeRoot }
    # One production assembler, source map, font verifier, notice exporter,
    # windeployqt invocation and supervisor compiler for both delivery paths.
    & (Join-Path $PSScriptRoot 'Install-Caelestia.ps1') @arguments
    $runtime = Resolve-CaelestiaRuntimePrefix $assemblyPrefix
    Assert-CaelestiaNoReparsePoints $runtime
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    New-Item -ItemType Directory -Path $bundle | Out-Null
    Copy-Item -LiteralPath $runtime -Destination (Join-Path $bundle 'payload') -Recurse
    $payload = Join-Path $bundle 'payload'
    # The local install record is intentionally replaced, not redacted: none
    # of its machine-specific prefix, profile or identity fields are shipped.
    Remove-Item -LiteralPath "$payload\install.json"
    foreach ($pdb in @(Get-ChildItem -LiteralPath $payload -File -Recurse -Filter '*.pdb')) {
        Remove-Item -LiteralPath $pdb.FullName
    }
    $shellPath = Join-Path $payload 'shell\shell.qml'
    $shell = [IO.File]::ReadAllText($shellPath)
    $header = "//@ pragma DataDir $assemblyProfile\data`n//@ pragma StateDir $assemblyProfile\state`n//@ pragma CacheDir $assemblyProfile\cache`n"
    if (-not $shell.StartsWith($header, [StringComparison]::Ordinal) -or
        [regex]::Matches($shell, '(?m)^//@ pragma (DataDir|StateDir|CacheDir) ').Count -ne 3) {
        throw 'Production profile pragmas changed; refusing an unbounded relocation.'
    }
    $template = "//@ pragma DataDir @CAELESTIA_PROFILE@/data`n//@ pragma StateDir @CAELESTIA_PROFILE@/state`n//@ pragma CacheDir @CAELESTIA_PROFILE@/cache`n"
    [IO.File]::WriteAllText($shellPath, ($template + $shell.Substring($header.Length)), [Text.UTF8Encoding]::new($false))
    $sourcesPath = Join-Path $payload 'shell\sources.json'
    $sources = Get-Content -LiteralPath $sourcesPath -Raw | ConvertFrom-Json
    $shellEntries = @($sources | Where-Object { $_.staged -eq 'shell.qml' })
    if ($shellEntries.Count -ne 1) { throw 'Invalid production staging record.' }
    $shellEntries[0].stagedSha256 = (Get-FileHash -LiteralPath $shellPath -Algorithm SHA256).Hash
    $sources | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sourcesPath -Encoding UTF8
    Copy-Item -LiteralPath "$PSScriptRoot\Install-CaelestiaRelease.ps1", "$PSScriptRoot\Install.cmd" -Destination $bundle
    Copy-Item -LiteralPath "$repoRoot\windows\docs\INSTALL-RELEASE.md" -Destination $bundle
    # Empty deployment directories have no runtime content and therefore no
    # manifest record. Remove them before the validator rejects extra paths.
    foreach ($directory in @(Get-ChildItem -LiteralPath $payload -Directory -Recurse |
        Sort-Object { $_.FullName.Length } -Descending)) {
        if (-not (Get-ChildItem -LiteralPath $directory.FullName -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $directory.FullName
        }
    }

    if ((Get-NativeReleaseInputs | ConvertTo-Json -Depth 6 -Compress) -ne $nativeBefore) {
        throw 'The read-only native build changed during packaging.'
    }
    if (((Invoke-ReleaseGit $repoRoot @('rev-parse', 'HEAD')) -join '') -ne $revision -or
        (Invoke-ReleaseGit $repoRoot @('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none'))) {
        throw 'The production source changed during packaging.'
    }
    $vendorReviewPath = Join-Path $repoRoot 'windows\release\vendor-privacy-review.json'
    $vendorExceptions = Get-ReleaseVendorPrivacyExceptions $payload $vendorReviewPath $QtPrefix $VCRuntimeRoot $nativeInputs
    $files = @(Get-ChildItem -LiteralPath $bundle -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($bundle.Length + 1).Replace('\', '/')
            size = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    [ordered]@{
        schema = 'caelestia-windows-release'; version = 1; platform = 'windows-x64'
        releaseId = $ReleaseId; sourceRevision = $revision; nativeSourceRevision = $build.sourceRevision
        backendRevision = $build.backendRevision; qtVersion = $build.qtVersion
        dependencies = $dependencies; nativeInputs = $nativeInputs
        vendorPrivacyReviewSha256 = (Get-FileHash -LiteralPath $vendorReviewPath -Algorithm SHA256).Hash.ToLowerInvariant()
        relocation = 'profile-pragmas-v1'; signing = 'unsigned-preview'
        files = $files
    } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath "$bundle\release.json" -Encoding UTF8
    # Scan the manifest too. Never rewrite DLLs, fonts, SBOMs or notices to get
    # a distributable result. Report relative names, not matched identities.
    $privateRoots = @($repoRoot, $BuildRoot, $QtPrefix, $VCRuntimeRoot, $scratch,
        $env:USERPROFILE, $env:CARGO_HOME, $env:RUSTUP_HOME) | Where-Object { $_ }
    $privacyCandidates = @()
    foreach ($file in Get-ChildItem -LiteralPath $bundle -File -Recurse -Force) {
        $flags = Get-ReleaseFilePrivacy ([IO.File]::ReadAllBytes($file.FullName)) $file.Extension $privateRoots
        $relative = $file.FullName.Substring($bundle.Length + 1).Replace('\', '/')
        $reviewedVendor = $relative.StartsWith('payload/', [StringComparison]::Ordinal) -and
            $vendorExceptions.ContainsKey($relative.Substring(8))
        if ($flags.Sensitive -or ($flags.GenericPath -and -not $reviewedVendor)) { $privacyCandidates += $relative }
    }
    if ($privacyCandidates.Count) {
        throw ('Privacy-sensitive release candidates require inspection or a clean reproducible rebuild (no binary patching): ' + ($privacyCandidates -join ', '))
    }
    $manifestHash = (Get-FileHash -LiteralPath "$bundle\release.json" -Algorithm SHA256).Hash.ToLowerInvariant()
    $null = & "$bundle\Install-CaelestiaRelease.ps1" -BundleRoot $bundle -VerifyOnly -ExpectedManifestSha256 $manifestHash
    # Keep the directory's leaf in the ZIP, so extraction has one clear root.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $OutputDirectory ($bundleName + '.zip')
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
    $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$zipHash  $bundleName.zip" | Set-Content -LiteralPath ($zip + '.sha256') -Encoding ASCII
    "$manifestHash  release.json" | Set-Content -LiteralPath (Join-Path $OutputDirectory ($bundleName + '.manifest.sha256')) -Encoding ASCII
    Write-Output "Unsigned preview ZIP: $zip"
    Write-Output "ZIP SHA256: $zipHash"
    Write-Output "Manifest SHA256: $manifestHash"
} finally {
    # The scratch root was created by this invocation, never supplied by a
    # caller. A failed output is retained for inspection but has no ZIP digest.
    $safe = Resolve-CaelestiaDirectory $scratch
    if ((Split-Path -Parent $safe) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -or
        (Split-Path -Leaf $safe) -notmatch '^caelestia-release-[a-f0-9]{32}$') { throw 'Unsafe release assembly cleanup.' }
    Assert-CaelestiaNoReparsePoints $safe
    Remove-Item -LiteralPath $safe -Recurse -Force
}
