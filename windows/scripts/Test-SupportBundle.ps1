[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $output -Force
$prior = $env:CAELESTIA_SUPPORT_TEST_OUTPUT
try {
    $env:CAELESTIA_SUPPORT_TEST_OUTPUT = $output
    & node --test (Join-Path $PSScriptRoot '..\tests\support-bundle\support-bundle.test.js')
    if ($LASTEXITCODE -ne 0) { throw 'Support bundle fixtures failed; retained synthetic evidence is in the selected output directory.' }
} finally {
    $env:CAELESTIA_SUPPORT_TEST_OUTPUT = $prior
}
