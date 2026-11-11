# Test-only, imported into instrumented copies outside source/production paths.
# Real crypto, bounded copy/extraction, maintenance args and install transaction;
# recording network/task/native/readiness/integration boundaries only.
. (Join-Path $PSScriptRoot 'UninstallTransaction-FixtureBoundary.ps1')
function Get-CaelestiaAutostartKey { Join-Path $env:CAELESTIA_FIXTURE_CASE 'integration' }
function Get-CaelestiaUpdateStatePath { Join-Path $env:CAELESTIA_FIXTURE_CASE 'trust\highwater.json' }
function Complete-CaelestiaInstallIntegration {
    param($Prefix, $Runtime, $Previous, [switch]$Restart, [switch]$Autostart, [switch]$DesktopShortcut)
    Assert-FixturePrefix $Prefix
    if (-not $Restart -or -not $Autostart) { throw 'Existing fixture autostart opt-in was not preserved.' }
    Invoke-FixtureBoundary 'complete-integration'
}
$script:nexusRealCheck = (Get-Command Invoke-CaelestiaUpdateCheck).ScriptBlock
$script:nexusRealSave = (Get-Command Save-CaelestiaUpdateBundle).ScriptBlock
$script:nexusRealWriteJson = (Get-Command Write-CaelestiaJsonAtomic).ScriptBlock
function Write-CaelestiaJsonAtomic([string]$Path, $Value) {
    & $script:nexusRealWriteJson $Path $Value
    if ((Split-Path -Leaf $Path) -eq 'update-operation.json') {
        Add-Content -LiteralPath (Join-Path $env:CAELESTIA_FIXTURE_CONTROL 'progress.jsonl') `
            -Value ($Value | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
    }
}
function Invoke-CaelestiaUpdateCheck($Trust, $Channel, $CurrentVersion, $StatePath) {
    & $script:nexusRealCheck $Trust $Channel $CurrentVersion $StatePath {
        param($Address, $Milliseconds)
        $name = if ($Address.EndsWith('/keys.dsse.json')) { 'keys.dsse.json' } else { 'development.dsse.json' }
        return ,([IO.File]::ReadAllBytes((Join-Path $env:CAELESTIA_FIXTURE_CASE "metadata\$name")))
    }
}
function Save-CaelestiaUpdateBundle($Release, $Trust, $Directory, [scriptblock]$Progress) {
    & $script:nexusRealSave $Release $Trust $Directory {
        param($Address, $Hosts, $Redirects, $Cap, $Size, $Hash, $Destination, $Milliseconds, $Report)
        Invoke-FixtureBoundary 'download'
        $inputStream = [IO.File]::OpenRead((Join-Path $env:CAELESTIA_FIXTURE_CASE 'download.zip'))
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
        try {
            [Caelestia.Update.Transport]::CopyBounded($inputStream, $outputStream, $Cap, $Size, $Hash,
                [Threading.CancellationToken]::None, [Action[long,long]]$Report)
        } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    } -Progress $Progress
}
