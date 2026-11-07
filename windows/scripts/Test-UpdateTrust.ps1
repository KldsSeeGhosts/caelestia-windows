#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\Caelestia-Update.ps1"
$count = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message }; $script:count++ }
function JsonBytes($Value) { return ,([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20 -Compress))) }
function Strict($Value) { return ,(ConvertFrom-CaelestiaStrictJson (JsonBytes $Value)) }
function Refuse([scriptblock]$Action, [string]$Name, [string]$Message = '') {
    $rejected = $false
    try { $null = & $Action } catch {
        $rejected = $true
        if ($Message -and $_.Exception.Message -cne $Message) { throw "Wrong refusal for ${Name}: $($_.Exception.Message)" }
    }
    Assert $rejected "Accepted negative control: $Name"
}
function New-Key {
    $ecdsa = [Security.Cryptography.ECDsaCng]::new(256)
    $key = $ecdsa.Key
    try {
        if (-not $key.IsEphemeral) { throw 'Test key must never be persisted.' }
        $blob = $key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $x = [byte[]]$blob[8..39]; $y = [byte[]]$blob[40..71]
        return @{ Private = $key.Export([Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
            Public = @{ keyid = [Caelestia.Update.Security]::KeyId($x, $y)
                algorithm = 'ecdsa-p256-sha256'; x = [Convert]::ToBase64String($x); y = [Convert]::ToBase64String($y) } }
    } finally { $ecdsa.Dispose() }
}
function Sign($Value, [string]$Type, $Key) {
    return ,(New-CaelestiaDsse (JsonBytes $Value) ('application/vnd.caelestia.update-' + $Type + '+json') $Key.Public.keyid $Key.Private)
}
$root = New-Key; $dev = New-Key; $promotion = New-Key
$backup = New-Key
$now = [DateTime]::UtcNow
$future = $now.AddDays(90).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$trust = Strict @{
    schema = 'caelestia-update-trust'; version = 1; rootVersion = 1; status = 'configured'
    repository = 'KldsSeeGhosts/caelestia-windows'
    metadataBase = 'https://raw.githubusercontent.com/KldsSeeGhosts/caelestia-windows/nexus-channels/v1/'
    assetPrefix = 'https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/'
    redirectHosts = @('objects.githubusercontent.com', 'release-assets.githubusercontent.com')
    rootKeys = @($root.Public); rootThreshold = 1; requireAuthenticode = $false
}
$keys = @{
    type = 'caelestia-update-keys'; schema = 1; repository = $trust.repository; version = 1
    expires = $future; threshold = 1
    keys = @(@{ public = $dev.Public; channels = @('development'); notAfter = $future },
        @{ public = $promotion.Public; channels = @('preview', 'stable'); notAfter = $future })
}
$id = '0.2.0-dev.1.57.1'; $bundleRoot = "caelestia-windows-$id-windows-x64"
$channel = @{
    type = 'caelestia-update-channel'; schema = 1; repository = $trust.repository; channel = 'development'
    sequence = 1; issuedAt = $now.Date.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    expires = $now.Date.AddDays(14).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); keysVersion = 1
    release = @{
        displayVersion = $id; buildVersion = $id; releaseId = $id; tag = "v$id"
        sourceRevision = 'a' * 40; backendRevision = 'b' * 40
        manifestSha256 = 'c' * 64; profileSchema = 1; minimumUpdaterSchema = 1
        notesUrl = "https://github.com/$($trust.repository)/releases/tag/v$id"
        bundle = @{ name = "$bundleRoot.zip"; root = $bundleRoot
            url = $trust.assetPrefix + "v$id/$bundleRoot.zip"; size = 12; entries = 1; unpackedSize = 20; sha256 = 'd' * 64 }
        provenance = @{ runId = '123'; runAttempt = '1'; pairResultSha256 = 'e' * 64; candidateReceiptSha256 = 'f' * 64 }
    }
}
function Verify($K = $keys, $C = $channel, $State = $null, $Signer = $dev, $T = $trust, $Name = 'development') {
    return Test-CaelestiaMetadata (Sign $K 'keys' $root) (Sign $C 'channel' $Signer) $T $Name $State $now
}
Assert ((Verify).Release.buildVersion -ceq $id) 'Native CNG/PKCS8/P1363 round trip failed.'
$twoRoots = Strict ($trust | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
$twoRoots['rootKeys'] = @((Strict $root.Public), (Strict $backup.Public))
$twoRoots['rootThreshold'] = 2L
$first = ConvertFrom-CaelestiaStrictJson (Sign $keys 'keys' $root)
$second = ConvertFrom-CaelestiaStrictJson (Sign $keys 'keys' $backup)
$first['signatures'] = @($first.signatures[0], $second.signatures[0])
$twoVerified = Test-CaelestiaMetadata (JsonBytes $first) (Sign $channel 'channel' $dev) $twoRoots 'development' $null $now
Assert ($twoVerified.Release.buildVersion -ceq $id) 'Two distinct root signatures failed threshold.'
$first['signatures'] = @($first.signatures[0])
Refuse { Test-CaelestiaMetadata (JsonBytes $first) (Sign $channel 'channel' $dev) $twoRoots 'development' $null $now } 'missing second root' 'bad-signature'
# Independently specified DSSE PAE vectors, including byte lengths, not chars.
Assert ([Text.Encoding]::UTF8.GetString([Caelestia.Update.Security]::Pae('', [byte[]]@())) -ceq 'DSSEv1 0  0 ') 'Empty PAE vector.'
Assert ([Convert]::ToBase64String([Caelestia.Update.Security]::Pae('x', [byte[]](0, 255))) -ceq 'RFNTRXYxIDEgeCAyIAD/') 'Binary PAE vector.'
Assert ([Text.Encoding]::UTF8.GetString([Caelestia.Update.Security]::Pae([string][char]0xE9, [Text.Encoding]::UTF8.GetBytes([string][char]0xE9))) -ceq
    ('DSSEv1 2 ' + [char]0xE9 + ' 2 ' + [char]0xE9)) 'UTF8 byte-length PAE vector.'
$envelope = Strict (@{ payloadType = 'application/vnd.caelestia.update-channel+json'; payload = ''; signatures = @() })
$signed = Sign $channel 'channel' $dev
$changed = ConvertFrom-CaelestiaStrictJson $signed
$payload = [Caelestia.Update.Security]::Base64($changed.payload); $payload[1] = $payload[1] -bxor 1
$changed['payload'] = [Convert]::ToBase64String($payload)
Refuse { Read-CaelestiaDsse (JsonBytes $changed) 'application/vnd.caelestia.update-channel+json' @((Strict $dev.Public)) } 'flipped payload' 'bad-signature'
Refuse { Read-CaelestiaDsse $signed 'application/vnd.caelestia.update-keys+json' @((Strict $dev.Public)) } 'wrong payload type'
$bad = $channel.Clone(); $bad.channel = 'preview'
Refuse { Verify $keys $bad $null $dev $trust 'preview' } 'development key cannot sign preview' 'bad-signature'
$revoked = $keys.Clone(); $revoked.keys = @($keys.keys[1])
Refuse { Verify $revoked } 'revoked development key' 'bad-signature'
$verified = Verify
$high = Strict @{ schema = 1; rootVersion = 1; rootSha256 = (Get-CaelestiaRootDigest $trust); keysVersion = 1; keysSha256 = $verified.KeysSha256
    channels = @{ development = @{ sequence = 1; sha256 = $verified.Sha256; buildVersion = $id
        bundleSha256 = 'd' * 64; manifestSha256 = 'c' * 64 } } }
Assert ((Verify $keys $channel $high).Sequence -eq 1) 'Identical document replay must be idempotent.'
$newHigh = Strict @{ schema = 1; rootVersion = 1; rootSha256 = (Get-CaelestiaRootDigest $trust); keysVersion = 2; keysSha256 = '0' * 64; channels = @{} }
Refuse { Verify $keys $channel $newHigh } 'keys version rollback' 'replay'
$bad = $keys.Clone(); $bad.threshold = 2
Refuse { Verify $bad } 'distinct threshold' 'bad-signature'
$bad = $keys.Clone(); $bad.expires = $now.AddDays(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
Refuse { Verify $bad } 'expired keys' 'expired'
$bad = $channel.Clone(); $bad.sequence = 2; $bad.issuedAt = $now.Date.AddMinutes(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
Assert ((Verify $keys $bad $high).Sequence -eq 2) 'Fresh sequence rejected.'
$bad.sequence = 1
Refuse { Verify $keys $bad $high } 'equal sequence different payload' 'replay'
$olderHigh = Strict @{ schema = 1; rootVersion = 1; rootSha256 = (Get-CaelestiaRootDigest $trust); keysVersion = 1; keysSha256 = $verified.KeysSha256
    channels = @{ development = @{ sequence = 2; sha256 = $verified.Sha256 } } }
Refuse { Verify $keys $channel $olderHigh } 'lower sequence' 'replay'
$bad = $channel.Clone(); $bad.sequence = 2; $bad.release = $channel.release.Clone(); $bad.release.bundle = $channel.release.bundle.Clone()
$bad.release.bundle.sha256 = '0' * 64
Refuse { Verify $keys $bad $high } 'same build different payload' 'replay'
foreach ($field in @('repository', 'channel')) {
    $bad = $channel.Clone(); $bad[$field] = 'wrong'
    Refuse { Verify $keys $bad } "binding $field"
}
foreach ($field in @('releaseId', 'tag', 'manifestSha256', 'notesUrl', 'displayVersion')) {
    $bad = $channel.Clone(); $bad.release = $channel.release.Clone(); $bad.release[$field] = 'invalid'
    Refuse { Verify $keys $bad } "release binding $field"
}
$bad = $channel.Clone(); $bad.expires = $now.AddDays(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
Refuse { Verify $keys $bad } 'expired channel' 'expired'
$bad = $channel.Clone(); $bad.issuedAt = $now.AddDays(2).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
Refuse { Verify $keys $bad } 'future issue' 'clock'
foreach ($url in @('http://github.com/a.zip', ($channel.release.bundle.url + '?x'), 'https://evil.invalid/a.zip')) {
    $bad = $channel.Clone(); $bad.release = $channel.release.Clone(); $bad.release.bundle = $channel.release.bundle.Clone()
    $bad.release.bundle.url = $url
    Refuse { Verify $keys $bad } "asset binding $url"
}
foreach ($json in @('{"x":1,"x":2}', '{"X":1,"x":2}', '{"\u0078":1,"x":2}', '{"x":01}', '{"x":1.0}', '{"x":1e0}',
    '{"x":9223372036854775808}', '{"x":"\ud800"}', '{"x":true}x', '{"x":1,}', ('{"x":"a'+[char]0+'"}'))) {
    Refuse { ConvertFrom-CaelestiaStrictJson ([Text.Encoding]::UTF8.GetBytes($json)) } 'ambiguous/malformed JSON'
}
Refuse { ConvertFrom-CaelestiaStrictJson ([byte[]](123,34,120,34,58,34,255,34,125)) } 'malformed UTF8'
Refuse { ConvertFrom-CaelestiaStrictJson ([byte[]]::new(65537)) } 'metadata byte cap'
Refuse { [Caelestia.Update.Security]::Base64('Y Q==') } 'base64 whitespace'
Refuse { [Caelestia.Update.Security]::KeyId([byte[]]::new(31), [byte[]]::new(32)) } 'coordinate length'
$duplicate = ConvertFrom-CaelestiaStrictJson $signed
$duplicate['signatures'] = @($duplicate.signatures[0], $duplicate.signatures[0])
Refuse { Read-CaelestiaDsse (JsonBytes $duplicate) 'application/vnd.caelestia.update-channel+json' @((Strict $dev.Public)) 2 } 'duplicate signatures cannot meet threshold'
$unknownField = ConvertFrom-CaelestiaStrictJson $signed
$unknownField.Add('extra', 1L)
Refuse { Read-CaelestiaDsse (JsonBytes $unknownField) 'application/vnd.caelestia.update-channel+json' @((Strict $dev.Public)) } 'unknown envelope field'
$badSignature = ConvertFrom-CaelestiaStrictJson $signed
$badSignature.signatures[0]['sig'] = [Convert]::ToBase64String([byte[]]::new(70))
Refuse { Read-CaelestiaDsse (JsonBytes $badSignature) 'application/vnd.caelestia.update-channel+json' @((Strict $dev.Public)) } 'DER-size signature'
$olderRoot = Strict @{ schema = 1; rootVersion = 2; rootSha256 = (Get-CaelestiaRootDigest $trust)
    keysVersion = 1; keysSha256 = $verified.KeysSha256; channels = @{} }
Refuse { Verify $keys $channel $olderRoot } 'old trust roots after rollback/reinstall' 'replay'
$unconfigured = Strict @{ status = 'unconfigured'; rootKeys = @() }
$script:calls = 0
$result = Invoke-CaelestiaUpdateCheck $unconfigured 'development' $id 'C:\never-written.json' { $script:calls++; throw 'unexpected transport' }
Assert ($result.state -ceq 'not-configured' -and $script:calls -eq 0) 'Unconfigured check touched transport.'
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-trust-test-' + [guid]::NewGuid().ToString('N'))
$statePath = Join-Path $stateRoot 'highwater.json'
try {
    $script:testKeysEnvelope = Sign $keys 'keys' $root
    $script:testChannelEnvelope = Sign $channel 'channel' $dev
    $transport = { param($url, $milliseconds)
        if ($url.EndsWith('/keys.dsse.json')) { return ,$script:testKeysEnvelope }
        return ,$script:testChannelEnvelope
    }
    $checked = Invoke-CaelestiaUpdateCheck $trust 'development' '0.1.0-preview.2' $statePath $transport
    Assert ($checked.state -ceq 'available' -and $checked.available.buildVersion -ceq $id) 'Authenticated Check did not offer newer build.'
    $savedHash = (Get-FileHash -LiteralPath $statePath).Hash
    $checked = Invoke-CaelestiaUpdateCheck $trust 'development' $id $statePath $transport
    Assert ($checked.state -ceq 'not-newer') 'Same installed build was offered.'
    $bad = $channel.Clone(); $bad.sequence = 1; $bad.issuedAt = $now.Date.AddMinutes(2).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $script:testChannelEnvelope = Sign $bad 'channel' $dev
    $checked = Invoke-CaelestiaUpdateCheck $trust 'development' '0.1.0-preview.2' $statePath $transport
    Assert ($checked.state -ceq 'replay') 'Check accepted different payload at same sequence.'
    Assert ((Get-FileHash -LiteralPath $statePath).Hash -ceq $savedHash) 'Failed check mutated persisted highwater.'
    $script:testChannelEnvelope = [byte[]]::new(65537)
    $checked = Invoke-CaelestiaUpdateCheck $trust 'development' $id $statePath $transport
    Assert ($checked.state -ceq 'bad-metadata' -and (Get-FileHash -LiteralPath $statePath).Hash -ceq $savedHash) 'Oversize metadata mutated highwater.'
} finally {
    if (Test-Path -LiteralPath $stateRoot) {
        Assert-CaelestiaUpdatePath $stateRoot
        if ((Split-Path -Parent $stateRoot) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path -Leaf $stateRoot) -notlike 'caelestia-trust-test-*') { throw 'Unsafe trust fixture cleanup.' }
        Assert-CaelestiaNoReparsePoints $stateRoot
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
    }
    foreach ($key in @($root, $dev, $promotion, $backup)) { [Array]::Clear($key.Private, 0, $key.Private.Length) }
}
Write-Output "PASS update trust: $count assertions; PS $($PSVersionTable.PSVersion), CLR $([Environment]::Version); ephemeral keys only."
