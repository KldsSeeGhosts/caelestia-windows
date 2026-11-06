[CmdletBinding()]
param(
    [string]$BundleRoot,
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows'),
    [string]$ProfileRoot,
    [switch]$Restart,
    [switch]$Autostart,
    [switch]$NoIntegration,
    # Optional Python/CLI downloads are not part of the basic shell install.
    [switch]$PrepareSchemeRuntime,
    # Obtain this digest from trusted release metadata, not the extracted ZIP.
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
# Resolve in the body for Windows PowerShell -File, like the stable launcher.
if (-not $BundleRoot) { $BundleRoot = $PSScriptRoot }
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or
    $env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or [Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'Use 64-bit Windows PowerShell on Windows 11 x64.'
}

# Bootstrap deliberately has no imports, dot-sources, native processes or
# supplied-code execution until the complete bundle passes validation.
function Assert-ReleaseComponents([string[]]$Parts) {
    foreach ($part in $Parts) {
        if (-not $part -or $part -in @('.', '..') -or
            $part.IndexOfAny([char[]]@(':', '"', '<', '>', '|', '?', '*', '\', '/')) -ge 0 -or
            $part -match '[\x00-\x1f\x7f]|[. ]$|^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(\.|$)') {
            throw 'Unsafe release path component.'
        }
    }
}

function Assert-ReleaseDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:\\' -or $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) {
        throw 'Release, prefix and profile paths require local, non-root directories.'
    }
    Assert-ReleaseComponents $full.Substring(3).Split('\')
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Release paths must not traverse files, symlinks or reparse points.'
            }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $full
}

function Resolve-ReleaseFile([string]$Root, [string]$Relative) {
    if (-not $Relative -or $Relative.Contains('\') -or $Relative.StartsWith('/') -or
        $Relative.IndexOfAny([char[]]@(':', '"', '<', '>', '|', '?', '*')) -ge 0 -or
        $Relative -match '[\x00-\x1f\x7f]') { throw 'Invalid release manifest path.' }
    Assert-ReleaseComponents $Relative.Split('/')
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative.Replace('/', '\')))
    if (-not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Release path escapes its root.' }
    return $full
}

function Test-ReleaseVCRuntimeVersions([int]$Installed, [string]$RegisteredVersion,
    [version[]]$FileVersions, [version]$MinimumVersion) {
    if ($Installed -ne 1 -or $RegisteredVersion -notmatch '^v?\d+\.\d+\.\d+\.\d+$' -or
        $FileVersions.Count -ne 3) { return $false }
    if ([version]($RegisteredVersion -replace '^v', '') -lt $MinimumVersion) { return $false }
    return @($FileVersions | Where-Object { $null -eq $_ -or $_ -lt $MinimumVersion }).Count -eq 0
}

function Test-ReleaseVCRuntime([version]$MinimumVersion) {
    $baseKey = $null
    $runtimeKey = $null
    try {
        # Read the native x64 registration, never PATH or a developer SDK.
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $runtimeKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')
        if (-not $runtimeKey) { return $false }
        $versions = foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
            $file = Join-Path ([Environment]::SystemDirectory) $name
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($file)
            [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
        }
        return Test-ReleaseVCRuntimeVersions ([int]$runtimeKey.GetValue('Installed', 0)) `
            ([string]$runtimeKey.GetValue('Version', '')) $versions $MinimumVersion
    } catch { return $false }
    finally {
        if ($runtimeKey) { $runtimeKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Test-ReleaseBundle([string]$Root, [string]$ExpectedHash = '') {
    $Root = Assert-ReleaseDirectory $Root
    # Enumerate manually, without following junctions even once. This also
    # rejects unlisted files (including hidden files), not just missing files.
    $actual = @{}
    $directories = @{}
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release contains a symlink or reparse point.' }
            $relative = $item.FullName.Substring($Root.Length + 1).Replace('\', '/')
            $null = Resolve-ReleaseFile $Root $relative
            if ($actual.ContainsKey($relative) -or $directories.ContainsKey($relative)) { throw 'Release contains case-colliding paths.' }
            if ($item.PSIsContainer) { $directories[$relative] = $true; $pending.Push($item.FullName) }
            else { $actual[$relative] = $item }
        }
    }
    if (-not $actual.ContainsKey('release.json')) { throw 'Missing release.json.' }
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $Root 'release.json') -Algorithm SHA256).Hash
    if ($ExpectedHash -and $manifestHash -ne $ExpectedHash) { throw 'Release manifest digest differs from trusted metadata.' }
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'release.json') -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 'caelestia-windows-release' -or $manifest.version -ne 1 -or
        $manifest.platform -ne 'windows-x64' -or $manifest.sourceRevision -notmatch '^[a-f0-9]{40}$' -or
        $manifest.nativeSourceRevision -notmatch '^[a-f0-9]{40}$' -or $manifest.backendRevision -notmatch '^[a-f0-9]{40}$' -or
        $manifest.releaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
        $manifest.dependencies.quickshell.revision -ne $manifest.backendRevision -or
        $manifest.dependencies.glazier.revision -notmatch '^[a-f0-9]{40}$' -or
        $manifest.dependencies.m3shapes.revision -notmatch '^[a-f0-9]{40}$' -or
        $manifest.prerequisites.visualCppRuntime.deployment -ne 'system' -or
        $manifest.prerequisites.visualCppRuntime.architecture -ne 'x64' -or
        $manifest.prerequisites.visualCppRuntime.minimumVersion -ne '14.44.35211.0' -or
        $manifest.prerequisites.visualCppRuntime.downloadUrl -ne 'https://aka.ms/vc14/vc_redist.x64.exe' -or
        -not $manifest.files -or $manifest.relocation -ne 'profile-pragmas-v1') {
        throw 'Unsupported or incomplete release manifest.'
    }
    $listed = @{}
    $parents = @{}
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.path
        $path = Resolve-ReleaseFile $Root $relative
        # Supplier notice trees preserve upstream attribution paths, including
        # licenses from upstream tests. They are data, never runtime test wiring.
        $supplementalNotice = $relative.StartsWith('payload/licenses/supplemental/', [StringComparison]::Ordinal)
        if ($relative -eq 'release.json' -or $listed.ContainsKey($relative) -or
            (-not $relative.StartsWith('payload/', [StringComparison]::Ordinal) -and $relative -notin @('Install.cmd', 'Install-CaelestiaRelease.ps1', 'INSTALL-RELEASE.md')) -or
            $relative -match '(^|/)(\.git|\.zcode|screenshots?|evidence)(/|$)|\.pdb$|^payload/(install\.json|build\.json|versions|profile|config|runtime|logs?|cache|state|data)(/|$)' -or
            ($relative -match '(^|/)tests?(/|$)' -and -not $supplementalNotice) -or
            ($supplementalNotice -and [IO.Path]::GetExtension($relative) -in @('.exe', '.dll', '.pdb', '.zip', '.7z', '.tar', '.xz')) -or
            $relative -match '(^|/)((concrt|msvcp|msvcr|vccorlib|vcruntime)\d[^/]*\.dll|ucrtbase(?:d)?\.dll|api-ms-win-crt-[^/]*\.dll|vc_redist[^/]*\.exe)$' -or
            [string]$entry.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            ($entry.size -isnot [long] -and $entry.size -isnot [int])) { throw 'Invalid or duplicate release file record.' }
        if (-not $actual.ContainsKey($relative) -or $actual[$relative].Length -ne $entry.size -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Missing, partial or corrupt release file: $relative"
        }
        $listed[$relative] = $true
        $parent = $relative
        while ($parent.Contains('/')) {
            $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
            $parents[$parent] = $true
        }
    }
    if ($actual.Count -ne $listed.Count + 1) { throw 'Release contains unlisted files.' }
    foreach ($directory in $directories.Keys) {
        if (-not $parents.ContainsKey($directory)) { throw 'Release contains an unlisted directory.' }
    }
    foreach ($required in @(
        'Install.cmd', 'Install-CaelestiaRelease.ps1', 'INSTALL-RELEASE.md',
        'payload/qs.exe', 'payload/glazier.exe', 'payload/qt.conf',
        'payload/Qt6Core.dll', 'payload/Qt6Qml.dll', 'payload/Qt6Quick.dll',
        'payload/plugins/platforms/qwindows.dll', 'payload/qml/Caelestia/Windows/qmldir',
        'payload/qml/M3Shapes/qmldir', 'payload/m3shapes.dll', 'payload/shell/shell.qml',
        'payload/shell/sources.json', 'payload/defaults/shell.json', 'payload/defaults/windows.json',
        'payload/defaults/keybinds.json', 'payload/DesktopTakeover.dll', 'payload/DesktopTakeover.build.json',
        'payload/Start-Caelestia.ps1', 'payload/Start-CaelestiaEntry.ps1',
        'payload/Manage-Caelestia.ps1', 'payload/Uninstall-Caelestia.ps1',
        'payload/Caelestia-InstallCommon.ps1', 'payload/Caelestia-Versions.ps1',
        'payload/Start-DesktopShell.ps1', 'payload/Watch-DesktopShell.ps1', 'payload/Restore-Desktop.ps1',
        'payload/Install-SchemeRuntime.ps1', 'payload/Get-AccountPicture.ps1', 'payload/Banner-Suppression.ps1',
        'payload/scheme/requirements.lock.txt', 'payload/scheme/win_scheme.py', 'payload/scheme/fcntl.py',
        'payload/licenses/LICENSE', 'payload/licenses/THIRD-PARTY-NOTICES.md',
        'payload/licenses/sources.lock.json', 'payload/licenses/Glazier-LICENSE',
        'payload/licenses/Glazier-THIRD_PARTY_NOTICES.md', 'payload/licenses/M3Shapes-LICENSE',
        'payload/licenses/Quickshell-LICENSE', 'payload/licenses/Qt/LGPL-3.0.txt'
    )) {
        if (-not $listed.ContainsKey($required)) { throw "Incomplete release: $required" }
    }
    $header = "//@ pragma DataDir @CAELESTIA_PROFILE@/data`n//@ pragma StateDir @CAELESTIA_PROFILE@/state`n//@ pragma CacheDir @CAELESTIA_PROFILE@/cache`n"
    $shell = [IO.File]::ReadAllText((Join-Path $Root 'payload\shell\shell.qml'))
    if (-not $shell.StartsWith($header, [StringComparison]::Ordinal) -or
        [regex]::Matches($shell, '(?m)^//@ pragma (DataDir|StateDir|CacheDir) ').Count -ne 3) {
        throw 'Unexpected profile relocation template.'
    }
    return [pscustomobject]@{ Manifest = $manifest; Sha256 = $manifestHash }
}

$BundleRoot = Assert-ReleaseDirectory $BundleRoot
$verified = Test-ReleaseBundle $BundleRoot $ExpectedManifestSha256
$release = $verified.Manifest
$verifiedManifestHash = $verified.Sha256
if ((Get-FileHash -LiteralPath (Join-Path $BundleRoot 'release.json') -Algorithm SHA256).Hash -ne $verifiedManifestHash) {
    throw 'Release manifest changed during verification.'
}
if ($VerifyOnly) { $release; return }
if (-not (Test-ReleaseVCRuntime ([version]$release.prerequisites.visualCppRuntime.minimumVersion))) {
    throw ('Microsoft Visual C++ x64 Redistributable 14.44.35211.0 or newer is required. ' +
        'Install or repair it using Microsoft''s official download, then rerun Install.cmd: ' +
        'https://aka.ms/vc14/vc_redist.x64.exe . The runtime installer may require administrator approval. ' +
        'Caelestia has not downloaded anything or changed your installation.')
}
$payloadSource = Join-Path $BundleRoot 'payload'
# Supplied maintenance code is loaded only after every file passed verification.
. (Join-Path $payloadSource 'Caelestia-InstallCommon.ps1')
$Prefix = Assert-ReleaseDirectory (Resolve-CaelestiaDirectory $Prefix)
if (-not $ProfileRoot) {
    $ProfileRoot = if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) {
        [string](Read-CaelestiaInstall $Prefix).profile
    } else { Join-Path $env:LOCALAPPDATA 'caelestia-windows' }
}
$ProfileRoot = Assert-ReleaseDirectory (Resolve-CaelestiaDirectory $ProfileRoot)
foreach ($pair in @(@($Prefix, $ProfileRoot), @($Prefix, $BundleRoot), @($ProfileRoot, $BundleRoot))) {
    if ($pair[0] -eq $pair[1] -or $pair[0].StartsWith($pair[1] + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $pair[1].StartsWith($pair[0] + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Prefix, profile and extracted release must be separate, non-nested directories.'
    }
}
if ($NoIntegration -and $Autostart) { throw '-NoIntegration cannot register autostart.' }
$lock = Enter-CaelestiaInstallLock $Prefix
$payload = "$Prefix.staging-$PID"
try {
    if (-not $lock) { throw 'An installation or rollback is already in progress.' }
    # Release installs never Force-adopt a foreign profile or unowned prefix.
    # Reject links in existing managed trees before any recovery or cleanup.
    foreach ($tree in @($Prefix, $ProfileRoot, "$Prefix.old")) {
        if (Test-Path -LiteralPath $tree) {
            $null = Resolve-CaelestiaDirectory $tree
            Assert-CaelestiaNoReparsePoints $tree
        }
    }
    $context = Initialize-CaelestiaInstall $Prefix $ProfileRoot -Restart:$Restart
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Prefix) | Out-Null
    New-Item -ItemType Directory -Path $payload | Out-Null
    [ordered]@{ product = 'caelestia-windows'; prefix = $Prefix; pid = $PID } |
        ConvertTo-Json | Set-Content -LiteralPath "$payload\.caelestia-staging.json" -Encoding UTF8
    foreach ($entry in $release.files) {
        if (-not $entry.path.StartsWith('payload/', [StringComparison]::Ordinal)) { continue }
        $relative = $entry.path.Substring(8)
        $target = Resolve-ReleaseFile $payload $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        [IO.File]::Copy((Resolve-ReleaseFile $BundleRoot $entry.path), $target)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw 'Release changed during copying; activation was refused.'
        }
    }
    $shellPath = Join-Path $payload 'shell\shell.qml'
    $shell = [IO.File]::ReadAllText($shellPath)
    # Only the three exact, verified header lines are transformed. Retain the
    # original manifest plus explicit destination hashes, never skip a hash.
    $header = "//@ pragma DataDir @CAELESTIA_PROFILE@/data`n//@ pragma StateDir @CAELESTIA_PROFILE@/state`n//@ pragma CacheDir @CAELESTIA_PROFILE@/cache`n"
    $profileQml = $ProfileRoot.Replace('\', '/')
    $replacement = "//@ pragma DataDir $profileQml/data`n//@ pragma StateDir $profileQml/state`n//@ pragma CacheDir $profileQml/cache`n"
    [IO.File]::WriteAllText($shellPath, ($replacement + $shell.Substring($header.Length)), [Text.UTF8Encoding]::new($false))
    $shellHash = (Get-FileHash -LiteralPath $shellPath -Algorithm SHA256).Hash
    $sourcesPath = Join-Path $payload 'shell\sources.json'
    $sources = Get-Content -LiteralPath $sourcesPath -Raw | ConvertFrom-Json
    $shellEntries = @($sources | Where-Object { $_.staged -eq 'shell.qml' })
    if ($shellEntries.Count -ne 1) { throw 'Invalid production staging record.' }
    $shellEntries[0].stagedSha256 = $shellHash
    $sources | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sourcesPath -Encoding UTF8
    [IO.File]::Copy((Join-Path $BundleRoot 'release.json'), (Join-Path $payload 'release-manifest.json'))
    if ((Get-FileHash -LiteralPath "$payload\release-manifest.json" -Algorithm SHA256).Hash -ne $verifiedManifestHash) {
        throw 'Release manifest changed during copying.'
    }
    [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $Prefix; profile = $ProfileRoot
        installId = $context.InstallId; sourceRevision = $release.sourceRevision
        backendRevision = $release.backendRevision; glazierRevision = $release.dependencies.glazier.revision
        executableSha256 = (Get-FileHash -LiteralPath "$payload\qs.exe" -Algorithm SHA256).Hash
        glazierSha256 = (Get-FileHash -LiteralPath "$payload\glazier.exe" -Algorithm SHA256).Hash
        releaseId = $release.releaseId
        releaseManifestSha256 = (Get-FileHash -LiteralPath "$payload\release-manifest.json" -Algorithm SHA256).Hash
        relocatedShellSha256 = $shellHash
        relocatedSourcesSha256 = (Get-FileHash -LiteralPath $sourcesPath -Algorithm SHA256).Hash
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$payload\install.json" -Encoding UTF8
    Remove-Item -LiteralPath "$payload\.caelestia-staging.json"
    Write-CaelestiaProfileOwner $ProfileRoot $Prefix $context.InstallId $context.ProfileExclusive
    if ($PrepareSchemeRuntime) {
        $scheme = Install-CaelestiaSchemeRuntime $payload $ProfileRoot
        if (-not $scheme.available) { Write-Warning 'Optional scheme runtime unavailable; the shell will use its fixed palette.' }
    }
    $runtime = Install-CaelestiaVersion $Prefix $payload -Restart:$Restart
    Remove-CaelestiaSchemeGenerations $Prefix $ProfileRoot
    $installed = Read-CaelestiaInstall $Prefix
    if (-not $NoIntegration) {
        Complete-CaelestiaInstallIntegration $Prefix $runtime -Previous ([string]$installed.previous) -Restart:$Restart -Autostart:$Autostart
    }
    Remove-CaelestiaRetiredVersions $Prefix
    Write-Output "Installed release $($release.releaseId): $Prefix"
    Write-Output ('Start: powershell -NoProfile -File "' + (Join-Path $Prefix 'Start-Caelestia.ps1') + '" -PreparedSchemeRuntime')
    Write-Output "Profile preserved: $ProfileRoot"
} finally {
    try {
        if ($lock -and (Test-Path -LiteralPath $payload)) {
            $safe = Resolve-CaelestiaDirectory $payload
            if ($safe -ne "$Prefix.staging-$PID") { throw 'Unsafe release staging cleanup.' }
            Assert-CaelestiaNoReparsePoints $safe
            Remove-Item -LiteralPath $safe -Recurse -Force
        }
    } finally {
        Exit-CaelestiaInstallLock $lock
    }
}
