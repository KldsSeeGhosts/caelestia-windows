#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Paths')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Paths')][string[]]$RootPrivateKeyPath,
    # JSON array of paths supports multiple roots under powershell.exe -File.
    [Parameter(Mandatory, ParameterSetName = 'List')][string]$RootPrivateKeyListPath,
    # JSON array of { publicPath, channels, notAfter? }, paths relative to this file.
    [Parameter(Mandatory)][string]$DelegatedKeysPath,
    [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long]$Version,
    [string]$Expires = [DateTime]::UtcNow.AddDays(365).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    [ValidateRange(1, 16)][int]$Threshold = 1,
    [string]$TrustPath = "$PSScriptRoot\..\release\update-trust.json",
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Nexus-OwnerCommon.ps1"
$privateValues = @()
$temporary = $null
try {
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    Assert-NexusOwnerOutput $OutputPath
    $trust = Read-CaelestiaStrictJsonFile (Resolve-Path -LiteralPath $TrustPath).Path
    Assert-CaelestiaTrust $trust
    $delegations = (Resolve-Path -LiteralPath $DelegatedKeysPath).Path
    $entries = Read-CaelestiaStrictJsonFile $delegations
    if ($entries -isnot [object[]]) { throw 'Delegations must be a JSON array.' }
    $keys = @()
    foreach ($entry in $entries) {
        $fields = @('publicPath', 'channels')
        if ($entry.ContainsKey('notAfter')) { $fields += 'notAfter' }
        Assert-CaelestiaFields $entry $fields
        $publicPath = $entry.publicPath
        if (-not [IO.Path]::IsPathRooted($publicPath)) { $publicPath = Join-Path (Split-Path -Parent $delegations) $publicPath }
        $keys += @{ public = Read-CaelestiaStrictJsonFile $publicPath; channels = $entry.channels
            notAfter = $(if ($entry.ContainsKey('notAfter')) { $entry.notAfter } else { $Expires }) }
    }
    $doc = @{ type = 'caelestia-update-keys'; schema = 1; repository = $trust.repository
        version = $Version; expires = $Expires; keys = $keys; threshold = $Threshold }
    $payload = [Text.UTF8Encoding]::new($false).GetBytes(($doc | ConvertTo-Json -Depth 20 -Compress))
    Assert-NexusOwnerKeys (ConvertFrom-CaelestiaStrictJson $payload) $trust
    if ($PSCmdlet.ParameterSetName -eq 'List') {
        $listPath = (Resolve-Path -LiteralPath $RootPrivateKeyListPath).Path
        $RootPrivateKeyPath = Read-CaelestiaStrictJsonFile $listPath
        $RootPrivateKeyPath = @($RootPrivateKeyPath | ForEach-Object {
            if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path (Split-Path -Parent $listPath) $_ }
        })
    }
    if ($RootPrivateKeyPath.Count -lt $trust.rootThreshold -or $RootPrivateKeyPath.Count -gt 16) { throw 'Insufficient/excess root signers.' }
    $rootIds = @($trust.rootKeys | ForEach-Object { Get-CaelestiaPublicKeyId $_ })
    $signers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $type = 'application/vnd.caelestia.update-keys+json'
    $signatures = @()
    foreach ($path in $RootPrivateKeyPath) {
        $private = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $path).Path)
        $privateValues += ,$private
        $blob = [Caelestia.Update.Security]::PublicFromPrivate($private)
        $id = [Caelestia.Update.Security]::KeyId([byte[]]$blob[8..39], [byte[]]$blob[40..71])
        if ($id -cnotin $rootIds -or -not $signers.Add($id)) { throw 'Unauthorized or duplicate root signer.' }
        $sig = [Caelestia.Update.Security]::Sign([Caelestia.Update.Security]::Pae($type, $payload), $private)
        $signatures += @{ keyid = $id; sig = [Convert]::ToBase64String($sig) }
    }
    $envelope = @{ payloadType = $type; payload = [Convert]::ToBase64String($payload); signatures = $signatures }
    # Use the existing JSON writer on a unique public-only sibling, then
    # authenticate the exact bytes that will become the owner document.
    $temporary = Join-Path (Split-Path -Parent $OutputPath) ('keys-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-CaelestiaJsonAtomic $temporary $envelope
    $bytes = [IO.File]::ReadAllBytes($temporary)
    $verified = Read-CaelestiaDsse $bytes $type $trust.rootKeys $trust.rootThreshold
    Assert-NexusOwnerKeys $verified.Value $trust
    # Move without replacement also rejects an output created after the initial
    # path check. An interrupted write never exposes a partial final document.
    [IO.File]::Move($temporary, $OutputPath)
    Write-Output "Keys document version: $Version"
    Write-Output "Expires: $Expires"
    foreach ($entry in $keys) { Write-Output ("Delegated key: {0} roles: {1} notAfter: {2}" -f $entry.public.keyid, ($entry.channels -join ','), $entry.notAfter) }
    Write-Output ("Envelope SHA-256: " + [Caelestia.Update.Security]::Hash($bytes))
} finally {
    foreach ($private in $privateValues) { [Array]::Clear($private, 0, $private.Length) }
    if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}
