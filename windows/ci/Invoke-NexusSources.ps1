#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Privacy')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Privacy')][string]$Transfer,
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][string]$SourceRoot,
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][string]$SourceRevision,
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][string]$OutputDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][string]$CacheDirectory
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Caelestia-Toolchain.ps1"
Initialize-CaelestiaToolchainModules
if ($PSCmdlet.ParameterSetName -eq 'Prepare') {
    & "$PSScriptRoot\..\scripts\Prepare-CaelestiaSourceAssets.ps1" -SourceRoot $SourceRoot `
        -SourceRevision $SourceRevision -OutputDirectory $OutputDirectory -CacheDirectory $CacheDirectory
    return
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    "$PSScriptRoot\..\scripts\New-CaelestiaRelease.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Source privacy scanner source failed to parse.' }
$scanner = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ReleaseFilePrivacy'
}, $true)
if (-not $scanner) { throw 'Missing reviewed source privacy scanner.' }
. ([scriptblock]::Create($scanner.Extent.Text))
. "$PSScriptRoot\..\scripts\Caelestia-ReleasePrivacy.ps1"
$files = @(Get-ChildItem -LiteralPath $Transfer -Recurse -File -Force | Where-Object Extension -ne '.zip')
foreach ($flags in @(Invoke-CaelestiaReleasePrivacyScan -Files $files -PrivateRoots @(
    $Transfer, (Split-Path -Parent $Transfer), (Resolve-Path "$PSScriptRoot\..\..").Path, $env:USERPROFILE) `
    -ScannerDefinition ${function:Get-ReleaseFilePrivacy}.ToString())) {
    if ($flags.Sensitive -or $flags.GenericPath) { throw 'Prepared source metadata or notice privacy refused.' }
}
