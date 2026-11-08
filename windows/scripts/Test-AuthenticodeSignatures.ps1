#requires -Version 5.1
<#
.SYNOPSIS
    Verifies the expected file set and Authenticode signatures of an extracted
    release bundle.

.DESCRIPTION
    Checks the publisher-signing policy in windows/docs/CODE-SIGNING-POLICY.md.
    This is a standalone tool. No CI job calls it, and it changes no signature,
    certificate store or machine policy.

    Before examining any signature it checks the bundle against two reviewed
    inventories and the bundle's own release.json:

      windows/release/signing-inventory.json   first-party files that must exist
      windows/release/vendor-privacy-review.json   deployed Qt DLLs that must exist

    A missing capture host, desktop supervisor, bootstrap script, maintenance
    script or Qt DLL fails even when release.json was edited to match the
    deletion.

      stable   every reviewed first-party PE and PowerShell file has a Valid
               signature with an RFC 3161 timestamp from the exact expected
               publisher; every reviewed Qt PE keeps a valid, timestamped Qt
               signature; no third-party file carries the project identity.
      preview  the unsigned development channel: only Qt signatures are
               checked, so an unsigned development bundle still fails when a
               deployed Qt DLL lost its vendor signature.

    Prints a compact summary and fails with exit code 1 on any violation. It
    reads files only.

.PARAMETER BundleRoot
    Extracted bundle directory containing release.json and payload/.

.PARAMETER Channel
    stable or preview. Select it from the release reference with
    Get-CaelestiaReleaseChannel.

.PARAMETER ExpectedSignerSubject
    Exact signing certificate subject, compared as a literal string. Required
    for stable. Use the subject recorded by the first accepted signing request;
    never a wildcard or regular expression.

.PARAMETER SignedInventoryPath
    Reviewed signed-file inventory. Defaults to
    windows/release/signing-inventory.json in this checkout.

.PARAMETER VendorReviewPath
    Reviewed Qt supplier list. Defaults to
    windows/release/vendor-privacy-review.json in this checkout.

.PARAMETER SummaryPath
    Optional path for a JSON summary. Contains relative bundle paths only.

.EXAMPLE
    powershell -NoProfile -File windows/scripts/Test-AuthenticodeSignatures.ps1 `
        -BundleRoot D:\release\caelestia-windows-1.0.0-windows-x64 -Channel stable `
        -ExpectedSignerSubject 'CN=SignPath Foundation, O=SignPath Foundation'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundleRoot,
    [Parameter(Mandatory)][ValidateSet('stable', 'preview')][string]$Channel,
    [string]$ExpectedSignerSubject,
    [string]$SignedInventoryPath,
    [string]$VendorReviewPath,
    [string]$SummaryPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Signing.ps1')

if ($env:OS -ne 'Windows_NT') { throw 'Authenticode verification requires Windows.' }
if ($Channel -eq 'stable' -and -not $ExpectedSignerSubject) {
    throw 'Stable signature verification requires -ExpectedSignerSubject.'
}
$releaseRoot = Split-Path -Parent $PSScriptRoot
if (-not $SignedInventoryPath) { $SignedInventoryPath = Join-Path $releaseRoot 'release\signing-inventory.json' }
if (-not $VendorReviewPath) { $VendorReviewPath = Join-Path $releaseRoot 'release\vendor-privacy-review.json' }
$SignedInventoryPath = (Resolve-Path -LiteralPath $SignedInventoryPath).Path
$VendorReviewPath = (Resolve-Path -LiteralPath $VendorReviewPath).Path
$root = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $BundleRoot).Path)
$expected = Get-CaelestiaExpectedSigningInventory -SignedInventoryPath $SignedInventoryPath `
    -VendorReviewPath $VendorReviewPath
$inventory = Get-CaelestiaSigningInventory $root
$completeness = Assert-CaelestiaReleaseCompleteness -Inventory $inventory -Expected $expected `
    -ManifestPath (Join-Path $root 'release.json')
$result = Test-CaelestiaSigningPolicy -Inventory $inventory -Channel $Channel `
    -ExpectedSignerSubject $ExpectedSignerSubject
$summary = [ordered]@{
    schemaVersion = 1
    check = 'authenticode-signatures'
    channel = $Channel
    root = Split-Path -Leaf $inventory.root
    expectedSigner = if ($Channel -eq 'stable') { $ExpectedSignerSubject } else { 'Qt vendor signature' }
    manifestFiles = $completeness.manifestFiles
    expectedSigned = $completeness.signedFiles
    expectedQt = $completeness.qtFiles
    checkedOwned = $result.checkedOwned
    checkedQt = $result.checkedQt
    otherPe = @($inventory.otherPe).Count
    passed = $result.ok
    failures = $result.failures
}
if ($SummaryPath) {
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
}
Write-Output ("Signature policy: channel=$Channel owned={0} qt={1} third-party={2} manifest={3}" -f `
        $result.checkedOwned, $result.checkedQt, @($inventory.otherPe).Count, $completeness.manifestFiles)
if (-not $result.ok) {
    foreach ($failure in $result.failures) {
        Write-Output ("FAIL {0} [{1}]: {2}" -f $failure.path, $failure.kind, ($failure.reasons -join ', '))
    }
    Write-Output ("Signature policy failed: {0} file(s) do not match the {1} channel." -f @($result.failures).Count, $Channel)
    exit 1
}
Write-Output "Signature policy passed for the $Channel channel."
exit 0
