[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$root = Resolve-CaelestiaDirectory (Join-Path $env:TEMP ('caelestia-version-test-' + [guid]::NewGuid().ToString('N')))
[IO.Directory]::CreateDirectory($root) | Out-Null
$script:started = 0
$script:failStart = $false
$script:runningPaths = @()
function Get-CaelestiaProcesses([string]$Prefix) {
    foreach ($path in $script:runningPaths) { [pscustomobject]@{ Path = $path } }
}
function Get-CaelestiaSupervisors { return @() }
function New-CaelestiaLaunchTask { return 'fixture-no-task' }
function Unregister-ScheduledTask { }
function Start-CaelestiaDetached {
    $script:started++
    if ($script:failStart) { $script:failStart = $false; throw 'Injected startup failure.' }
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Payload([string]$Prefix, [string]$Label) {
    $path = Join-Path $root ('payload-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'qs.exe'), $Label)
    [IO.File]::WriteAllText((Join-Path $path 'Start-Caelestia.ps1'), 'param($Prefix,$Command) if ($Command -eq "State") { "fixture" }')
    foreach ($name in @('Start-CaelestiaEntry.ps1', 'Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1', 'Uninstall-Caelestia.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $path
    }
    @{
        product = 'caelestia-windows'; version = 1; prefix = $Prefix
        profile = (Join-Path $root 'profile'); installId = 'version-test'
        sourceRevision = $Label; executableSha256 = (Get-FileHash (Join-Path $path 'qs.exe')).Hash
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $path 'install.json') -Encoding UTF8
    return $path
}
try {
    $prefix = Join-Path $root 'app'
    $a = Install-CaelestiaVersion $prefix (New-Payload $prefix 'A')
    $recordA = Read-CaelestiaInstall $prefix
    $aHash = (Get-FileHash (Join-Path $a 'install.json')).Hash
    Assert ($recordA.version -eq 2 -and (Resolve-CaelestiaRuntimePrefix $prefix) -eq $a) 'Fresh install is not routed to its version.'
    Assert ((& (Join-Path $PSScriptRoot 'Start-Caelestia.ps1') -Prefix $prefix -Command State) -eq 'fixture') 'Repository launcher did not route to the selected payload.'
    $failed = $false
    try { Install-CaelestiaVersion $a (New-Payload $a 'nested') } catch { $failed = $_ -match 'immutable version directory' }
    Assert $failed 'An immutable payload was accepted as an install root.'
    $b = Install-CaelestiaVersion $prefix (New-Payload $prefix 'B')
    $recordB = Read-CaelestiaInstall $prefix
    Assert ($recordB.previous -eq $recordA.current) 'Update did not retain its previous version.'
    Assert ((Get-FileHash (Join-Path $a 'install.json')).Hash -eq $aHash) 'Published metadata was modified.'
    $script:runningPaths = @((Join-Path $a 'qs.exe'))
    Assert ((Resolve-CaelestiaRuntimePrefix $prefix -Running) -eq $a) 'IPC does not route to the actually running version.'
    $script:runningPaths = @()
    Switch-CaelestiaVersion $prefix $recordA.current
    Assert ((Read-CaelestiaInstall $prefix).current -eq $recordA.current) 'Rollback did not select A.'
    Assert ((Read-CaelestiaInstall $prefix).previous -eq $recordB.current) 'Rollback cannot return to B.'

    $script:failStart = $true
    $failed = $false
    try { Install-CaelestiaVersion $prefix (New-Payload $prefix 'broken') -Restart } catch { $failed = $_ -match 'Injected startup failure' }
    Assert $failed 'Injected activation failure was hidden.'
    Assert ((Read-CaelestiaInstall $prefix).current -eq $recordA.current) 'Failed activation did not restore A.'
    Assert ((Read-CaelestiaInstall $prefix).previous -eq $recordB.current) 'Failed activation lost previous-version history.'
    $status = & (Join-Path $prefix 'Manage-Caelestia.ps1') -Prefix $prefix -Command Status | ConvertFrom-Json
    Assert ($status.schema -eq 1 -and $status.current -eq $recordA.current -and $status.canRollback) 'Settings status does not match the selector.'
    $failed = $false
    try { & (Join-Path $prefix 'Manage-Caelestia.ps1') -Prefix $prefix -Command Rollback -ExpectedCurrent $recordB.current }
    catch { $failed = $_ -match 'selected version changed' }
    Assert $failed 'A stale UI request was allowed to queue rollback.'

    $script:failStart = $true
    $failed = $false
    try { Switch-CaelestiaVersion $prefix $recordB.current -Restart } catch { $failed = $_ -match 'Injected startup failure' }
    Assert ($failed -and (Read-CaelestiaInstall $prefix).current -eq $recordA.current) 'Failed rollback did not restore selector.'
    foreach ($id in @('..\escape', '..', 'C:\escape', 'a/b')) {
        $failed = $false
        try { Get-CaelestiaVersionPrefix $prefix $id } catch { $failed = $true }
        Assert $failed 'Escaping version identifier accepted.'
    }
    $failed = $false
    try { Publish-CaelestiaPayload $prefix (New-Payload $prefix 'overwrite') $recordA.current } catch { $failed = $_ -match 'immutable' }
    Assert $failed 'Published version was overwritten.'
    $unused = Get-ChildItem (Join-Path $prefix 'versions') -Directory | Where-Object Name -notin @($recordA.current, $recordB.current) | Select-Object -First 1
    $script:runningPaths = @((Join-Path $unused.FullName 'qs.exe'))
    Remove-CaelestiaRetiredVersions $prefix
    Assert (Test-Path -LiteralPath $unused.FullName) 'Retention removed a running version.'
    $script:runningPaths = @()
    Remove-CaelestiaRetiredVersions $prefix
    Assert ((Get-ChildItem (Join-Path $prefix 'versions') -Directory).Count -eq 2) 'Retention did not keep exactly current and previous.'
    Assert (Test-Path -LiteralPath $a) 'Retention removed the active payload.'
    Assert (Test-Path -LiteralPath $b) 'Retention removed the previous payload.'
    $linkedRoot = Join-Path $root 'linked-app'
    $outside = Join-Path $root 'link-target'
    [IO.Directory]::CreateDirectory($linkedRoot) | Out-Null
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $junction = Join-Path $linkedRoot 'versions'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    try {
        $failed = $false
        try { Publish-CaelestiaPayload $linkedRoot (New-Payload $linkedRoot 'linked') 'version' }
        catch { $failed = $_ -match 'reparse point' }
        Assert $failed 'Publishing followed a versions junction.'
        Assert (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'Publishing wrote through a junction.'
    } finally {
        # Delete only this test's junction, not its target or contents.
        [IO.Directory]::Delete($junction, $false)
    }
    Write-Output 'PASS versioned: immutable payloads, running-version routing, rollback/roll-forward, activation failure and traversal refusal.'

    foreach ($injectFailure in @($false, $true)) {
        $legacy = Join-Path $root ('legacy-' + $injectFailure)
        $legacyPayload = New-Payload $legacy 'legacy-original'
        [IO.Directory]::Move($legacyPayload, $legacy)
        $script:failStart = $injectFailure
        try { $null = Install-CaelestiaVersion $legacy (New-Payload $legacy 'migrated') -Restart }
        catch { if (-not $injectFailure -or $_ -notmatch 'Injected startup failure') { throw } }
        $record = Read-CaelestiaInstall $legacy
        Assert ($record.version -eq 2) 'Legacy root did not migrate.'
        $runtime = Resolve-CaelestiaRuntimePrefix $legacy
        $expected = if ($injectFailure) { 'legacy-original' } else { 'migrated' }
        Assert ([IO.File]::ReadAllText((Join-Path $runtime 'qs.exe')) -eq $expected) 'Legacy migration/rollback selected wrong bytes.'
        Assert ((Get-ChildItem (Join-Path $legacy 'versions') -Directory).Count -eq 2) 'Legacy copy recursed into versions.'
    }
    Write-Output 'PASS migration: legacy payload retained without recursion; failed first version falls back to migrated legacy.'
} finally {
    $safe = Resolve-CaelestiaDirectory $root
    if ((Split-Path -Parent $safe) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -or
        (Split-Path -Leaf $safe) -notlike 'caelestia-version-test-*') { throw 'Unsafe test cleanup.' }
    Assert-CaelestiaNoReparsePoints $safe
    Remove-Item -LiteralPath $safe -Recurse -Force
}
