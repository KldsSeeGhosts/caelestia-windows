#requires -Version 5.1
[CmdletBinding()]
param(
    # Explicit owner action only. Use a private, preferably offline encrypted
    # volume outside the checkout, output trees, payloads and shared folders.
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\..\scripts\Caelestia-Update.ps1"
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
Assert-CaelestiaUpdatePath $OutputDirectory
if ($OutputDirectory -eq $repo -or $OutputDirectory.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $repo.StartsWith($OutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $OutputDirectory)) { throw 'Key output must be new and outside the checkout.' }
$ecdsa = [Security.Cryptography.ECDsaCng]::new(256)
$private = $null
try {
    if (-not $ecdsa.Key.IsEphemeral) { throw 'Persistent provider keys are not permitted.' }
    $blob = $ecdsa.Key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
    $x = [byte[]]$blob[8..39]; $y = [byte[]]$blob[40..71]
    $id = [Caelestia.Update.Security]::KeyId($x, $y)
    $private = $ecdsa.Key.Export([Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    # Private output is binary PKCS8, never stdout or a source-controlled file.
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'private.pkcs8'), $private)
    Write-CaelestiaJsonAtomic (Join-Path $OutputDirectory 'public.json') @{
        keyid = $id; algorithm = 'ecdsa-p256-sha256'; x = [Convert]::ToBase64String($x); y = [Convert]::ToBase64String($y)
    }
    Write-Output "Public key fingerprint: $id"
    Write-Output 'Private PKCS8 is unencrypted. Secure the output offline; never commit or upload it.'
} finally {
    if ($private) { [Array]::Clear($private, 0, $private.Length) }
    $ecdsa.Dispose()
}
