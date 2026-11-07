#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('ReadChannel', 'ReadRecord', 'SignChannel', 'SignRecord')][string]$Action,
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][string]$TrustPath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\..\scripts\Caelestia-Update.ps1"
$privateValues = @()
try {
    $Directory = Resolve-CaelestiaDirectory $Directory
    Assert-CaelestiaNoReparsePoints $Directory
    $trust = Read-CaelestiaStrictJsonFile $TrustPath
    Assert-CaelestiaTrust $trust
    $request = Read-CaelestiaStrictJsonFile (Join-Path $Directory 'request.json')
    Assert-CaelestiaFields $request @('channel')
    $channel = $request.channel
    if ($channel -cnotin @('development', 'preview', 'stable')) { throw 'Invalid role.' }
    $now = [DateTime]::UtcNow
    $keysBytes = [IO.File]::ReadAllBytes((Join-Path $Directory 'keys.dsse.json'))
    $keysVerified = Read-CaelestiaDsse $keysBytes 'application/vnd.caelestia.update-keys+json' $trust.rootKeys $trust.rootThreshold
    $keys = $keysVerified.Value
    Assert-CaelestiaFields $keys @('type', 'schema', 'repository', 'version', 'expires', 'keys', 'threshold')
    Assert-CaelestiaInteger $keys.schema 1 1
    Assert-CaelestiaInteger $keys.version 1 ([long]::MaxValue)
    Assert-CaelestiaInteger $keys.threshold 1 16
    if ($keys.type -cne 'caelestia-update-keys' -or $keys.repository -cne $trust.repository -or
        (Get-CaelestiaUtc $keys.expires) -le $now -or $keys.keys -isnot [object[]] -or $keys.keys.Count -gt 16) { throw 'Invalid/expired keys document.' }
    $rootIds = @($trust.rootKeys | ForEach-Object { Get-CaelestiaPublicKeyId $_ })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allowed = @(); $entries = @{}
    foreach ($entry in $keys.keys) {
        Assert-CaelestiaFields $entry @('public', 'channels', 'notAfter')
        $id = Get-CaelestiaPublicKeyId $entry.public
        $expiry = Get-CaelestiaUtc $entry.notAfter
        if (-not $seen.Add($id) -or $id -cin $rootIds -or $entry.channels -isnot [object[]] -or
            $entry.channels.Count -lt 1 -or $entry.channels.Count -gt 2) { throw 'Invalid delegated key.' }
        $roles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($role in $entry.channels) {
            if ($role -cnotin @('development', 'preview', 'stable') -or -not $roles.Add($role)) { throw 'Invalid delegated roles.' }
        }
        if ($roles.Contains('development') -and $roles.Count -ne 1) { throw 'Development/promotion roles must be separate.' }
        if ($roles.Contains($channel) -and $expiry -gt $now) { $allowed += ,$entry.public; $entries[$id] = $entry }
    }
    function Assert-ChannelShape($doc, [switch]$Historical) {
        Assert-CaelestiaFields $doc @('type', 'schema', 'repository', 'channel', 'sequence', 'issuedAt', 'expires', 'keysVersion', 'release')
        Assert-CaelestiaInteger $doc.schema 1 1
        Assert-CaelestiaInteger $doc.sequence 1 ([long]::MaxValue)
        Assert-CaelestiaInteger $doc.keysVersion 1 $keys.version
        if ($doc.type -cne 'caelestia-update-channel' -or $doc.repository -cne $trust.repository -or $doc.channel -cne $channel) { throw 'Channel binding mismatch.' }
        $issued = Get-CaelestiaUtc $doc.issuedAt; $expires = Get-CaelestiaUtc $doc.expires
        if ($issued -gt $now.AddHours(24) -or $expires -le $issued -or $expires -gt $issued.AddDays(15) -or
            (-not $Historical -and $expires -le $now)) { throw 'Invalid channel freshness.' }
        Assert-CaelestiaReleaseMetadata $doc.release $trust $channel
    }
    function Assert-RecordShape($doc) {
        Assert-CaelestiaFields $doc @('type', 'schema', 'repository', 'channel', 'signedAt', 'release', 'assets')
        Assert-CaelestiaInteger $doc.schema 1 1
        $expectedType = if ($channel -eq 'development') { 'caelestia-release-record' } else { 'caelestia-alias-record' }
        if ($doc.type -cne $expectedType -or $doc.repository -cne $trust.repository -or
            $doc.channel -cne $channel -or (Get-CaelestiaUtc $doc.signedAt) -gt $now.AddHours(24)) { throw 'Record binding mismatch.' }
        Assert-CaelestiaReleaseMetadata $doc.release $trust $channel
        if ($doc.assets -isnot [object[]] -or $doc.assets.Count -lt 1 -or $doc.assets.Count -gt 64) { throw 'Invalid record asset inventory.' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($asset in $doc.assets) {
            Assert-CaelestiaFields $asset @('name', 'size', 'sha256')
            Assert-CaelestiaZipComponent $asset.name
            Assert-CaelestiaInteger $asset.size 1 2147483648
            if (-not $names.Add($asset.name) -or $asset.sha256 -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Invalid record asset.' }
        }
    }
    $payloadType = if ($Action.EndsWith('Channel')) { 'application/vnd.caelestia.update-channel+json' }
        elseif ($channel -eq 'development') { 'application/vnd.caelestia.release-record+json' } else { 'application/vnd.caelestia.alias-record+json' }
    if ($Action.StartsWith('Read')) {
        $verified = Read-CaelestiaDsse ([IO.File]::ReadAllBytes((Join-Path $Directory 'document.dsse.json'))) $payloadType $allowed $keys.threshold
        if ($Action -eq 'ReadChannel') {
            # Publisher-only historical authentication. Expired documents may
            # be renewed, never installed: client TestMetadata remains strict.
            Assert-ChannelShape $verified.Value -Historical
        } else { Assert-RecordShape $verified.Value }
        Write-CaelestiaJsonAtomic (Join-Path $Directory 'result.json') @{
            payload = $verified.Value; payloadSha256 = $verified.Sha256; keysVersion = $keys.version
        }
    } else {
        $secret = $env:NEXUS_SIGNING_KEY
        $env:NEXUS_SIGNING_KEY = $null
        if (-not $secret) { throw 'Missing signing credential.' }
        # A single PKCS8 base64 or an explicit JSON array supports distinct-key
        # delegated thresholds without changing role policy or printing keys.
        $values = if ($secret.StartsWith('[')) { @($secret | ConvertFrom-Json -ErrorAction Stop) } else { @($secret) }
        $secret = $null
        if ($values.Count -lt 1 -or $values.Count -gt 16) { throw 'Invalid signing credential count.' }
        $doc = Read-CaelestiaStrictJsonFile (Join-Path $Directory 'payload.json') 1048576
        if ($Action -eq 'SignChannel') { Assert-ChannelShape $doc } else { Assert-RecordShape $doc }
        $payload = [Text.UTF8Encoding]::new($false).GetBytes(($doc | ConvertTo-Json -Depth 20 -Compress))
        $signatures = @()
        $signerIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($value in $values) {
            $private = [Caelestia.Update.Security]::Base64($value)
            $privateValues += ,$private
            $blob = [Caelestia.Update.Security]::PublicFromPrivate($private)
            $id = [Caelestia.Update.Security]::KeyId([byte[]]$blob[8..39], [byte[]]$blob[40..71])
            if (-not $entries.ContainsKey($id) -or -not $signerIds.Add($id)) { throw 'Unauthorized or duplicate signing key.' }
            if ($Action -eq 'SignChannel' -and (Get-CaelestiaUtc $doc.expires) -gt (Get-CaelestiaUtc $entries[$id].notAfter)) {
                throw 'Channel expiry exceeds signing key lifetime; rotate or renew first.'
            }
            $signature = [Caelestia.Update.Security]::Sign([Caelestia.Update.Security]::Pae($payloadType, $payload), $private)
            $signatures += @{ keyid = $id; sig = [Convert]::ToBase64String($signature) }
        }
        $values = $null
        $envelope = [Text.UTF8Encoding]::new($false).GetBytes((@{
            payloadType = $payloadType; payload = [Convert]::ToBase64String($payload); signatures = $signatures
        } | ConvertTo-Json -Depth 6 -Compress))
        $null = Read-CaelestiaDsse $envelope $payloadType $allowed $keys.threshold
        if ($Action -eq 'SignChannel') {
            # Execute the unchanged strict CLIENT verifier before publication.
            $null = Test-CaelestiaMetadata $keysBytes $envelope $trust $channel $null $now
        }
        [IO.File]::WriteAllBytes((Join-Path $Directory 'envelope.dsse.json'), $envelope)
    }
    Write-Output 'NEXUS_CRYPTO_PASS'
} catch {
    Write-Error 'Nexus metadata verification/signing refused.' -ErrorAction Continue
    exit 1
} finally {
    $env:NEXUS_SIGNING_KEY = $null
    foreach ($private in $privateValues) { [Array]::Clear($private, 0, $private.Length) }
}
