#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-InstallCommon.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-updates-status-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$count = 0
function Assert($Value, [string]$Message) {
    if (-not $Value) { throw $Message }
    $script:count++
}
try {
    foreach ($kind in @('legacy', 'single', 'retained')) {
        $prefix = Join-Path $root $kind
        [IO.Directory]::CreateDirectory($prefix) | Out-Null
        $base = @{product = 'caelestia-windows'; version = 1; prefix = $prefix
            profile = (Join-Path $root 'profile'); installId = 'synthetic-status-owner'
            sourceRevision = 'fixture-current'}
        if ($kind -eq 'legacy') {
            Write-CaelestiaJsonAtomic (Join-Path $prefix 'install.json') $base
        } else {
            foreach ($id in @('current-fixture', 'retained-fixture')) {
                $runtime = Join-Path $prefix "versions\$id"
                [IO.Directory]::CreateDirectory($runtime) | Out-Null
                $payload = $base.Clone()
                $payload.prefix = $runtime
                $payload.installRoot = $prefix
                $payload.versionId = $id
                $payload.sourceRevision = $id
                Write-CaelestiaJsonAtomic (Join-Path $runtime 'install.json') $payload
            }
            $base.version = 2
            $base.current = 'current-fixture'
            $base.previous = $(if ($kind -eq 'retained') { 'retained-fixture' } else { '' })
            Write-CaelestiaJsonAtomic (Join-Path $prefix 'install.json') $base
        }
        $before = @(Get-ChildItem -LiteralPath $prefix -File -Recurse |
            Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ','
        $status = & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -File "$PSScriptRoot\Manage-Caelestia.ps1" `
            -Prefix $prefix -Command Status | ConvertFrom-Json
        Assert ($LASTEXITCODE -eq 0) 'Status command failed on a recognized synthetic installation.'
        Assert ($status.schema -eq 1) 'Status schema changed unexpectedly.'
        Assert ($status.manualReleaseUrl -eq 'https://github.com/KldsSeeGhosts/caelestia-windows/releases') 'Wrong manual release destination.'
        Assert ($status.remoteVersionChecked -eq $false -and $null -eq $status.latestVersion) 'Status invented a remote version result.'
        Assert ($status.automaticUpdatesAvailable -eq $false -and $status.downloadChannelAvailable -eq $false) 'Status claimed an automatic updater.'
        Assert ($status.canRollback -eq ($kind -eq 'retained')) 'Rollback availability does not follow the retained version.'
        Assert (($kind -eq 'retained') -eq ($status.previous -ne '')) 'Retained version identity is inconsistent.'
        Assert ($status.sourceRevision -eq $(if ($kind -eq 'legacy') { 'fixture-current' } else { 'current-fixture' })) 'Installed revision was lost.'
        $after = @(Get-ChildItem -LiteralPath $prefix -File -Recurse |
            Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ','
        Assert ($after -eq $before) 'Status mutated the synthetic installation.'
    }
    Write-Output "PASS updates Status contract: $count assertions, three synthetic installation states."
} finally {
    $resolved = Resolve-CaelestiaDirectory $root
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or
        (Split-Path -Leaf $resolved) -notlike 'caelestia-updates-status-*') { throw 'Unsafe updates fixture cleanup.' }
    Assert-CaelestiaNoReparsePoints $resolved
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
