#requires -Version 5.1
. "$PSScriptRoot\..\scripts\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\..\scripts\Caelestia-Update.ps1"

function Assert-NexusOwnerOutput([string]$Path) {
    Assert-CaelestiaUpdatePath $Path
    $checkout = (Resolve-Path "$PSScriptRoot\..\..").Path.TrimEnd('\')
    if ($Path -eq $checkout -or $Path.StartsWith($checkout + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $checkout.StartsWith($Path.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath $Path)) { throw 'Output must be new and outside the checkout.' }
}

# Owner-side validation mirrors the keys-document checks in the client and
# publisher, including the publisher's stricter duplicate/root/role policy.
# The client verifier and trust loader remain unchanged.
function Assert-NexusOwnerKeys($Keys, $Trust, [DateTime]$Now = [DateTime]::UtcNow) {
    Assert-CaelestiaFields $Keys @('type', 'schema', 'repository', 'version', 'expires', 'keys', 'threshold')
    Assert-CaelestiaInteger $Keys.schema 1 1
    Assert-CaelestiaInteger $Keys.version 1 ([long]::MaxValue)
    Assert-CaelestiaInteger $Keys.threshold 1 16
    if ($Keys.type -cne 'caelestia-update-keys' -or $Keys.repository -cne $Trust.repository -or
        (Get-CaelestiaUtc $Keys.expires) -le $Now -or $Keys.keys -isnot [object[]] -or
        $Keys.keys.Count -lt 1 -or $Keys.keys.Count -gt 16) { throw 'Invalid/expired keys document.' }
    $roots = @($Trust.rootKeys | ForEach-Object { Get-CaelestiaPublicKeyId $_ })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $counts = @{ development = 0; preview = 0; stable = 0 }
    foreach ($entry in $Keys.keys) {
        Assert-CaelestiaFields $entry @('public', 'channels', 'notAfter')
        $id = Get-CaelestiaPublicKeyId $entry.public
        if (-not $seen.Add($id) -or $id -cin $roots -or $entry.channels -isnot [object[]] -or
            $entry.channels.Count -lt 1 -or $entry.channels.Count -gt 2 -or
            (Get-CaelestiaUtc $entry.notAfter) -le $Now) { throw 'Invalid delegated key.' }
        $roles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($role in $entry.channels) {
            if ($role -cnotin @('development', 'preview', 'stable') -or -not $roles.Add($role)) { throw 'Invalid delegated roles.' }
            $counts[$role]++
        }
        if ($roles.Contains('development') -and $roles.Count -ne 1) { throw 'Development/promotion roles must be separate.' }
    }
    foreach ($role in $counts.Keys) {
        if ($counts[$role] -gt 0 -and $counts[$role] -lt $Keys.threshold) { throw 'Insufficient delegated keys for role threshold.' }
    }
}

function Get-NexusBootstrapRelease($Trust, [string]$OutputDirectory, [scriptblock]$Fetch = {
    param($Address, $Hosts, $Redirects, $Cap, $Size, $Hash, $Destination, $Milliseconds)
    return ,([Caelestia.Update.Transport]::Fetch($Address, $Hosts, $Redirects, $Cap, $Size, $Hash, $Destination, $Milliseconds))
}) {
    Assert-CaelestiaTrust $Trust
    Assert-NexusOwnerOutput $OutputDirectory
    $keys = & $Fetch ($Trust.metadataBase + 'keys.dsse.json') @('raw.githubusercontent.com') 0 65536 -1 $null $null 30000
    $pointer = & $Fetch ($Trust.metadataBase + 'development.dsse.json') @('raw.githubusercontent.com') 0 65536 -1 $null $null 30000
    $verified = Test-CaelestiaMetadata $keys $pointer $Trust 'development' $null
    # The client authenticates the bundle and manifest directly from the signed
    # pointer. It requires no separate release record for development install.
    $release = $verified.Release
    # Recheck after metadata transport and reserve the new directory without
    # -Force, so a concurrent creator cannot turn this into reuse.
    Assert-NexusOwnerOutput $OutputDirectory
    $null = New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop
    $zip = Save-CaelestiaUpdateBundle $release $Trust $OutputDirectory $Fetch
    if ((Get-Item -LiteralPath $zip).Length -ne $release.bundle.size -or
        (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.bundle.sha256) {
        throw 'Bootstrap bundle size/hash mismatch.'
    }
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'keys.dsse.json'), $keys)
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'development.dsse.json'), $pointer)
    $installer = Join-Path (Join-Path $OutputDirectory $release.bundle.root) 'Install-CaelestiaRelease.ps1'
    return [pscustomobject]@{
        Bundle = $zip; Release = $release
        InstallCommand = "& '" + $installer.Replace("'", "''") + "' -ExpectedManifestSha256 " + $release.manifestSha256 + ' -Restart'
    }
}
