#requires -Version 5.1
. (Join-Path $PSScriptRoot 'Caelestia-SemVer.ps1')
if (-not ('Caelestia.Update.Security' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Caelestia-UpdateSecurity.cs') -ReferencedAssemblies System.Net.Http -ErrorAction Stop
}

function ConvertFrom-CaelestiaStrictJson([byte[]]$Bytes, [int]$MaxBytes = 65536) {
    return ,([Caelestia.Update.Security]::Json($Bytes, $MaxBytes))
}
function Read-CaelestiaStrictJsonFile([string]$Path, [int]$MaxBytes = 65536, [switch]$AllowUtf8Bom) {
    return ,([Caelestia.Update.Security]::JsonFile($Path, $MaxBytes, [bool]$AllowUtf8Bom))
}
function Assert-CaelestiaFields($Object, [string[]]$Fields) {
    if ($Object -isnot [Collections.Generic.Dictionary[string, object]] -or $Object.Count -ne $Fields.Count) { throw 'bad-metadata' }
    foreach ($field in $Fields) { if (-not $Object.ContainsKey($field)) { throw 'bad-metadata' } }
}
function Assert-CaelestiaInteger($Value, [long]$Minimum, [long]$Maximum) {
    if ($Value -isnot [long] -or $Value -lt $Minimum -or $Value -gt $Maximum) { throw 'bad-metadata' }
}
function Get-CaelestiaUtc($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$') { throw 'bad-metadata' }
    return [DateTime]::ParseExact($Value, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}
function Get-CaelestiaPublicKeyId($Key) {
    Assert-CaelestiaFields $Key @('keyid', 'algorithm', 'x', 'y')
    if ($Key.algorithm -cne 'ecdsa-p256-sha256') { throw 'bad-metadata' }
    $id = [Caelestia.Update.Security]::KeyId([Caelestia.Update.Security]::Base64($Key.x), [Caelestia.Update.Security]::Base64($Key.y))
    if ($Key.keyid -cne $id) { throw 'bad-metadata' }
    return $id
}
function Read-CaelestiaDsse([byte[]]$Envelope, [string]$PayloadType, $Keys, [int]$Threshold = 1) {
    if ($Threshold -lt 1 -or $Threshold -gt 16 -or @($Keys).Count -gt 16) { throw 'bad-metadata' }
    $doc = ConvertFrom-CaelestiaStrictJson $Envelope
    Assert-CaelestiaFields $doc @('payloadType', 'payload', 'signatures')
    if ($doc.payloadType -cne $PayloadType -or $doc.payload -isnot [string] -or
        $doc.signatures -isnot [object[]] -or $doc.signatures.Count -gt 16) { throw 'bad-metadata' }
    $payload = [Caelestia.Update.Security]::Base64($doc.payload)
    $pae = [Caelestia.Update.Security]::Pae($PayloadType, $payload)
    $authorized = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($key in $Keys) {
        $id = Get-CaelestiaPublicKeyId $key
        if ($authorized.ContainsKey($id)) { throw 'bad-metadata' }
        $authorized.Add($id, $key)
    }
    $valid = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($signature in $doc.signatures) {
        Assert-CaelestiaFields $signature @('keyid', 'sig')
        if ($signature.keyid -isnot [string] -or $signature.keyid -cnotmatch '^[a-f0-9]{64}$' -or
            -not $seen.Add($signature.keyid) -or $signature.sig -isnot [string]) { throw 'bad-metadata' }
        $sig = [Caelestia.Update.Security]::Base64($signature.sig)
        if ($sig.Length -ne 64) { throw 'bad-signature' }
        if ($authorized.ContainsKey($signature.keyid)) {
            $key = $authorized[$signature.keyid]
            if ([Caelestia.Update.Security]::Verify($pae, $sig, [Caelestia.Update.Security]::Base64($key.x),
                [Caelestia.Update.Security]::Base64($key.y))) { $null = $valid.Add($signature.keyid) }
        }
    }
    if ($valid.Count -lt $Threshold) { throw 'bad-signature' }
    return [pscustomobject]@{ Value = (ConvertFrom-CaelestiaStrictJson $payload); Sha256 = [Caelestia.Update.Security]::Hash($payload) }
}

function New-CaelestiaDsse([byte[]]$Payload, [string]$PayloadType, [string]$KeyId, [byte[]]$Pkcs8) {
    $signature = [Caelestia.Update.Security]::Sign([Caelestia.Update.Security]::Pae($PayloadType, $Payload), $Pkcs8)
    return [Text.UTF8Encoding]::new($false).GetBytes((@{
        payloadType = $PayloadType; payload = [Convert]::ToBase64String($Payload)
        signatures = @(@{ keyid = $KeyId; sig = [Convert]::ToBase64String($signature) })
    } | ConvertTo-Json -Depth 5 -Compress))
}

function Test-CaelestiaTrustConfigured($Trust) {
    # No transport, override, environment variable or test key fallback here.
    return $Trust.status -ceq 'configured' -and @($Trust.rootKeys).Count -gt 0
}

function Assert-CaelestiaTrust($Trust) {
    Assert-CaelestiaFields $Trust @('schema', 'version', 'rootVersion', 'status', 'repository', 'metadataBase', 'assetPrefix',
        'redirectHosts', 'rootKeys', 'rootThreshold', 'requireAuthenticode')
    if ($Trust.schema -cne 'caelestia-update-trust' -or $Trust.version -ne 1 -or
        -not (Test-CaelestiaTrustConfigured $Trust) -or $Trust.requireAuthenticode -isnot [bool] -or $Trust.requireAuthenticode -ne $false -or
        $Trust.repository -cne 'KldsSeeGhosts/caelestia-windows' -or
        $Trust.metadataBase -cne 'https://raw.githubusercontent.com/KldsSeeGhosts/caelestia-windows/nexus-channels/v1/' -or
        $Trust.assetPrefix -cne 'https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/') { throw 'not-configured' }
    Assert-CaelestiaInteger $Trust.rootThreshold 1 16
    Assert-CaelestiaInteger $Trust.version 1 1
    Assert-CaelestiaInteger $Trust.rootVersion 1 ([long]::MaxValue)
    if ($Trust.rootKeys -isnot [object[]] -or $Trust.rootKeys.Count -lt $Trust.rootThreshold -or $Trust.rootKeys.Count -gt 16) { throw 'bad-metadata' }
    foreach ($key in $Trust.rootKeys) { $null = Get-CaelestiaPublicKeyId $key }
    if ($Trust.redirectHosts -isnot [object[]]) { throw 'bad-metadata' }
    foreach ($hostName in $Trust.redirectHosts) {
        if ($hostName -cnotin @('objects.githubusercontent.com', 'release-assets.githubusercontent.com')) { throw 'bad-metadata' }
    }
}

function Get-CaelestiaRootDigest($Trust) {
    $ids = @($Trust.rootKeys | ForEach-Object { Get-CaelestiaPublicKeyId $_ } | Sort-Object -CaseSensitive)
    return [Caelestia.Update.Security]::Hash([Text.Encoding]::ASCII.GetBytes(
        ([string]$Trust.rootThreshold + ':' + ($ids -join ':'))))
}

function Test-CaelestiaMetadata([byte[]]$KeysEnvelope, [byte[]]$ChannelEnvelope, $Trust,
    [ValidateSet('development', 'preview', 'stable')][string]$Channel, $Highwater, [DateTime]$Now = [DateTime]::UtcNow) {
    Assert-CaelestiaTrust $Trust
    if ($Highwater -and ($Trust.rootVersion -lt $Highwater.rootVersion -or
        ($Trust.rootVersion -eq $Highwater.rootVersion -and (Get-CaelestiaRootDigest $Trust) -cne $Highwater.rootSha256))) { throw 'replay' }
    $keysVerified = Read-CaelestiaDsse $KeysEnvelope 'application/vnd.caelestia.update-keys+json' $Trust.rootKeys $Trust.rootThreshold
    $keys = $keysVerified.Value
    Assert-CaelestiaFields $keys @('type', 'schema', 'repository', 'version', 'expires', 'keys', 'threshold')
    if ($keys.type -cne 'caelestia-update-keys' -or $keys.schema -ne 1 -or $keys.repository -cne $Trust.repository) { throw 'bad-metadata' }
    Assert-CaelestiaInteger $keys.version 1 ([long]::MaxValue)
    Assert-CaelestiaInteger $keys.schema 1 1
    Assert-CaelestiaInteger $keys.threshold 1 16
    if ((Get-CaelestiaUtc $keys.expires) -le $Now) { throw 'expired' }
    if ($Highwater -and ($keys.version -lt $Highwater.keysVersion -or
        ($keys.version -eq $Highwater.keysVersion -and $keysVerified.Sha256 -cne $Highwater.keysSha256))) { throw 'replay' }
    if ($keys.keys -isnot [object[]] -or $keys.keys.Count -gt 16) { throw 'bad-metadata' }
    $allowed = @()
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $keys.keys) {
        Assert-CaelestiaFields $entry @('public', 'channels', 'notAfter')
        $id = Get-CaelestiaPublicKeyId $entry.public
        if (-not $ids.Add($id) -or $entry.channels -isnot [object[]] -or $entry.channels.Count -eq 0) { throw 'bad-metadata' }
        foreach ($name in $entry.channels) { if ($name -cnotin @('development', 'preview', 'stable')) { throw 'bad-metadata' } }
        # Role separation is structural, not merely advisory.
        if ('development' -cin $entry.channels -and $entry.channels.Count -ne 1) { throw 'bad-metadata' }
        if ($Channel -cin $entry.channels -and (Get-CaelestiaUtc $entry.notAfter) -gt $Now) { $allowed += ,$entry.public }
    }
    $verified = Read-CaelestiaDsse $ChannelEnvelope 'application/vnd.caelestia.update-channel+json' $allowed $keys.threshold
    $doc = $verified.Value
    Assert-CaelestiaFields $doc @('type', 'schema', 'repository', 'channel', 'sequence', 'issuedAt', 'expires', 'keysVersion', 'release')
    if ($doc.type -cne 'caelestia-update-channel' -or $doc.schema -ne 1 -or $doc.repository -cne $Trust.repository -or
        $doc.channel -cne $Channel -or $doc.keysVersion -ne $keys.version) { throw 'bad-metadata' }
    Assert-CaelestiaInteger $doc.sequence 1 ([long]::MaxValue)
    Assert-CaelestiaInteger $doc.schema 1 1
    Assert-CaelestiaInteger $doc.keysVersion 1 ([long]::MaxValue)
    $issued = Get-CaelestiaUtc $doc.issuedAt; $expires = Get-CaelestiaUtc $doc.expires
    if ($issued -gt $Now.AddHours(24)) { throw 'clock' }
    if ($expires -le $Now) { throw 'expired' }
    if ($expires -le $issued -or $expires -gt $issued.AddDays(15)) { throw 'bad-metadata' }
    $old = if ($Highwater -and $Highwater.channels) { $Highwater.channels[$Channel] } else { $null }
    if ($old -and ($doc.sequence -lt $old.sequence -or ($doc.sequence -eq $old.sequence -and $verified.Sha256 -cne $old.sha256))) { throw 'replay' }
    $release = $doc.release
    Assert-CaelestiaReleaseMetadata $release $Trust $Channel
    if ($old -and $old.buildVersion) {
        $comparison = Compare-CaelestiaSemVer $release.buildVersion $old.buildVersion
        if ($comparison -lt 0 -or ($comparison -eq 0 -and
            ($old.bundleSha256 -cne $release.bundle.sha256 -or $old.manifestSha256 -cne $release.manifestSha256))) { throw 'replay' }
    }
    return [pscustomobject]@{
        Release = $release
        KeysVersion = $keys.version; KeysSha256 = $keysVerified.Sha256
        Sequence = $doc.sequence; Sha256 = $verified.Sha256
    }
}

function Assert-CaelestiaReleaseMetadata($release, $Trust, [string]$Channel) {
    Assert-CaelestiaFields $release @('displayVersion', 'buildVersion', 'releaseId', 'tag', 'sourceRevision', 'backendRevision',
        'bundle', 'manifestSha256', 'profileSchema', 'minimumUpdaterSchema', 'notesUrl', 'provenance')
    if (-not (Test-CaelestiaDevVersion $release.buildVersion) -or $release.releaseId -cne $release.buildVersion -or
        $release.tag -cne ('v' + $release.displayVersion) -or
        $release.sourceRevision -cnotmatch '^[a-f0-9]{40}$' -or $release.backendRevision -cnotmatch '^[a-f0-9]{40}$' -or
        $release.manifestSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'bad-metadata' }
    $build = ConvertTo-CaelestiaSemVer $release.buildVersion
    $display = ConvertTo-CaelestiaSemVer $release.displayVersion
    if ($build.Core -cne $display.Core -or $display.Build) { throw 'bad-metadata' }
    if ($Channel -ceq 'development' -and $release.displayVersion -cne $release.buildVersion) { throw 'bad-metadata' }
    if ($Channel -ceq 'preview' -and $display.Prerelease -cnotmatch '^(preview|rc)\.[1-9][0-9]*$') { throw 'bad-metadata' }
    if ($Channel -ceq 'stable' -and ($display.Major -ceq '0' -or $display.Prerelease)) { throw 'bad-metadata' }
    Assert-CaelestiaInteger $release.profileSchema 1 ([long]::MaxValue)
    Assert-CaelestiaInteger $release.minimumUpdaterSchema 1 ([long]::MaxValue)
    if ($release.minimumUpdaterSchema -gt 1 -or $release.profileSchema -ne 1) { throw 'unsupported' }
    $bundle = $release.bundle
    Assert-CaelestiaFields $bundle @('name', 'url', 'size', 'sha256', 'root', 'entries', 'unpackedSize')
    $root = 'caelestia-windows-' + $release.buildVersion + '-windows-x64'
    if ($bundle.root -cne $root -or $bundle.name -cne ($root + '.zip') -or
        $bundle.url -cne ($Trust.assetPrefix + $release.tag + '/' + $bundle.name) -or
        $bundle.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $release.notesUrl -cne ('https://github.com/' + $Trust.repository + '/releases/tag/' + $release.tag)) { throw 'bad-metadata' }
    Assert-CaelestiaInteger $bundle.size 1 1073741824
    Assert-CaelestiaInteger $bundle.entries 1 50000
    Assert-CaelestiaInteger $bundle.unpackedSize 1 4294967296
    Assert-CaelestiaFields $release.provenance @('runId', 'runAttempt', 'pairResultSha256', 'candidateReceiptSha256')
    foreach ($field in @('runId', 'runAttempt')) {
        if ($release.provenance[$field] -isnot [string] -or $release.provenance[$field] -cnotmatch '^[1-9][0-9]*$') { throw 'bad-metadata' }
    }
    foreach ($field in @('pairResultSha256', 'candidateReceiptSha256')) {
        if ($release.provenance[$field] -cnotmatch '^[a-f0-9]{64}$') { throw 'bad-metadata' }
    }
}
