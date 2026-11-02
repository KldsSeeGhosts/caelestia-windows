[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$root = Resolve-CaelestiaDirectory (Join-Path $env:TEMP ('caelestia-version-test-' + [guid]::NewGuid().ToString('N')))
[IO.Directory]::CreateDirectory($root) | Out-Null
$script:started = 0
$script:failStart = $false
$script:runningPaths = @()
$script:runLauncher = $false
function Get-CaelestiaProcesses([string]$Prefix) {
    foreach ($path in $script:runningPaths) { [pscustomobject]@{ Path = $path } }
}
function Get-CaelestiaSupervisors { return @() }
function New-CaelestiaLaunchTask {
    param([string]$Prefix, [switch]$PreparedSchemeRuntime)
    if (-not $PreparedSchemeRuntime) { throw 'Activation did not request the prepared scheme runtime.' }
    return 'fixture-no-task'
}
function Unregister-ScheduledTask { }
function Start-CaelestiaDetached {
    param([string]$Prefix, [switch]$LegacyReady, [string]$TaskName = '', [switch]$PreparedSchemeRuntime)
    $script:started++
    if (-not $PreparedSchemeRuntime) { throw 'Activation did not request the prepared scheme runtime.' }
    if ($script:failStart) { $script:failStart = $false; throw 'Injected startup failure.' }
    if (-not $script:runLauncher) { return }
    # Reproduce the scheduled-task handoff: the launcher runs asynchronously,
    # and the installer only waits 20 s for the shell to become ready. A cold
    # provisioner inside that launch would consume the budget and fail here.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Get-WindowsPowerShellPath
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        (Join-Path $Prefix 'Start-Caelestia.ps1') + '" -Prefix "' + $Prefix + '" -PreparedSchemeRuntime'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try { Wait-CaelestiaReady $Prefix } finally {
        if (-not $process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit() }
    }
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Payload([string]$Prefix, [string]$Label) {
    $path = Join-Path $root ('payload-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'qs.exe'), $Label)
    [IO.File]::WriteAllText((Join-Path $path 'Start-Caelestia.ps1'), 'param($Prefix,$Command = "Start") if ($Command -eq "State") { "fixture" } elseif ($Command -eq "Start") { "fixture-start" }')
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
function Get-SchemeQsFixture {
    if (-not $script:schemeQs) {
        $script:schemeQs = Join-Path $root 'scheme-qs.exe'
        Add-Type -OutputAssembly $script:schemeQs -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public static class SchemeProvisioningFixture {
    public static int Main(string[] args) {
        string command = args.Length > 0 ? args[args.Length - 1] : "";
        string ready = Path.Combine(Environment.CurrentDirectory, "shell-ready.txt");
        if (command == "state") {
            // A real shell answers only after it has rendered. The provisioner
            // must delay this marker, not the IPC probe itself.
            bool rendered = File.Exists(ready);
            Console.WriteLine("{\"lifecycle\":{\"generation\":\"scheme\",\"ready\":" +
                (rendered ? "true" : "false") + "},\"screens\":1,\"windows\":[" +
                (rendered ? "{}" : "") + "]}");
            return 0;
        }
        if (command == "quit") {
            if (File.Exists(ready)) File.Delete(ready);
            return 0;
        }
        if (command == "restart" || command == "settings") return 0;
        File.AppendAllText(Path.Combine(Environment.CurrentDirectory, "shell-started.txt"), "started\n");
        File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "shell-scheme.txt"),
            (Environment.GetEnvironmentVariable("CAELESTIA_SCHEME_PYTHON") ?? "") + "\n" +
            (Environment.GetEnvironmentVariable("CAELESTIA_SCHEME_HELPER") ?? ""));
        File.WriteAllText(ready, "ready");
        return 0;
    }
}
'@
    }
    return $script:schemeQs
}
function New-LauncherPayload([string]$Prefix, [string]$ProfileRoot, [string]$Label, [string]$ProvisionMode) {
    $path = Join-Path $root ('launcher-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    Copy-Item -LiteralPath (Get-SchemeQsFixture) -Destination (Join-Path $path 'qs.exe')
    foreach ($name in @('Start-Caelestia.ps1', 'Start-CaelestiaEntry.ps1', 'Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1', 'Uninstall-Caelestia.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $path
    }
    @'
param($StartInfo, $StateDirectory, $ConfigPath, $StdoutPath, $StderrPath)
$process = [Diagnostics.Process]::Start($StartInfo)
$null = $process.WaitForExit(5000)
[pscustomobject]@{ Watchdog = $process; StatusPath = (Join-Path $StateDirectory 'watchdog.json') }
'@ | Set-Content -LiteralPath (Join-Path $path 'Start-DesktopShell.ps1') -Encoding UTF8
    @'
param([string]$ProfileRoot)
$mode = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provision-mode.txt') -Raw).Trim()
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'scheme-provision-called.txt') -Value $mode
if ($mode -eq 'fail') { throw 'injected provisioning failure' }
Start-Sleep -Seconds 22
'{"available":true,"python":"stub","helper":"stub","message":"slow"}'
'@ | Set-Content -LiteralPath (Join-Path $path 'Install-SchemeRuntime.ps1') -Encoding UTF8
    @'
param([string]$CacheRoot)
''
'@ | Set-Content -LiteralPath (Join-Path $path 'Get-AccountPicture.ps1') -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $path 'defaults'), (Join-Path $path 'shell') | Out-Null
    foreach ($name in @('shell.json', 'keybinds.json', 'windows.json')) {
        '{}' | Set-Content -LiteralPath (Join-Path $path "defaults\$name") -Encoding UTF8
    }
    $ProvisionMode | Set-Content -LiteralPath (Join-Path $path 'provision-mode.txt') -Encoding UTF8
    @{
        product = 'caelestia-windows'; version = 1; prefix = $Prefix; profile = $ProfileRoot
        installId = 'scheme-test'; sourceRevision = $Label
        executableSha256 = (Get-FileHash (Join-Path $path 'qs.exe')).Hash
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
    # Match the Run entry: a fresh Windows PowerShell -File process, no -Prefix.
    # In-process invocation does not reproduce $PSScriptRoot parameter defaults.
    $entry = Join-Path $prefix 'Start-Caelestia.ps1'
    $output = & (Get-WindowsPowerShellPath) -NoProfile -ExecutionPolicy Bypass -File $entry
    Assert ($LASTEXITCODE -eq 0 -and $output -eq 'fixture-start') 'Sign-in launcher did not start the selected payload without -Prefix.'
    $output = & (Get-WindowsPowerShellPath) -NoProfile -ExecutionPolicy Bypass -File $entry -Command State
    Assert ($LASTEXITCODE -eq 0 -and $output -eq 'fixture') 'Installed launcher did not route State without -Prefix.'
    $output = & (Get-WindowsPowerShellPath) -NoProfile -ExecutionPolicy Bypass -File $entry -Prefix $prefix -Command State
    Assert ($LASTEXITCODE -eq 0 -and $output -eq 'fixture') 'Installed launcher did not preserve an explicit -Prefix.'
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

    # Scheme dependencies are optional and are prepared before the activation
    # handoff. Activation must never run the provisioner inside its 20 s
    # readiness budget, and a failed provisioning record must still start the
    # shell on its fixed palette instead of rolling the update back.
    $schemePrefix = Join-Path $root 'scheme-app'
    $schemeProfile = Join-Path $root 'scheme-profile'
    [IO.Directory]::CreateDirectory($schemeProfile) | Out-Null
    Write-CaelestiaProfileOwner $schemeProfile $schemePrefix 'scheme-test' $true
    $script:runLauncher = $true
    try {
        $null = Install-CaelestiaVersion $schemePrefix (New-LauncherPayload $schemePrefix $schemeProfile 'A' 'slow')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $bRuntime = Install-CaelestiaVersion $schemePrefix (New-LauncherPayload $schemePrefix $schemeProfile 'B' 'slow') -Restart
        $elapsed = $clock.Elapsed.TotalSeconds
        $record = Read-CaelestiaInstall $schemePrefix
        Assert ($record.current -eq (Split-Path -Leaf $bRuntime)) 'A cold slow provisioner rolled back the activation.'
        Assert ($elapsed -lt 15) "Activation waited $([Math]::Round($elapsed, 1)) s for the provisioner."
        Assert (Test-Path -LiteralPath (Join-Path $bRuntime 'shell-started.txt') -PathType Leaf) 'The shell did not start on the fixed palette.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $bRuntime 'scheme-provision-called.txt'))) 'Activation ran the slow provisioner.'
        $applied = Get-Content -LiteralPath (Join-Path $bRuntime 'shell-scheme.txt') -Raw
        Assert (-not $applied.Trim()) 'A cold profile passed scheme runtime paths to the shell.'
        $log = Get-Content -LiteralPath (Join-Path $schemeProfile 'logs\scheme-runtime.log') -Raw
        Assert ($log -match 'fixed palette') 'The fixed-palette fallback was not reported.'
        $exposed = $log -match [regex]::Escape($schemeProfile)
        if ($env:USERNAME) { $exposed = $exposed -or ($log -match [regex]::Escape($env:USERNAME)) }
        Assert (-not $exposed) 'The activation log exposed a user path.'
        Write-Output 'PASS scheme activation: cold slow provisioning stays out of the readiness budget.'

        $schemeRoot = Join-Path $schemeProfile 'scheme'
        New-Item -ItemType Directory -Force -Path $schemeRoot | Out-Null
        @{
            available = $false; revision = 'test'; message = 'injected provisioning failure'
            attemptedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $schemeRoot 'runtime.json') -Encoding UTF8
        $cRuntime = Install-CaelestiaVersion $schemePrefix (New-LauncherPayload $schemePrefix $schemeProfile 'C' 'fail') -Restart
        Assert ((Read-CaelestiaInstall $schemePrefix).current -eq (Split-Path -Leaf $cRuntime)) 'A provisioning failure rolled back the activation.'
        Assert (Test-Path -LiteralPath (Join-Path $cRuntime 'shell-started.txt') -PathType Leaf) 'A provisioning failure stopped the shell.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $cRuntime 'scheme-provision-called.txt'))) 'A failed record retried provisioning during activation.'
        Assert (-not (Get-Content -LiteralPath (Join-Path $cRuntime 'shell-scheme.txt') -Raw).Trim()) 'A failed record passed scheme runtime paths to the shell.'
        Write-Output 'PASS scheme failure: a failed record keeps the shell running on the fixed palette.'

        $python = Join-Path $schemeRoot 'venv\Scripts\python.exe'
        $helper = Join-Path $schemeRoot 'win_scheme.py'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $python) | Out-Null
        'fixture' | Set-Content -LiteralPath $python -Encoding UTF8
        'fixture' | Set-Content -LiteralPath $helper -Encoding UTF8
        @{
            available = $true; revision = 'test'; python = $python; helper = $helper
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $schemeRoot 'runtime.json') -Encoding UTF8
        $dRuntime = Install-CaelestiaVersion $schemePrefix (New-LauncherPayload $schemePrefix $schemeProfile 'D' 'fail') -Restart
        Assert ((Read-CaelestiaInstall $schemePrefix).current -eq (Split-Path -Leaf $dRuntime)) 'A prepared runtime rolled back the activation.'
        $applied = Get-Content -LiteralPath (Join-Path $dRuntime 'shell-scheme.txt') -Raw
        Assert ($applied -match [regex]::Escape($python) -and $applied -match [regex]::Escape($helper)) 'A prepared runtime was not passed to the shell.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $dRuntime 'scheme-provision-called.txt'))) 'A prepared runtime was provisioned again.'
        Write-Output 'PASS scheme ready: a prepared runtime reaches the shell without provisioning.'
    } finally {
        $script:runLauncher = $false
    }

    # A retained pre-versioning payload has no -PreparedSchemeRuntime parameter.
    # The stable router must drop it instead of failing parameter binding.
    $legacyRouterPrefix = Join-Path $root 'legacy-router'
    $legacyRouterVersion = Join-Path $legacyRouterPrefix 'versions\v1'
    [IO.Directory]::CreateDirectory($legacyRouterVersion) | Out-Null
    @'
param($Prefix, $Command = "Start")
"legacy-router-ok:$Command"
'@ | Set-Content -LiteralPath (Join-Path $legacyRouterVersion 'Start-Caelestia.ps1') -Encoding UTF8
    @{
        product = 'caelestia-windows'; version = 1; prefix = $legacyRouterVersion
        profile = (Join-Path $root 'legacy-router-profile'); installId = 'legacy-router'
        installRoot = $legacyRouterPrefix; versionId = 'v1'
        sourceRevision = 'legacy'; executableSha256 = 'legacy'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyRouterVersion 'install.json') -Encoding UTF8
    @{
        product = 'caelestia-windows'; version = 2; prefix = $legacyRouterPrefix
        profile = (Join-Path $root 'legacy-router-profile'); installId = 'legacy-router'
        current = 'v1'; previous = ''
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyRouterPrefix 'install.json') -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-CaelestiaEntry.ps1') -Destination (Join-Path $legacyRouterPrefix 'Start-Caelestia.ps1')
    foreach ($name in @('Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $legacyRouterPrefix
    }
    $legacyOutput = & (Join-Path $legacyRouterPrefix 'Start-Caelestia.ps1') -Prefix $legacyRouterPrefix -Command Start -PreparedSchemeRuntime
    Assert ($legacyOutput -match 'legacy-router-ok:Start') 'The router passed the prepared switch to a legacy payload.'
    Write-Output 'PASS router: a legacy payload still starts without the prepared-runtime switch.'

    # The installer phase itself is non-throwing and reports its own elapsed
    # time, so a slow or failed provisioner cannot fail the install or hide
    # behind shell readiness.
    $provisionRoot = Join-Path $root 'provision-helper'
    [IO.Directory]::CreateDirectory($provisionRoot) | Out-Null
    @'
param([string]$ProfileRoot)
Start-Sleep -Seconds 1
'{"available":true,"message":"ready"}'
'@ | Set-Content -LiteralPath (Join-Path $provisionRoot 'Install-SchemeRuntime.ps1') -Encoding UTF8
    $prepared = Install-CaelestiaSchemeRuntime $provisionRoot $schemeProfile
    Assert ($prepared.available -and $prepared.seconds -ge 1) 'Provisioning was not reported as a separate completed phase.'
    @'
param([string]$ProfileRoot)
throw 'injected provisioning failure'
'@ | Set-Content -LiteralPath (Join-Path $provisionRoot 'Install-SchemeRuntime.ps1') -Encoding UTF8
    $failedProvision = Install-CaelestiaSchemeRuntime $provisionRoot $schemeProfile
    Assert (-not $failedProvision.available -and $failedProvision.message -match 'injected provisioning failure') 'A provisioning failure escaped the installer phase.'
    Write-Output 'PASS scheme phase: installer preparation is timed separately and never throws.'

    # Migration window: an installed copy from before the Global lock holds
    # only Local\CaelestiaInstall-<key>. The new lock must take both names so
    # installation and selector writes still serialize with that copy. The
    # legacy owner runs in a separate process; mutex ownership is per thread,
    # so an in-process holder would let this same thread re-enter recursively.
    Add-Type -OutputAssembly (Join-Path $root 'legacy-install-lock.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class LegacyInstallLockFixture {
    public static int Main(string[] args) {
        using (var mutex = new Mutex(false, args[0])) {
            if (!mutex.WaitOne(0)) return 2;
            File.WriteAllText("held.txt", "held");
            var deadline = DateTime.UtcNow.AddSeconds(20);
            while (DateTime.UtcNow < deadline && !File.Exists("stop.txt")) Thread.Sleep(25);
            mutex.ReleaseMutex();
        }
        return 0;
    }
}
'@
    $lockPrefix = $prefix
    $lockExe = Join-Path $root 'legacy-install-lock.exe'
    $lockName = 'Local\CaelestiaInstall-' + (Get-CaelestiaInstallLockKey $lockPrefix)
    $heldFile = Join-Path $root 'held.txt'
    $stopFile = Join-Path $root 'stop.txt'
    $holder = Start-Process -FilePath $lockExe -ArgumentList $lockName -WorkingDirectory $root -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $heldFile) -and [DateTime]::UtcNow -lt $deadline -and -not $holder.HasExited) {
            Start-Sleep -Milliseconds 50
        }
        Assert (Test-Path -LiteralPath $heldFile) 'The legacy install lock holder did not start.'
        Assert ($null -eq (Enter-CaelestiaInstallLock $lockPrefix)) 'The new install lock ignored an old Local lock owner.'
        $refused = $false
        try { & (Join-Path $PSScriptRoot 'Manage-Caelestia.ps1') -Prefix $prefix -Command Rollback -Wait }
        catch { $refused = $_.Exception.Message -match 'already in progress' }
        Assert $refused 'The manager did not refuse a rollback while an old install held the Local lock.'
        Assert ((Read-CaelestiaInstall $prefix).current -eq $recordA.current) 'A blocked rollback still changed the selector.'
    } finally {
        [IO.File]::WriteAllText($stopFile, '')
        if (-not $holder.WaitForExit(5000)) { $holder.Kill(); $holder.WaitForExit() }
    }
    $lock = Enter-CaelestiaInstallLock $lockPrefix
    Assert ($null -ne $lock) 'The new install lock stayed blocked after the old owner exited.'
    try {
        $oldOwner = Start-Process -FilePath $lockExe -ArgumentList $lockName -WorkingDirectory $root -PassThru -Wait
        Assert ($oldOwner.ExitCode -eq 2) 'An old install could take the legacy Local lock while the new lock was held.'
    } finally { Exit-CaelestiaInstallLock $lock }
    $lock = Enter-CaelestiaInstallLock $lockPrefix
    Assert ($null -ne $lock) 'The new install lock did not release cleanly.'
    Exit-CaelestiaInstallLock $lock
    Write-Output 'PASS lock: a legacy Local owner blocks install/rollback, and the new Global+Local lock excludes it in turn.'

    # Uninstall renames the installation aside before deleting it, so a locked
    # file leaves the installation intact and still resolvable instead of
    # half-deleted. The same test then uninstalls cleanly and leaves no tombstone.
    $lockedApp = Join-Path $root 'locked-app'
    $null = Install-CaelestiaVersion $lockedApp (New-Payload $lockedApp 'locked')
    $held = Join-Path $lockedApp 'held.bin'
    [IO.File]::WriteAllText($held, 'held')
    $heldStream = [IO.File]::Open($held, 'Open', 'Read', 'None')
    try {
        $refused = $false
        try { & (Join-Path $PSScriptRoot 'Uninstall-Caelestia.ps1') -Prefix $lockedApp }
        catch { $refused = $_.Exception.Message -match 'still in use' }
        Assert $refused 'Uninstall did not refuse an installation with an open file.'
        Assert (Test-Path -LiteralPath (Join-Path $lockedApp 'install.json')) 'A locked uninstall damaged the installation.'
        Assert (@(Get-ChildItem -LiteralPath $root -Directory -Filter 'locked-app.uninstall-*').Count -eq 0) 'A locked uninstall left a tombstone.'
    } finally { $heldStream.Dispose() }
    $null = & (Join-Path $PSScriptRoot 'Uninstall-Caelestia.ps1') -Prefix $lockedApp
    Assert (-not (Test-Path -LiteralPath $lockedApp)) 'Uninstall left the prefix.'
    Assert (@(Get-ChildItem -LiteralPath $root -Directory -Filter 'locked-app.uninstall-*').Count -eq 0) 'Uninstall left a tombstone.'
    Write-Output 'PASS uninstall: a locked installation is unchanged; a clean run removes prefix and tombstone.'
} finally {
    $safe = Resolve-CaelestiaDirectory $root
    if ((Split-Path -Parent $safe) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -or
        (Split-Path -Leaf $safe) -notlike 'caelestia-version-test-*') { throw 'Unsafe test cleanup.' }
    Assert-CaelestiaNoReparsePoints $safe
    Remove-Item -LiteralPath $safe -Recurse -Force
}
