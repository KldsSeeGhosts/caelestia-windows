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
    if ($env:CAELESTIA_TEST_PROVISION_LOG) {
        Add-Content -LiteralPath $env:CAELESTIA_TEST_PROVISION_LOG -Value ('{0},0,launch' -f [DateTime]::UtcNow.Ticks)
    }
    if (-not $PreparedSchemeRuntime) { throw 'Activation did not request the prepared scheme runtime.' }
    if ($script:failStart) {
        $script:failStart = $false
        # Optionally break the fallback payload at the moment its activation is
        # needed, so the catch must reselect instead of launching it.
        if ($script:breakFallbackPayload) {
            'broken payload' | Set-Content -LiteralPath (Join-Path $script:breakFallbackPayload 'install.json') -Encoding UTF8
            $script:breakFallbackPayload = $null
        }
        throw 'Injected startup failure.'
    }
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
            (Environment.GetEnvironmentVariable("CAELESTIA_SCHEME_HELPER") ?? "") + "\n" +
            (Environment.GetEnvironmentVariable("CAELESTIA_WE_PYTHON") ?? ""));
        File.WriteAllText(ready, "ready");
        return 0;
    }
}
'@
    }
    return $script:schemeQs
}
function Get-FakePythonFixture {
    if (-not $script:fakePython) {
        $directory = Join-Path $root 'fake-python'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $script:fakePython = Join-Path $directory 'py.exe'
        Add-Type -OutputAssembly $script:fakePython -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public static class FakeSchemePython {
    static void Log(string ev) {
        string path = Environment.GetEnvironmentVariable("CAELESTIA_TEST_PROVISION_LOG");
        if (String.IsNullOrEmpty(path)) return;
        try { File.AppendAllText(path, DateTime.UtcNow.Ticks + "," + Process.GetCurrentProcess().Id + "," + ev + "\n"); } catch {}
    }
    public static int Main(string[] args) {
        string exe = Process.GetCurrentProcess().MainModule.FileName;
        if (Path.GetFileName(exe).Equals("py.exe", StringComparison.OrdinalIgnoreCase)) {
            // Any start of the launcher is logged; the stall models a slow or
            // hung interpreter discovery.
            Log("py-launcher");
            int launcherSeconds = 0;
            Int32.TryParse(Environment.GetEnvironmentVariable("CAELESTIA_TEST_PY_LAUNCHER_SECONDS"), out launcherSeconds);
            if (launcherSeconds > 0) Thread.Sleep(launcherSeconds * 1000);
        }
        for (int i = 0; i + 2 < args.Length; i++) {
            if (args[i] == "-m" && args[i + 1] == "venv") {
                string venv = args[i + 2];
                Directory.CreateDirectory(Path.Combine(venv, "Scripts"));
                Directory.CreateDirectory(Path.Combine(venv, "Lib", "site-packages"));
                File.Copy(exe, Path.Combine(venv, "Scripts", "python.exe"), true);
                File.WriteAllText(Path.Combine(venv, "pyvenv.cfg"), "home = " + Path.GetDirectoryName(exe) + "\r\n");
                Log("venv");
                return 0;
            }
        }
        for (int i = 0; i + 1 < args.Length; i++) {
            if (args[i] == "-m" && args[i + 1] == "pip") {
                Log("pip-start");
                string failText = Environment.GetEnvironmentVariable("CAELESTIA_TEST_PIP_FAIL");
                if (!String.IsNullOrEmpty(failText)) {
                    Console.Error.WriteLine("ERROR: could not open " + failText);
                    return 1;
                }
                int seconds = 1;
                string raw = Environment.GetEnvironmentVariable("CAELESTIA_TEST_PIP_SECONDS");
                if (!String.IsNullOrEmpty(raw)) Int32.TryParse(raw, out seconds);
                Thread.Sleep(Math.Max(0, seconds) * 1000);
                Log("pip-end");
                return 0;
            }
        }
        for (int i = 0; i + 1 < args.Length; i++) {
            if (args[i] == "-c") {
                string code = args[i + 1];
                if (code.Contains("site.getsitepackages")) {
                    string venv = Path.GetDirectoryName(Path.GetDirectoryName(exe));
                    Console.WriteLine(Path.Combine(venv, "Lib", "site-packages"));
                } else if (code.Contains("sys.executable")) {
                    Console.WriteLine(exe);
                }
                Log("check");
                // A hang.txt next to this python makes only this generation hang.
                if (File.Exists(Path.Combine(Path.GetDirectoryName(exe), "hang.txt"))) Thread.Sleep(30000);
                int wait = 0;
                Int32.TryParse(Environment.GetEnvironmentVariable("CAELESTIA_TEST_CHECK_SECONDS"), out wait);
                if (wait > 0) Thread.Sleep(wait * 1000);
                int exitCode = 0;
                Int32.TryParse(Environment.GetEnvironmentVariable("CAELESTIA_TEST_CHECK_EXIT"), out exitCode);
                return exitCode;
            }
        }
        Log("other");
        return 0;
    }
}
'@
        # The venv launcher follows pyvenv.cfg's home to a python.exe.
        Copy-Item -LiteralPath $script:fakePython -Destination (Join-Path $directory 'python.exe')
    }
    return $script:fakePython
}
function Read-SchemeResult([string]$Path) {
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if (-not $lines.Count) { return $null }
    try { return ($lines[-1] | ConvertFrom-Json) } catch { return $null }
}
function Get-DirectoryHash([string]$Directory) {
    $builder = [Text.StringBuilder]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Recurse -File | Sort-Object FullName)) {
        $null = $builder.Append($file.FullName.Substring($Directory.Length + 1))
        $null = $builder.Append(':')
        $null = $builder.Append((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
        $null = $builder.Append("`n")
    }
    return $builder.ToString()
}
# A generation whose interpreter is the fake python, with its own base
# interpreter directory so a test can break it. Created sets the directory's
# creation time, which orders generations of one identity.
function New-TestGeneration([string]$Runtimes, [string]$Name, [string]$Revision, [string]$IdentityId, [object]$Created = $null, [switch]$BrokenBase) {
    $generationRoot = Join-Path $Runtimes $Name
    $scripts = Join-Path $generationRoot 'venv\Scripts'
    $baseDirectory = Join-Path $generationRoot 'base'
    New-Item -ItemType Directory -Force -Path $scripts, $baseDirectory | Out-Null
    $fake = Get-FakePythonFixture
    Copy-Item -LiteralPath $fake -Destination (Join-Path $scripts 'python.exe')
    if (-not $BrokenBase) { Copy-Item -LiteralPath $fake -Destination (Join-Path $baseDirectory 'python.exe') }
    [IO.File]::WriteAllText((Join-Path $generationRoot 'venv\pyvenv.cfg'), "home = $baseDirectory`r`n")
    'fixture' | Set-Content -LiteralPath (Join-Path $generationRoot 'win_scheme.py') -Encoding UTF8
    @{ revision = $Revision; generation = $Name; identity = $IdentityId } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $generationRoot 'generation.json') -Encoding UTF8
    if ($Created) { (Get-Item -LiteralPath $generationRoot).CreationTimeUtc = $Created }
    return $generationRoot
}
function Read-Pointer([string]$ProfileRoot) {
    return (Get-Content -LiteralPath (Join-Path $ProfileRoot 'scheme\runtime.json') -Raw | ConvertFrom-Json)
}
# Production activation selects before the stop and publishes that decision
# with the setter afterwards. Tests that need a fresh probe follow the same
# two-step path; the setter itself can no longer start a process.
function Update-SchemeRuntimeForRevision([string]$ProfileRoot, [string]$Revision, [string]$RuntimePrefix = '', [int]$BudgetSeconds = $script:CaelestiaSchemeProbeBudgetSeconds, [int]$CandidateSeconds = $script:CaelestiaSchemeProbeSliceSeconds) {
    $decision = Select-CaelestiaSchemeGeneration $ProfileRoot $Revision $RuntimePrefix $BudgetSeconds $CandidateSeconds
    return Set-CaelestiaSchemeRuntimeForRevision $ProfileRoot $Revision $RuntimePrefix -Verified $decision
}
# Names and sizes only, so a file held open exclusively can still be compared.
function Get-DirectoryListing([string]$Directory) {
    return ((Get-ChildItem -LiteralPath $Directory -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Directory.Length + 1) + ':' + $_.Length
    }) -join "`n")
}
# The shell was stopped at the 'quit' event and relaunched at 'launch'. After
# the stop nothing may be probed, and the stopped interval, which has no probe
# time in it, must stay small.
function Assert-NoPostQuitProbe([string]$Log, [string]$What, [double]$MaxStopped = 3, [switch]$LastLaunch, [switch]$NoProbesExpected) {
    $events = @(Get-Content -LiteralPath $Log | ForEach-Object {
        $parts = $_ -split ','
        [pscustomobject]@{ Ticks = [long]$parts[0]; Event = $parts[2] }
    })
    $quit = $events | Where-Object { $_.Event -eq 'quit' } | Select-Object -First 1
    Assert ($null -ne $quit) "$What never stopped the old shell."
    $launches = @($events | Where-Object { $_.Event -eq 'launch' -and $_.Ticks -ge $quit.Ticks })
    Assert ($launches.Count -ge 1) "$What never relaunched the shell."
    $launch = if ($LastLaunch) { $launches[-1] } else { $launches[0] }
    if ($NoProbesExpected) {
        Assert (@($events | Where-Object { $_.Event -eq 'check' }).Count -eq 0) "$What probed a generation although the scheme lock was busy."
    } else {
        Assert (@($events | Where-Object { $_.Event -eq 'check' -and $_.Ticks -lt $quit.Ticks }).Count -ge 1) "$What did not probe before stopping the shell."
    }
    Assert (@($events | Where-Object { $_.Event -eq 'check' -and $_.Ticks -gt $quit.Ticks }).Count -eq 0) "$What probed a generation after the shell had stopped."
    $stopped = ($launch.Ticks - $quit.Ticks) / 1e7
    Assert ($stopped -lt $MaxStopped) "$What left the shell stopped for $([Math]::Round($stopped, 1)) s."
}
function New-LauncherPayload([string]$Prefix, [string]$ProfileRoot, [string]$Label, [string]$ProvisionMode, [switch]$LegacyStart) {
    $path = Join-Path $root ('launcher-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    Copy-Item -LiteralPath (Get-SchemeQsFixture) -Destination (Join-Path $path 'qs.exe')
    foreach ($name in @('Start-CaelestiaEntry.ps1', 'Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1', 'Uninstall-Caelestia.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $path
    }
    if ($LegacyStart) {
        @'
[CmdletBinding()]
param([string]$Prefix, [string]$Command = 'Start', [switch]$SkipSchemeRuntime)
if ($Command -eq 'Quit' -and $env:CAELESTIA_TEST_PROVISION_LOG) { Add-Content -LiteralPath $env:CAELESTIA_TEST_PROVISION_LOG -Value ("{0},0,quit" -f [DateTime]::UtcNow.Ticks) }
if ($Command -ne 'Start') { return }
if (-not $SkipSchemeRuntime) {
    $null = & (Join-Path $PSScriptRoot 'Install-SchemeRuntime.ps1') -ProfileRoot (Join-Path $PSScriptRoot 'fixture-profile.txt') -LockWaitSeconds 0
}
'started' | Set-Content -LiteralPath (Join-Path $Prefix 'shell-started.txt') -Encoding UTF8
'' | Set-Content -LiteralPath (Join-Path $Prefix 'shell-scheme.txt') -Encoding UTF8
'ready' | Set-Content -LiteralPath (Join-Path $Prefix 'shell-ready.txt') -Encoding UTF8
'@ | Set-Content -LiteralPath (Join-Path $path 'Start-Caelestia.ps1') -Encoding UTF8
    } else {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-Caelestia.ps1') -Destination $path
    }
    @'
param($StartInfo, $StateDirectory, $ConfigPath, $StdoutPath, $StderrPath)
$process = [Diagnostics.Process]::Start($StartInfo)
$null = $process.WaitForExit(5000)
[pscustomobject]@{ Watchdog = $process; StatusPath = (Join-Path $StateDirectory 'watchdog.json') }
'@ | Set-Content -LiteralPath (Join-Path $path 'Start-DesktopShell.ps1') -Encoding UTF8
    @'
[CmdletBinding()]
param([string]$ProfileRoot, [int]$LockWaitSeconds = 0)
$mode = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provision-mode.txt') -Raw).Trim()
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'scheme-provision-called.txt') -Value $mode
if ($mode -eq 'fail') { throw 'injected provisioning failure' }
Start-Sleep -Seconds 22
'{"available":true,"revision":"test","generation":"stub","python":"stub","helper":"stub","message":"slow"}'
'@ | Set-Content -LiteralPath (Join-Path $path 'Install-SchemeRuntime.ps1') -Encoding UTF8
    @'
param([string]$CacheRoot)
''
'@ | Set-Content -LiteralPath (Join-Path $path 'Get-AccountPicture.ps1') -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $path 'defaults'), (Join-Path $path 'shell'), (Join-Path $path 'licenses'), (Join-Path $path 'scheme') | Out-Null
    foreach ($name in @('shell.json', 'keybinds.json', 'windows.json')) {
        '{}' | Set-Content -LiteralPath (Join-Path $path "defaults\$name") -Encoding UTF8
    }
    '{"schemeCli":{"revision":"test"}}' | Set-Content -LiteralPath (Join-Path $path 'licenses\sources.lock.json') -Encoding UTF8
    'fixture-helper' | Set-Content -LiteralPath (Join-Path $path 'scheme\win_scheme.py') -Encoding UTF8
    'fixture-requirements' | Set-Content -LiteralPath (Join-Path $path 'scheme\requirements.lock.txt') -Encoding UTF8
    'fixture-shim' | Set-Content -LiteralPath (Join-Path $path 'scheme\fcntl.py') -Encoding UTF8
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
    $beforeNested = Get-DirectoryHash $a
    try { Install-CaelestiaVersion $a (New-Payload $a 'nested') } catch { $failed = $true }
    Assert $failed 'An immutable payload was accepted as an install root.'
    Assert ((Get-DirectoryHash $a) -eq $beforeNested) 'A refused nested install modified the immutable payload.'
    Assert ((Read-CaelestiaInstall $prefix).current -eq $recordA.current) 'A refused nested install changed the selector.'
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
    try { Install-CaelestiaVersion $prefix (New-Payload $prefix 'broken') -Restart } catch { $failed = $true }
    Assert ($failed -and -not $script:failStart) 'Injected activation failure was hidden or never reached.'
    Assert ((Read-CaelestiaInstall $prefix).current -eq $recordA.current) 'Failed activation did not restore A.'
    Assert ((Read-CaelestiaInstall $prefix).previous -eq $recordB.current) 'Failed activation lost previous-version history.'
    $status = & (Join-Path $prefix 'Manage-Caelestia.ps1') -Prefix $prefix -Command Status | ConvertFrom-Json
    Assert ($status.schema -eq 1 -and $status.current -eq $recordA.current -and $status.canRollback) 'Settings status does not match the selector.'
    $failed = $false
    try { & (Join-Path $prefix 'Manage-Caelestia.ps1') -Prefix $prefix -Command Rollback -ExpectedCurrent $recordB.current }
    catch { $failed = $true }
    Assert $failed 'A stale UI request was allowed to queue rollback.'
    Assert ((Read-CaelestiaInstall $prefix).current -eq $recordA.current) 'A stale UI request changed the selector.'

    $script:failStart = $true
    $failed = $false
    try { Switch-CaelestiaVersion $prefix $recordB.current -Restart } catch { $failed = $true }
    Assert ($failed -and -not $script:failStart -and (Read-CaelestiaInstall $prefix).current -eq $recordA.current) 'Failed rollback did not restore selector.'

    # A queued rollback whose task dies must not leave Settings > Updates in a
    # permanent working phase. The deadline watchdog records the failure the
    # page observes, and only for its own operation.
    $operationFile = Join-Path $root 'profile\state\update-operation.json'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($operationFile)) | Out-Null
    $watchId = [guid]::NewGuid().ToString('N')
    @{ schema = 1; operationId = $watchId; phase = 'working' } |
        ConvertTo-Json | Set-Content -LiteralPath $operationFile -Encoding UTF8
    & (Join-Path $PSScriptRoot 'Manage-Caelestia.ps1') -Prefix $prefix -Command Watch -OperationId $watchId
    $expired = Get-Content -LiteralPath $operationFile -Raw | ConvertFrom-Json
    Assert ($expired.phase -eq 'failed' -and $expired.operationId -eq $watchId) 'A working rollback with a dead task never failed.'
    @{ schema = 1; operationId = $watchId; phase = 'complete' } |
        ConvertTo-Json | Set-Content -LiteralPath $operationFile -Encoding UTF8
    & (Join-Path $PSScriptRoot 'Manage-Caelestia.ps1') -Prefix $prefix -Command Watch -OperationId $watchId
    Assert ((Get-Content -LiteralPath $operationFile -Raw | ConvertFrom-Json).phase -eq 'complete') 'The deadline watchdog changed a completed rollback.'
    $otherId = [guid]::NewGuid().ToString('N')
    @{ schema = 1; operationId = $otherId; phase = 'working' } |
        ConvertTo-Json | Set-Content -LiteralPath $operationFile -Encoding UTF8
    & (Join-Path $PSScriptRoot 'Manage-Caelestia.ps1') -Prefix $prefix -Command Watch -OperationId $watchId
    Assert ((Get-Content -LiteralPath $operationFile -Raw | ConvertFrom-Json).phase -eq 'working') 'A deadline watchdog expired another operation.'
    # The queued path schedules the bound itself: the worker task and a separate
    # watchdog one deadline later, so a task that dies after 'queued' is ended.
    $global:queuedTasks = [Collections.ArrayList]::new()
    $queued = & {
        function New-ScheduledTaskAction {
            param($Execute, $WorkingDirectory, $Argument)
            [pscustomobject]@{ Execute = $Execute; WorkingDirectory = $WorkingDirectory; Argument = $Argument }
        }
        function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return $null }
        function New-ScheduledTaskSettingsSet {
            param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $ExecutionTimeLimit)
            [pscustomobject]@{ ExecutionTimeLimit = $ExecutionTimeLimit }
        }
        function New-ScheduledTaskTrigger { param([switch]$Once, $At) [pscustomobject]@{ At = $At } }
        function Register-ScheduledTask {
            param($TaskName, $Action, $Trigger, $Principal, $Settings, $ErrorAction)
            $null = $global:queuedTasks.Add([pscustomobject]@{ Name = $TaskName; Action = $Action; Trigger = $Trigger; Settings = $Settings })
        }
        function Start-ScheduledTask { param($TaskName, $ErrorAction) }
        function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm, $ErrorAction) }
        & (Join-Path $PSScriptRoot 'Manage-Caelestia.ps1') -Prefix $prefix -Command Rollback -ExpectedCurrent $recordA.current -PhaseTimeoutSeconds 5
    }
    $queuedId = ($queued | ConvertFrom-Json).operationId
    Assert ($queuedId -match '^[a-f0-9]{32}$') 'A queued rollback did not report its operation.'
    $watchTaskItem = @($global:queuedTasks | Where-Object { $_.Name -eq "Caelestia-MaintenanceWatch-$queuedId" })
    $workerTaskItem = @($global:queuedTasks | Where-Object { $_.Name -eq "Caelestia-Maintenance-$queuedId" })
    Remove-Variable -Scope Global -Name queuedTasks -ErrorAction SilentlyContinue
    Assert ($watchTaskItem.Count -eq 1 -and $workerTaskItem.Count -eq 1) 'A queued rollback did not schedule its worker and deadline watchdog.'
    Assert ($watchTaskItem[0].Action.Argument -match '-Command Watch' -and $watchTaskItem[0].Action.Argument -match $queuedId) 'The deadline watchdog does not expire its own operation.'
    $delay = ($watchTaskItem[0].Trigger.At - [DateTime]::Now).TotalSeconds
    Assert ($delay -gt 2 -and $delay -lt 8) "The deadline watchdog was scheduled $([Math]::Round($delay, 1)) s out instead of the bound."
    Assert ($workerTaskItem[0].Settings.ExecutionTimeLimit.TotalSeconds -eq 65) 'The worker task has no bounded execution time.'
    Assert ((Get-Content -LiteralPath $operationFile -Raw | ConvertFrom-Json).phase -eq 'queued') 'A queued rollback did not record its phase.'
    Write-Output 'PASS operation watchdog: a dead rollback task is bounded, its queued path schedules the deadline, and terminal or foreign phases are left alone.'

    foreach ($id in @('..\escape', '..', 'C:\escape', 'a/b')) {
        $failed = $false
        try { Get-CaelestiaVersionPrefix $prefix $id } catch { $failed = $true }
        Assert $failed 'Escaping version identifier accepted.'
    }
    $failed = $false
    $beforeOverwrite = Get-DirectoryHash $a
    try { Publish-CaelestiaPayload $prefix (New-Payload $prefix 'overwrite') $recordA.current } catch { $failed = $true }
    Assert $failed 'Published version was overwritten.'
    Assert ((Get-DirectoryHash $a) -eq $beforeOverwrite) 'A refused publish modified the existing version.'
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
        catch { $failed = $true }
        Assert $failed 'Publishing followed a versions junction.'
        Assert (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'Publishing wrote through a junction.'
    } finally {
        # Delete only this test's junction, not its target or contents.
        [IO.Directory]::Delete($junction, $false)
    }
    Write-Output 'PASS versioned: immutable payloads, running-version routing, rollback/roll-forward, activation failure and traversal refusal.'

    # A crash can leave a staging directory beside the prefix. The marker is
    # written first, so the crash window only leaves an empty directory; both
    # are safe to remove, while a populated unowned directory is never touched
    # and a live owner blocks the next install.
    $stageParent = Join-Path $root 'stage-parent'
    $stagePrefix = Join-Path $stageParent 'app'
    [IO.Directory]::CreateDirectory($stagePrefix) | Out-Null
    $deadPid = 999999
    while (Get-Process -Id $deadPid -ErrorAction SilentlyContinue) { $deadPid-- }
    $emptyStage = "$stagePrefix.staging-$deadPid"
    [IO.Directory]::CreateDirectory($emptyStage) | Out-Null
    Remove-CaelestiaStagingDirectories $stagePrefix
    Assert (-not (Test-Path -LiteralPath $emptyStage)) 'An empty staging directory from a crash was not removed.'
    $markedStage = "$stagePrefix.staging-$deadPid"
    [IO.Directory]::CreateDirectory($markedStage) | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path $markedStage '.caelestia-staging.json') -Encoding UTF8
    Remove-CaelestiaStagingDirectories $stagePrefix
    Assert (-not (Test-Path -LiteralPath $markedStage)) 'An owned staging directory was not removed.'
    $unownedStage = "$stagePrefix.staging-$deadPid"
    [IO.Directory]::CreateDirectory($unownedStage) | Out-Null
    'user data' | Set-Content -LiteralPath (Join-Path $unownedStage 'notes.txt') -Encoding UTF8
    $refused = $false
    try { Remove-CaelestiaStagingDirectories $stagePrefix } catch { $refused = $true }
    Assert ($refused -and (Test-Path -LiteralPath (Join-Path $unownedStage 'notes.txt'))) 'An unowned populated staging directory was removed.'
    Remove-Item -LiteralPath $unownedStage -Recurse -Force
    # A PID that is our own is stale (PIDs are unique), not a live other install.
    $ownStage = "$stagePrefix.staging-$PID"
    [IO.Directory]::CreateDirectory($ownStage) | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path $ownStage '.caelestia-staging.json') -Encoding UTF8
    Remove-CaelestiaStagingDirectories $stagePrefix
    Assert (-not (Test-Path -LiteralPath $ownStage)) 'A stale staging directory with a reused PID of this process was not removed.'
    $sleeper = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' `
        -WindowStyle Hidden -PassThru
    try {
        $liveStage = "$stagePrefix.staging-$($sleeper.Id)"
        [IO.Directory]::CreateDirectory($liveStage) | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $liveStage '.caelestia-staging.json') -Encoding UTF8
        $refused = $false
        try { Remove-CaelestiaStagingDirectories $stagePrefix } catch { $refused = $true }
        Assert ($refused -and (Test-Path -LiteralPath $liveStage)) 'A live staging owner was removed or ignored.'
    } finally {
        if (-not $sleeper.HasExited) { $sleeper.Kill() }
        $sleeper.WaitForExit()
    }
    Write-Output 'PASS staging: crash leftovers are removed, a live owner blocks, and a populated unowned directory is kept.'

    # Integration is part of the activation transaction. A shortcut or Run
    # entry that cannot be written restores the previous integration, selects
    # the previous version again, and leaves no half-written shortcut behind.
    $uiPrefix = Join-Path $root 'ui'
    $null = Install-CaelestiaVersion $uiPrefix (New-Payload $uiPrefix 'ui-a')
    $uiA = (Read-CaelestiaInstall $uiPrefix).current
    $null = Install-CaelestiaVersion $uiPrefix (New-Payload $uiPrefix 'ui-b')
    $uiB = (Read-CaelestiaInstall $uiPrefix).current
    $uiShortcut = Join-Path $root 'ui-shortcut\Caelestia.lnk'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $uiShortcut)) | Out-Null
    'previous shortcut' | Set-Content -LiteralPath $uiShortcut -Encoding UTF8
    $originalShortcut = ${function:New-CaelestiaShortcut}
    try {
        ${function:New-CaelestiaShortcut} = {
            param([string]$Path, [string]$PowerShellPath, [string]$Arguments, [string]$WorkingDirectory, [string]$Icon)
            [IO.File]::WriteAllText($Path, 'half-written')
            throw 'Injected shortcut failure.'
        }
        $failed = $false
        try { Complete-CaelestiaInstallIntegration $uiPrefix (Join-Path $uiPrefix "versions\$uiB") -Previous $uiA -Shortcut $uiShortcut -RunName 'CaelestiaTest' }
        catch { $failed = $true }
        Assert $failed 'An integration failure was hidden.'
        Assert ((Get-Content -LiteralPath $uiShortcut -Raw).Trim() -eq 'previous shortcut') 'A failed integration did not restore the previous shortcut.'
        Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $uiShortcut) -Filter '*.integration-*').Count -eq 0) 'A failed integration left its shortcut backup behind.'
        Assert ((Read-CaelestiaInstall $uiPrefix).current -eq $uiA) 'An integration failure did not select the previous version again.'
        # A first install has no previous payload: the partial integration is
        # removed and the installed version stays selected.
        $freshPrefix = Join-Path $root 'fresh-ui'
        $null = Install-CaelestiaVersion $freshPrefix (New-Payload $freshPrefix 'fresh')
        $freshId = (Read-CaelestiaInstall $freshPrefix).current
        $freshShortcut = Join-Path $root 'fresh-shortcut\Caelestia.lnk'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $freshShortcut)) | Out-Null
        $failed = $false
        try { Complete-CaelestiaInstallIntegration $freshPrefix (Join-Path $freshPrefix "versions\$freshId") -Shortcut $freshShortcut -RunName 'CaelestiaTest' }
        catch { $failed = $true }
        Assert $failed 'A first-install integration failure was hidden.'
        Assert (-not (Test-Path -LiteralPath $freshShortcut)) 'A failed first-install integration left a partial shortcut behind.'
        Assert ((Read-CaelestiaInstall $freshPrefix).current -eq $freshId) 'A failed first-install integration changed the selector.'
    } finally {
        ${function:New-CaelestiaShortcut} = $originalShortcut
    }
    Write-Output 'PASS integration: a failed shortcut rolls back the activation or cleans up a first install.'

    # Regression: the Run value is snapshotted before any work that can fail.
    # A shortcut failure must not remove a pre-existing autostart entry that
    # this transaction never wrote.
    $autoPrefix = Join-Path $root 'auto-ui'
    $null = Install-CaelestiaVersion $autoPrefix (New-Payload $autoPrefix 'auto-a')
    $autoA = (Read-CaelestiaInstall $autoPrefix).current
    $null = Install-CaelestiaVersion $autoPrefix (New-Payload $autoPrefix 'auto-b')
    $autoB = (Read-CaelestiaInstall $autoPrefix).current
    $autoShortcut = Join-Path $root 'auto-shortcut\Caelestia.lnk'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $autoShortcut)) | Out-Null
    'previous shortcut' | Set-Content -LiteralPath $autoShortcut -Encoding UTF8
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $autoRunName = 'CaelestiaTestAuto-' + [guid]::NewGuid().ToString('N')
    $autoRunValue = '"C:\existing\CaelestiaWindows.exe"'
    if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey | Out-Null }
    New-ItemProperty -Path $runKey -Name $autoRunName -PropertyType String -Value $autoRunValue -Force | Out-Null
    try {
        ${function:New-CaelestiaShortcut} = {
            param([string]$Path, [string]$PowerShellPath, [string]$Arguments, [string]$WorkingDirectory, [string]$Icon)
            [IO.File]::WriteAllText($Path, 'half-written')
            throw 'Injected shortcut failure.'
        }
        $failed = $false
        try {
            Complete-CaelestiaInstallIntegration $autoPrefix (Join-Path $autoPrefix "versions\$autoB") -Previous $autoA -Autostart `
                -Shortcut $autoShortcut -RunName $autoRunName
        } catch { $failed = $true }
        Assert $failed 'An -Autostart integration failure was hidden.'
        $runNow = Get-ItemProperty -LiteralPath $runKey -Name $autoRunName -ErrorAction SilentlyContinue
        Assert ($null -ne $runNow -and [string]$runNow.$autoRunName -eq $autoRunValue) 'A failed -Autostart integration removed a pre-existing Run entry it never wrote.'
        Assert ((Read-CaelestiaInstall $autoPrefix).current -eq $autoA) 'An -Autostart integration failure did not select the previous version again.'
        Assert ((Get-Content -LiteralPath $autoShortcut -Raw).Trim() -eq 'previous shortcut') 'An -Autostart integration failure did not restore the previous shortcut.'
    } finally {
        Remove-ItemProperty -LiteralPath $runKey -Name $autoRunName -ErrorAction SilentlyContinue
        ${function:New-CaelestiaShortcut} = $originalShortcut
    }
    Write-Output 'PASS integration autostart: a shortcut failure leaves a pre-existing Run entry untouched.'

    # Regression: a successful -Autostart integration writes only its own Run
    # value. New-Item -Force on the existing Run key used to recreate it empty,
    # deleting every other application's startup entry.
    $otherRunName = 'CaelestiaTestOther-' + [guid]::NewGuid().ToString('N')
    $ownRunName = 'CaelestiaTestOwn-' + [guid]::NewGuid().ToString('N')
    New-ItemProperty -Path $runKey -Name $otherRunName -PropertyType String -Value '"C:\other\app.exe"' -Force | Out-Null
    try {
        Complete-CaelestiaInstallIntegration $autoPrefix (Join-Path $autoPrefix "versions\$autoB") -Previous $autoA -Autostart `
            -Shortcut (Join-Path $root 'auto-shortcut\Own.lnk') -RunName $ownRunName
        $other = Get-ItemProperty -LiteralPath $runKey -Name $otherRunName -ErrorAction SilentlyContinue
        Assert ($null -ne $other -and [string]$other.$otherRunName -eq '"C:\other\app.exe"') 'An -Autostart integration deleted another application''s Run entry.'
        Assert ($null -ne (Get-ItemProperty -LiteralPath $runKey -Name $ownRunName -ErrorAction SilentlyContinue)) 'An -Autostart integration did not write its Run entry.'
    } finally {
        Remove-ItemProperty -LiteralPath $runKey -Name $otherRunName, $ownRunName -ErrorAction SilentlyContinue
    }
    Write-Output 'PASS integration autostart: other applications'' Run entries survive.'

    # Regression: an existing shortcut that cannot be snapshotted aborts
    # integration before any write. The armed shortcut writer must not run, so
    # the original file survives instead of being deleted as a partial file.
    $snapshotPrefix = Join-Path $root 'snapshot-ui'
    $null = Install-CaelestiaVersion $snapshotPrefix (New-Payload $snapshotPrefix 'snapshot-a')
    $snapshotA = (Read-CaelestiaInstall $snapshotPrefix).current
    $null = Install-CaelestiaVersion $snapshotPrefix (New-Payload $snapshotPrefix 'snapshot-b')
    $snapshotB = (Read-CaelestiaInstall $snapshotPrefix).current
    $snapshotShortcut = Join-Path $root 'snapshot-shortcut\Caelestia.lnk'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $snapshotShortcut)) | Out-Null
    'original shortcut' | Set-Content -LiteralPath $snapshotShortcut -Encoding UTF8
    $script:shortcutWriterCalled = $false
    # Deny read sharing so the snapshot copy fails, but allow deletion: the
    # old cleanup path would remove this original as if it were a partial file.
    $snapshotLock = [IO.File]::Open($snapshotShortcut, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Delete)
    try {
        ${function:New-CaelestiaShortcut} = {
            param([string]$Path, [string]$PowerShellPath, [string]$Arguments, [string]$WorkingDirectory, [string]$Icon)
            $script:shortcutWriterCalled = $true
            throw 'Injected shortcut failure.'
        }
        $failed = $false
        try {
            Complete-CaelestiaInstallIntegration $snapshotPrefix (Join-Path $snapshotPrefix "versions\$snapshotB") -Previous $snapshotA `
                -Shortcut $snapshotShortcut -RunName 'CaelestiaTest'
        } catch { $failed = $true }
        Assert $failed 'A shortcut backup failure did not abort integration.'
        Assert (-not $script:shortcutWriterCalled) 'Integration wrote a shortcut after failing to snapshot the existing one.'
        Assert (Test-Path -LiteralPath $snapshotShortcut) 'A shortcut backup failure deleted the original shortcut.'
        Assert ((Read-CaelestiaInstall $snapshotPrefix).current -eq $snapshotA) 'A shortcut backup failure did not select the previous version again.'
        Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $snapshotShortcut) -Filter '*.integration-*').Count -eq 0) 'A shortcut backup failure left a partial backup behind.'
    } finally {
        $snapshotLock.Dispose()
        ${function:New-CaelestiaShortcut} = $originalShortcut
    }
    Assert ((Get-Content -LiteralPath $snapshotShortcut -Raw).Trim() -eq 'original shortcut') 'A shortcut backup failure changed the original shortcut.'
    Write-Output 'PASS integration snapshot: an unreadable existing shortcut aborts before it can be replaced or deleted.'

    foreach ($injectFailure in @($false, $true)) {
        $legacy = Join-Path $root ('legacy-' + $injectFailure)
        $legacyPayload = New-Payload $legacy 'legacy-original'
        [IO.Directory]::Move($legacyPayload, $legacy)
        $script:failStart = $injectFailure
        $failed = $false
        try { $null = Install-CaelestiaVersion $legacy (New-Payload $legacy 'migrated') -Restart }
        catch { if (-not $injectFailure) { throw }; $failed = $true }
        Assert ($failed -eq $injectFailure -and -not $script:failStart) 'Legacy migration did not reach the expected activation outcome.'
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
        Assert ($log -match 'event=scheme-runtime' -and $log -match 'action=fixed-palette') 'The fixed-palette fallback was not reported.'
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

        $generation = '0123456789abcdef0123456789abcdef01234567'
        $generationRoot = Join-Path $schemeRoot "runtimes\$generation"
        $python = Join-Path $generationRoot 'venv\Scripts\python.exe'
        $helper = Join-Path $generationRoot 'win_scheme.py'
        $null = New-TestGeneration (Join-Path $schemeRoot 'runtimes') $generation 'test' (Get-CaelestiaSchemeIdentity $cRuntime 'test').Id $null
        $null = Publish-CaelestiaSchemeRuntime $schemeProfile 'test' $generationRoot
        $dRuntime = Install-CaelestiaVersion $schemePrefix (New-LauncherPayload $schemePrefix $schemeProfile 'D' 'fail') -Restart
        Assert ((Read-CaelestiaInstall $schemePrefix).current -eq (Split-Path -Leaf $dRuntime)) 'A prepared runtime rolled back the activation.'
        $applied = Get-Content -LiteralPath (Join-Path $dRuntime 'shell-scheme.txt') -Raw
        Assert ($applied -match [regex]::Escape($python) -and $applied -match [regex]::Escape($helper)) 'A prepared runtime was not passed to the shell.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $dRuntime 'scheme-provision-called.txt'))) 'A prepared runtime was provisioned again.'
        Write-Output 'PASS scheme ready: a prepared runtime reaches the shell without provisioning.'

        # Activation must never start Python. With no scheme runtime the old
        # code ran py.exe to find an interpreter for the Wallpaper Engine
        # bridge; a stalled launcher then consumed the readiness budget.
        # The interpreter is now recorded while preparing and only read back.
        $stallDirectory = Split-Path -Parent (Get-FakePythonFixture)
        $stallLog = Join-Path $root 'launcher-stall.log'
        $savedPath = $env:PATH
        try {
            $env:PATH = "$stallDirectory;$savedPath"
            $env:CAELESTIA_TEST_PROVISION_LOG = $stallLog
            $env:CAELESTIA_TEST_PY_LAUNCHER_SECONDS = '25'
            Remove-Item -LiteralPath (Join-Path $schemeRoot 'runtime.json') -Force
            Remove-Item -LiteralPath (Join-Path $schemeRoot 'runtimes') -Recurse -Force
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $eRuntime = Install-CaelestiaVersion $schemePrefix (New-LauncherPayload $schemePrefix $schemeProfile 'E' 'fail') -Restart
            $elapsedE = $clock.Elapsed.TotalSeconds
            Assert ((Read-CaelestiaInstall $schemePrefix).current -eq (Split-Path -Leaf $eRuntime)) 'A stalled interpreter launcher rolled back the activation.'
            Assert ($elapsedE -lt 15) "Activation waited $([Math]::Round($elapsedE, 1)) s on a Python launcher."
            Assert (-not ((Test-Path -LiteralPath $stallLog) -and (Get-Content -LiteralPath $stallLog -Raw) -match 'py-launcher')) 'Activation started the Python launcher.'
            Assert (-not ([IO.File]::ReadAllText((Join-Path $eRuntime 'shell-scheme.txt')) -split "`n")[2].Trim()) 'Activation invented a Wallpaper Engine interpreter.'
            # A recorded interpreter reaches the bridge without being discovered.
            $recorded = Get-FakePythonFixture
            Set-CaelestiaSchemeInterpreter $schemeProfile $recorded
            $fRuntime = Install-CaelestiaVersion $schemePrefix (New-LauncherPayload $schemePrefix $schemeProfile 'F' 'fail') -Restart
            Assert (-not ((Test-Path -LiteralPath $stallLog) -and (Get-Content -LiteralPath $stallLog -Raw) -match 'py-launcher')) 'Activation started the Python launcher with a recorded interpreter.'
            Assert ((([IO.File]::ReadAllText((Join-Path $fRuntime 'shell-scheme.txt')) -split "`n")[2]).Trim() -eq $recorded) 'The recorded interpreter did not reach the Wallpaper Engine bridge.'
            Assert (-not (Test-Path -LiteralPath (Join-Path $fRuntime 'scheme-provision-called.txt'))) 'Activation provisioned again.'
        } finally {
            $env:PATH = $savedPath
            $env:CAELESTIA_TEST_PROVISION_LOG = $null
            $env:CAELESTIA_TEST_PY_LAUNCHER_SECONDS = $null
        }
        Write-Output 'PASS activation: no Python is started; the Wallpaper Engine interpreter is read from the prepared record.'
    } finally {
        $script:runLauncher = $false
    }

    # A retained pre-versioning payload has no -PreparedSchemeRuntime parameter.
    # Its launcher is an advanced function, so an unknown switch fails binding
    # instead of being swallowed through $args. Activation must also disable its
    # provisioner so pip cannot run inside the readiness budget.
    $legacyRouterPrefix = Join-Path $root 'legacy-router'
    $legacyRouterVersion = Join-Path $legacyRouterPrefix 'versions\v1'
    [IO.Directory]::CreateDirectory($legacyRouterVersion) | Out-Null
    @'
[CmdletBinding()]
param([string]$Prefix, [string]$Command = 'Start', [switch]$SkipSchemeRuntime)
"legacy-router-ok:$Command skip=$($SkipSchemeRuntime.IsPresent)"
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
    Assert ($legacyOutput -match 'legacy-router-ok:Start skip=True') 'The router did not disable provisioning on a legacy activation.'
    Write-Output 'PASS router: a legacy payload starts with provisioning disabled and no prepared switch.'

    # Update and rollback pick and verify the target's generation BEFORE the
    # running shell is stopped, so a slow probe is not an outage, and the
    # verified generation is repointed without a second probe.
    $vqPrefix = Join-Path $root 'vq'
    $vqProfile = Join-Path $root 'vqp'
    [IO.Directory]::CreateDirectory($vqProfile) | Out-Null
    Write-CaelestiaProfileOwner $vqProfile $vqPrefix 'vq-test' $true
    $vqLog = Join-Path $root 'vq.log'
    $script:runLauncher = $true
    $env:CAELESTIA_TEST_PROVISION_LOG = $vqLog
    try {
        $null = Install-CaelestiaVersion $vqPrefix (New-LauncherPayload $vqPrefix $vqProfile 'A' 'fail' -LegacyStart)
        $vqTarget = New-LauncherPayload $vqPrefix $vqProfile 'B' 'fail'
        $null = New-TestGeneration (Join-Path $vqProfile 'scheme\runtimes') ('3' * 40) 'test' (Get-CaelestiaSchemeIdentity $vqTarget 'test').Id
        $null = Install-CaelestiaVersion $vqPrefix $vqTarget -Restart
        $bId = (Read-CaelestiaInstall $vqPrefix).current
        $events = @(Get-Content -LiteralPath $vqLog | ForEach-Object { ($_ -split ',')[2] })
        Assert ($events -contains 'quit' -and $events -contains 'check') 'The update did not probe the generation and stop the old shell.'
        Assert ([array]::IndexOf($events, 'check') -lt [array]::IndexOf($events, 'quit')) 'Update stopped the old shell before verifying the generation.'
        Assert (@($events | Where-Object { $_ -eq 'check' }).Count -eq 1) 'Update probed the generation again after stopping the old shell.'
        Assert ((Read-Pointer $vqProfile).generation -eq ('3' * 40) -and (Read-Pointer $vqProfile).available -eq $true) 'Update did not publish the verified generation.'
        # Roll back to it from a launcher that records its quit.
        $null = Install-CaelestiaVersion $vqPrefix (New-LauncherPayload $vqPrefix $vqProfile 'C' 'fail' -LegacyStart)
        Remove-Item -LiteralPath $vqLog -Force
        $null = Switch-CaelestiaVersion $vqPrefix $bId -Restart
        $events = @(Get-Content -LiteralPath $vqLog | ForEach-Object { ($_ -split ',')[2] })
        Assert ($events -contains 'quit' -and [array]::IndexOf($events, 'check') -ge 0 -and [array]::IndexOf($events, 'check') -lt [array]::IndexOf($events, 'quit')) 'Rollback stopped the running shell before verifying the generation.'
        Assert (@($events | Where-Object { $_ -eq 'check' }).Count -eq 1) 'Rollback probed the generation again after stopping the shell.'
        Write-Output 'PASS verify-first: update and rollback verify the generation before the running shell is stopped.'
    } finally {
        $script:runLauncher = $false
        $env:CAELESTIA_TEST_PROVISION_LOG = $null
    }

    # A pre-selection that found nothing usable is final: the shell is stopped
    # once and relaunched on the fixed palette. Two generations hang their
    # probe; nothing may be probed again after the stop, for update or rollback.
    $fvPrefix = Join-Path $root 'fv'
    $fvProfile = Join-Path $root 'fvp'
    [IO.Directory]::CreateDirectory($fvProfile) | Out-Null
    Write-CaelestiaProfileOwner $fvProfile $fvPrefix 'fv-test' $true
    $fvLog = Join-Path $root 'fv.log'
    $script:CaelestiaSchemeProbeBudgetSeconds = 5
    $script:CaelestiaSchemeProbeSliceSeconds = 2
    $script:runLauncher = $true
    $env:CAELESTIA_TEST_PROVISION_LOG = $fvLog
    try {
        $null = Install-CaelestiaVersion $fvPrefix (New-LauncherPayload $fvPrefix $fvProfile 'A' 'fail' -LegacyStart)
        $fvTarget = New-LauncherPayload $fvPrefix $fvProfile 'B' 'fail'
        $fvIdentity = (Get-CaelestiaSchemeIdentity $fvTarget 'test').Id
        $fvNow = [DateTime]::UtcNow
        foreach ($spec in @(@('1', -1), @('2', -2))) {
            $hungRoot = New-TestGeneration (Join-Path $fvProfile 'scheme\runtimes') ($spec[0] * 40) 'test' $fvIdentity $fvNow.AddMinutes($spec[1])
            'hang' | Set-Content -LiteralPath (Join-Path $hungRoot 'venv\Scripts\hang.txt')
        }
        $null = Install-CaelestiaVersion $fvPrefix $fvTarget -Restart
        $fvB = Resolve-CaelestiaRuntimePrefix $fvPrefix
        Assert-NoPostQuitProbe $fvLog 'Update'
        Assert ((Read-Pointer $fvProfile).available -eq $false) 'Update left a rejected generation published.'
        Assert (-not ([IO.File]::ReadAllText((Join-Path $fvB 'shell-scheme.txt')) -split "`n")[0].Trim()) 'Update launched with a scheme runtime that was never verified.'
        Assert (Test-Path -LiteralPath (Join-Path $fvB 'shell-started.txt')) 'Update did not start the shell on the fixed palette.'
        $bId = (Read-CaelestiaInstall $fvPrefix).current
        $null = Install-CaelestiaVersion $fvPrefix (New-LauncherPayload $fvPrefix $fvProfile 'C' 'fail' -LegacyStart)
        Remove-Item -LiteralPath $fvLog -Force
        $null = Switch-CaelestiaVersion $fvPrefix $bId -Restart
        Assert-NoPostQuitProbe $fvLog 'Rollback'
        Assert ((Read-Pointer $fvProfile).available -eq $false) 'Rollback left a rejected generation published.'
        Write-Output 'PASS pre-selection is final: update and rollback never probe after the shell has stopped and start on the fixed palette.'
    } finally {
        $script:CaelestiaSchemeProbeBudgetSeconds = 15
        $script:CaelestiaSchemeProbeSliceSeconds = 8
        $script:runLauncher = $false
        $env:CAELESTIA_TEST_PROVISION_LOG = $null
    }

    # Failure recovery runs after the shell has stopped, so it must never probe:
    # the fallback's decision is taken before the quit, with the target's. Each
    # scenario has hung generations for the target and a healthy one for the
    # version being restored.
    $script:failSelectorWrite = $false
    $script:originalJsonWriter = ${function:Write-CaelestiaJsonAtomic}
    function Write-CaelestiaJsonAtomic([string]$Path, $Value) {
        if ($script:failSelectorWrite -and $Path -like '*\install.json') {
            $script:failSelectorWrite = $false
            throw 'Injected selector write failure.'
        }
        & $script:originalJsonWriter $Path $Value
    }
    $script:recoveryCount = 0
    function Invoke-RecoveryScenario([string]$Kind) {
        $script:recoveryCount++
        $n = $script:recoveryCount
        $rcPrefix = Join-Path $root "rc$n"
        $rcProfile = Join-Path $root "rcp$n"
        $rcLog = Join-Path $root "rc$n.log"
        [IO.Directory]::CreateDirectory($rcProfile) | Out-Null
        Write-CaelestiaProfileOwner $rcProfile $rcPrefix "rc-test-$n" $true
        $script:CaelestiaSchemeProbeBudgetSeconds = 5
        $script:CaelestiaSchemeProbeSliceSeconds = 2
        $script:runLauncher = $true
        try {
            $target = New-LauncherPayload $rcPrefix $rcProfile 'T' 'fail'
            $restore = New-LauncherPayload $rcPrefix $rcProfile 'R' 'fail' -LegacyStart
            'restore helper' | Set-Content -LiteralPath (Join-Path $restore 'scheme\win_scheme.py') -Encoding UTF8
            $targetId = (Get-CaelestiaSchemeIdentity $target 'test').Id
            $restoreId = (Get-CaelestiaSchemeIdentity $restore 'test').Id
            $targetVersion = ''
            if ($Kind -ne 'update') {
                $null = Install-CaelestiaVersion $rcPrefix $target
                $targetVersion = (Read-CaelestiaInstall $rcPrefix).current
            }
            $null = Install-CaelestiaVersion $rcPrefix $restore
            $restoreVersion = (Read-CaelestiaInstall $rcPrefix).current
            $runtimes = Join-Path $rcProfile 'scheme\runtimes'
            $now = [DateTime]::UtcNow
            $null = New-TestGeneration $runtimes ('4' * 40) 'test' $restoreId $now.AddMinutes(-10)
            foreach ($spec in @(@('1', -1), @('2', -2))) {
                $hungRoot = New-TestGeneration $runtimes ($spec[0] * 40) 'test' $targetId $now.AddMinutes($spec[1])
                'hang' | Set-Content -LiteralPath (Join-Path $hungRoot 'venv\Scripts\hang.txt')
            }
            Remove-Item -LiteralPath $rcLog -Force -ErrorAction SilentlyContinue
            $env:CAELESTIA_TEST_PROVISION_LOG = $rcLog
            $failed = $false
            try {
                switch ($Kind) {
                    'update' { $script:failStart = $true; $null = Install-CaelestiaVersion $rcPrefix $target -Restart }
                    'rollback' { $script:failStart = $true; $null = Switch-CaelestiaVersion $rcPrefix $targetVersion -Restart }
                    'selector' { $script:failSelectorWrite = $true; $null = Switch-CaelestiaVersion $rcPrefix $targetVersion -Restart }
                }
            } catch {
                $failed = $true
            }
            Assert ($failed -and -not $script:failStart -and -not $script:failSelectorWrite) "The $Kind scenario did not fail as injected."
            Assert-NoPostQuitProbe $rcLog "Recovery after a failed $Kind" -MaxStopped 6 -LastLaunch
            Assert ((Read-CaelestiaInstall $rcPrefix).current -eq $restoreVersion) "Recovery after a failed $Kind did not select the previous version."
            $pointer = Read-Pointer $rcProfile
            Assert ($pointer.available -eq $true -and $pointer.generation -eq ('4' * 40)) "Recovery after a failed $Kind did not publish the restored version's generation."
        } finally {
            $script:CaelestiaSchemeProbeBudgetSeconds = 15
            $script:CaelestiaSchemeProbeSliceSeconds = 8
            $script:runLauncher = $false
            $script:failStart = $false
            $script:failSelectorWrite = $false
            $env:CAELESTIA_TEST_PROVISION_LOG = $null
        }
    }
    Invoke-RecoveryScenario 'update'
    Invoke-RecoveryScenario 'rollback'
    Invoke-RecoveryScenario 'selector'
    Write-Output 'PASS recovery: failed update activation, failed rollback activation and a selector-write failure restore the previous version without probing after the stop.'

    # The retained fallback can itself be gone. The activation catch must not
    # leave the selector claiming the failed replacement, must not launch a
    # payload it cannot trust, and must reselect a retained payload that exists
    # so a later start can use it.
    $svPrefix = Join-Path $root 'sv'
    $null = Install-CaelestiaVersion $svPrefix (New-Payload $svPrefix 'sv-a')
    $svA = (Read-CaelestiaInstall $svPrefix).current
    $null = Install-CaelestiaVersion $svPrefix (New-Payload $svPrefix 'sv-b')
    $svB = (Read-CaelestiaInstall $svPrefix).current
    # The fallback payload is lost exactly when the failed activation needs it,
    # as an interrupted prune could leave it.
    $script:breakFallbackPayload = Join-Path $svPrefix "versions\$svB"
    $script:started = 0
    $script:failStart = $true
    $failed = $false
    try { $null = Install-CaelestiaVersion $svPrefix (New-Payload $svPrefix 'sv-c') -Restart }
    catch { $failed = $true }
    finally {
        $script:failStart = $false
        $script:breakFallbackPayload = $null
    }
    Assert $failed 'The missing-fallback scenario did not fail as injected.'
    Assert ($script:started -eq 1) 'Activation with no usable fallback launched a payload a later start could not trust.'
    $reselect = Read-CaelestiaInstall $svPrefix
    Assert ($reselect.current -eq $svA) 'Activation did not reselect a retained payload that exists.'
    Assert (-not $reselect.previous) 'A missing previous payload stayed in the selector.'
    Assert ((Resolve-CaelestiaRuntimePrefix $svPrefix) -eq (Join-Path $svPrefix "versions\$svA")) 'A later start would not select the existing payload.'
    Write-Output 'PASS reselect: a missing fallback payload is replaced by an existing one without launching.'

    # Update while another process holds the scheme lock: nothing can be probed
    # or published, the shell still restarts (on the fixed palette) without
    # waiting, and nothing is probed after the stop.
    Add-Type -OutputAssembly (Join-Path $root 'scheme-lock-holder.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class SchemeLockHolderFixture {
    public static int Main(string[] args) {
        Mutex mutex;
        try { mutex = new Mutex(false, "Global\\" + args[0]); }
        catch (UnauthorizedAccessException) { mutex = new Mutex(false, "Local\\" + args[0]); }
        if (!mutex.WaitOne(0)) return 2;
        File.WriteAllText("held.txt", "held");
        var deadline = DateTime.UtcNow.AddSeconds(90);
        while (DateTime.UtcNow < deadline && !File.Exists("stop.txt")) Thread.Sleep(25);
        mutex.ReleaseMutex();
        return 0;
    }
}
'@
    $lcPrefix = Join-Path $root 'lc'
    $lcProfile = Join-Path $root 'lcp'
    $lcLog = Join-Path $root 'lc.log'
    [IO.Directory]::CreateDirectory($lcProfile) | Out-Null
    Write-CaelestiaProfileOwner $lcProfile $lcPrefix 'lc-test' $true
    $script:runLauncher = $true
    $holderDirectory = Join-Path $root 'lock-holder'
    [IO.Directory]::CreateDirectory($holderDirectory) | Out-Null
    $holder = $null
    try {
        $lcTarget = New-LauncherPayload $lcPrefix $lcProfile 'T' 'fail'
        $null = Install-CaelestiaVersion $lcPrefix (New-LauncherPayload $lcPrefix $lcProfile 'R' 'fail' -LegacyStart)
        $null = New-TestGeneration (Join-Path $lcProfile 'scheme\runtimes') ('5' * 40) 'test' (Get-CaelestiaSchemeIdentity $lcTarget 'test').Id
        $lockName = 'CaelestiaScheme-' + (Get-CaelestiaInstallLockKey (Get-CaelestiaCanonicalPath $lcProfile))
        $holder = Start-Process -FilePath (Join-Path $root 'scheme-lock-holder.exe') -ArgumentList $lockName -WorkingDirectory $holderDirectory -PassThru -WindowStyle Hidden
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath (Join-Path $holderDirectory 'held.txt')) -and [DateTime]::UtcNow -lt $deadline -and -not $holder.HasExited) { Start-Sleep -Milliseconds 25 }
        Assert (Test-Path -LiteralPath (Join-Path $holderDirectory 'held.txt')) 'The scheme lock holder did not start.'
        $env:CAELESTIA_TEST_PROVISION_LOG = $lcLog
        $lockClock = [Diagnostics.Stopwatch]::StartNew()
        $null = Install-CaelestiaVersion $lcPrefix $lcTarget -Restart
        $lockElapsed = $lockClock.Elapsed.TotalSeconds
        Assert ($lockElapsed -lt 15) "An update waited $([Math]::Round($lockElapsed, 1)) s on a busy scheme lock."
        Assert-NoPostQuitProbe $lcLog 'Update under lock contention' -NoProbesExpected
        $lcRuntime = Resolve-CaelestiaRuntimePrefix $lcPrefix
        Assert (Test-Path -LiteralPath (Join-Path $lcRuntime 'shell-started.txt')) 'The update did not start the shell while the scheme lock was busy.'
        Assert (-not ([IO.File]::ReadAllText((Join-Path $lcRuntime 'shell-scheme.txt')) -split "`n")[0].Trim()) 'A scheme runtime reached the shell although the lock was busy.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $lcProfile 'scheme\runtime.json'))) 'A busy lock still allowed runtime.json to be written.'
        # Recovery: once the lock is free, the next repoint finds the generation.
        [IO.File]::WriteAllText((Join-Path $holderDirectory 'stop.txt'), '')
        Assert ($holder.WaitForExit(10000)) 'The scheme lock holder did not exit.'
        $later = Update-SchemeRuntimeForRevision $lcProfile 'test' $lcRuntime
        Assert ($later -and $later.generation -eq ('5' * 40)) 'The generation was not usable after the lock was released.'
        Write-Output 'PASS lock contention: an update under a busy scheme lock probes nothing, starts on the fixed palette and recovers on the next repoint.'
    } finally {
        $script:runLauncher = $false
        $env:CAELESTIA_TEST_PROVISION_LOG = $null
        if ($holder -and -not $holder.HasExited) {
            [IO.File]::WriteAllText((Join-Path $holderDirectory 'stop.txt'), '')
            if (-not $holder.WaitForExit(5000)) { $holder.Kill(); $holder.WaitForExit() }
        }
    }

    # Rolling back to a legacy payload with a 22 s fake provisioner must not
    # spend the readiness budget or roll forward again.
    $legacyPrefix = Join-Path $root 'legacy-rollback'
    $legacyProfile = Join-Path $root 'legacy-rollback-profile'
    [IO.Directory]::CreateDirectory($legacyProfile) | Out-Null
    Write-CaelestiaProfileOwner $legacyProfile $legacyPrefix 'legacy-rollback' $true
    $script:runLauncher = $true
    try {
        $null = Install-CaelestiaVersion $legacyPrefix (New-LauncherPayload $legacyPrefix $legacyProfile 'A' 'slow' -LegacyStart)
        $legacyRecordA = Read-CaelestiaInstall $legacyPrefix
        $null = Install-CaelestiaVersion $legacyPrefix (New-LauncherPayload $legacyPrefix $legacyProfile 'B' 'fail')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $null = Switch-CaelestiaVersion $legacyPrefix $legacyRecordA.current -Restart
        $elapsed = $clock.Elapsed.TotalSeconds
        Assert ((Read-CaelestiaInstall $legacyPrefix).current -eq $legacyRecordA.current) 'Legacy rollback rolled forward again.'
        Assert ($elapsed -lt 10) "Legacy rollback waited $([Math]::Round($elapsed, 1)) s for provisioning."
        $runtime = Resolve-CaelestiaRuntimePrefix $legacyPrefix
        Assert (Test-Path -LiteralPath (Join-Path $runtime 'shell-started.txt') -PathType Leaf) 'Legacy rollback never started the shell.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $runtime 'scheme-provision-called.txt'))) 'Legacy rollback ran the provisioner.'
        Write-Output 'PASS legacy rollback: provisioning stays out of the readiness budget.'
    } finally {
        $script:runLauncher = $false
    }

    # Generation retention and repointing: keep current and previous revisions,
    # drop unrelated ones only with no shell, and point runtime.json at an
    # existing generation before activation starts its readiness clock.
    $prunePrefix = Join-Path $root 'prune-app'
    $pruneProfile = Join-Path $root 'prune-profile'
    $versionA = Join-Path $prunePrefix 'versions\vA'
    $versionB = Join-Path $prunePrefix 'versions\vB'
    foreach ($pair in @(
        @($versionA, 'vA', 'rev-a'),
        @($versionB, 'vB', 'rev-b')
    )) {
        [IO.Directory]::CreateDirectory($pair[0]) | Out-Null
        @{
            product = 'caelestia-windows'; version = 1; prefix = $pair[0]; profile = $pruneProfile
            installId = 'prune-test'; installRoot = $prunePrefix; versionId = $pair[1]
            sourceRevision = 'x'; executableSha256 = 'x'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pair[0] 'install.json') -Encoding UTF8
        New-Item -ItemType Directory -Force -Path (Join-Path $pair[0] 'licenses'), (Join-Path $pair[0] 'scheme') | Out-Null
        "{`"schemeCli`":{`"revision`":`"$($pair[2])`"}}" |
            Set-Content -LiteralPath (Join-Path $pair[0] 'licenses\sources.lock.json') -Encoding UTF8
        'fixture-helper' | Set-Content -LiteralPath (Join-Path $pair[0] 'scheme\win_scheme.py') -Encoding UTF8
        'fixture-requirements' | Set-Content -LiteralPath (Join-Path $pair[0] 'scheme\requirements.lock.txt') -Encoding UTF8
        'fixture-shim' | Set-Content -LiteralPath (Join-Path $pair[0] 'scheme\fcntl.py') -Encoding UTF8
    }
    @{
        product = 'caelestia-windows'; version = 2; prefix = $prunePrefix
        profile = $pruneProfile; installId = 'prune-test'; current = 'vB'; previous = 'vA'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $prunePrefix 'install.json') -Encoding UTF8
    $pruneSchemeRoot = Join-Path $pruneProfile 'scheme'
    $pruneRuntimes = Join-Path $pruneSchemeRoot 'runtimes'
    New-Item -ItemType Directory -Force -Path $pruneRuntimes | Out-Null
    $gA = 'a' * 40; $gB = 'b' * 40; $gC = 'c' * 40; $gD = 'd' * 40
    $null = New-TestGeneration $pruneRuntimes $gA 'rev-a' (Get-CaelestiaSchemeIdentity $versionA 'rev-a').Id
    $null = New-TestGeneration $pruneRuntimes $gB 'rev-b' (Get-CaelestiaSchemeIdentity $versionB 'rev-b').Id
    $null = New-TestGeneration $pruneRuntimes $gC 'rev-c' ('c' * 64)
    @{ available = $true; revision = 'rev-b'; generation = $gB } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pruneSchemeRoot 'runtime.json') -Encoding UTF8
    $script:runningPaths = @()
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert ((Test-Path -LiteralPath (Join-Path $pruneRuntimes $gA)) -and (Test-Path -LiteralPath (Join-Path $pruneRuntimes $gB))) 'Pruning removed a current or previous generation.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $pruneRuntimes $gC))) 'Pruning kept an unreferenced generation.'
    $repoint = Update-SchemeRuntimeForRevision $pruneProfile 'rev-a' $versionA
    $repointRecord = Get-Content -LiteralPath (Join-Path $pruneSchemeRoot 'runtime.json') -Raw | ConvertFrom-Json
    Assert ($repoint -and $repoint.generation -eq $gA -and $repointRecord.generation -eq $gA) 'Activation did not repoint runtime.json to the retained revision.'
    Assert ($repointRecord.python -match "\\$gA\\") 'Repointed runtime does not use its generation paths.'
    $runningGeneration = New-TestGeneration $pruneRuntimes $gD 'rev-d' ('d' * 64)
    $script:runningPaths = @((Join-Path $prunePrefix 'versions\vA\qs.exe'))
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (Test-Path -LiteralPath $runningGeneration) 'Pruning deleted a generation while a shell was running.'
    $script:runningPaths = @()
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Write-Output 'PASS generations: current/previous retained, unrelated pruned only while idle, rollback repoints the record.'

    # Pruning takes exclusive ownership by renaming the generation into
    # runtimes\.trash first. A process whose working directory or open file is
    # inside keeps the generation whole; only a successful rename allows a delete.
    $workGeneration = New-TestGeneration $pruneRuntimes ('e' * 40) 'rev-z' ('e' * 64)
    New-Item -ItemType Directory -Force -Path (Join-Path $workGeneration 'work') | Out-Null
    'in use' | Set-Content -LiteralPath (Join-Path $workGeneration 'work\state.txt') -Encoding UTF8
    $workBefore = Get-DirectoryHash $workGeneration
    $holder = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' `
        -WorkingDirectory (Join-Path $workGeneration 'work') -WindowStyle Hidden -PassThru
    try {
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        Assert (Test-Path -LiteralPath $workGeneration) 'Pruning removed a generation a live process works in.'
        Assert ((Get-DirectoryHash $workGeneration) -eq $workBefore) 'Pruning deleted part of a generation a live process works in.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $pruneRuntimes '.trash'))) 'Pruning left the busy generation in .trash.'
    } finally {
        if (-not $holder.HasExited) { $holder.Kill() }
        $holder.WaitForExit()
    }
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (-not (Test-Path -LiteralPath $workGeneration)) 'A retired generation was not removed once nothing used it.'

    $openGeneration = New-TestGeneration $pruneRuntimes ('f' * 40) 'rev-z' ('f' * 64)
    $openBefore = Get-DirectoryListing $openGeneration
    $openStream = [IO.File]::Open((Join-Path $openGeneration 'win_scheme.py'), 'Open', 'Read', 'None')
    try {
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        Assert ((Test-Path -LiteralPath $openGeneration) -and (Get-DirectoryListing $openGeneration) -eq $openBefore) 'Pruning damaged a generation with an open file.'
    } finally { $openStream.Dispose() }
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (-not (Test-Path -LiteralPath $openGeneration)) 'A generation was not removed after its file closed.'

    # A rename does not prove nobody runs code from a generation: a loaded DLL
    # did not block it. Pruning fails closed: a mapped image keeps the whole
    # generation, even when process inspection cannot read anything.
    $imageGeneration = New-TestGeneration $pruneRuntimes ('a1' * 20) 'rev-z' ('a1' * 32)
    New-Item -ItemType Directory -Force -Path (Join-Path $imageGeneration 'lib') | Out-Null
    $loadedDll = Join-Path $imageGeneration 'lib\version.dll'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\version.dll') -Destination $loadedDll
    'sibling' | Set-Content -LiteralPath (Join-Path $imageGeneration 'lib\data.txt') -Encoding UTF8
    $imageBefore = Get-DirectoryListing $imageGeneration
    $loaderScript = Join-Path $root 'load-dll.ps1'
    $loadedMarker = Join-Path $root 'dll-loaded.txt'
    @'
param([string]$Dll, [string]$Marker)
Add-Type -Namespace T -Name K -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr LoadLibraryW(string path);'
if ([T.K]::LoadLibraryW($Dll) -eq [IntPtr]::Zero) { exit 3 }
Set-Content -LiteralPath $Marker -Value loaded
Start-Sleep -Seconds 60
'@ | Set-Content -LiteralPath $loaderScript -Encoding UTF8
    $loader = Start-Process -FilePath (Get-WindowsPowerShellPath) -WindowStyle Hidden -PassThru `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $loaderScript + '" -Dll "' + $loadedDll + '" -Marker "' + $loadedMarker + '"')
    $originalImagePaths = ${function:Get-CaelestiaProcessImagePaths}
    $originalImagesFree = ${function:Test-CaelestiaSchemeImagesFree}
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $loadedMarker) -and [DateTime]::UtcNow -lt $deadline -and -not $loader.HasExited) { Start-Sleep -Milliseconds 50 }
        Assert (Test-Path -LiteralPath $loadedMarker) 'The DLL loader did not start.'
        # Process inspection that cannot read any process.
        ${function:Get-CaelestiaProcessImagePaths} = { param($Process) throw 'injected: image paths are unreadable' }
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        Assert ((Test-Path -LiteralPath $imageGeneration) -and (Get-DirectoryListing $imageGeneration) -eq $imageBefore) 'Pruning damaged a generation with a loaded DLL while process inspection failed.'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $pruneRuntimes '.trash') -Force -ErrorAction SilentlyContinue).Count -eq 0) 'Pruning moved a generation with a loaded DLL.'
        # Readable inspection alone also protects it, without the image probe.
        ${function:Test-CaelestiaSchemeImagesFree} = { param($Directory) $true }
        $loaderId = $loader.Id
        ${function:Get-CaelestiaProcessImagePaths} = { param($Process) if ($Process.Id -eq $loaderId) { @($loadedDll) } else { @() } }.GetNewClosure()
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        Assert ((Test-Path -LiteralPath $imageGeneration) -and (Get-DirectoryListing $imageGeneration) -eq $imageBefore) 'Process module inspection did not protect a generation with a loaded DLL.'
    } finally {
        ${function:Get-CaelestiaProcessImagePaths} = $originalImagePaths
        ${function:Test-CaelestiaSchemeImagesFree} = $originalImagesFree
        if (-not $loader.HasExited) { $loader.Kill() }
        $loader.WaitForExit()
    }
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (-not (Test-Path -LiteralPath $imageGeneration)) 'A generation was not removed once its DLL was unloaded.'

    # The window between the image check and the rename. A directory cannot be
    # renamed while any handle is open inside it, so the check's handles cannot
    # span the rename; instead the check is repeated at the new location and a
    # generation that gained a mapped image is put straight back.
    Add-Type -Namespace TRace -Name K -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr LoadLibraryW(string path);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool FreeLibrary(System.IntPtr module);
'@
    $raceGeneration = New-TestGeneration $pruneRuntimes ('b2' * 20) 'rev-z' ('b2' * 32)
    New-Item -ItemType Directory -Force -Path (Join-Path $raceGeneration 'lib') | Out-Null
    $raceDll = Join-Path $raceGeneration 'lib\version.dll'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\version.dll') -Destination $raceDll
    'sibling' | Set-Content -LiteralPath (Join-Path $raceGeneration 'lib\data.txt') -Encoding UTF8
    # While the check's handles are held, no image of the generation can be
    # mapped or launched, and the directory cannot be renamed.
    $held = Open-CaelestiaSchemeImageHandles $raceGeneration
    try {
        Assert ($null -ne $held -and $held.Count -ge 1) 'The image check opened no handles.'
        Assert ([TRace.K]::LoadLibraryW($raceDll) -eq [IntPtr]::Zero) 'An image mapped while the check held its handles.'
        $renameBlocked = $false
        try { [IO.Directory]::Move($raceGeneration, $raceGeneration + '.x') } catch { $renameBlocked = $true }
        Assert $renameBlocked 'A directory was renamed while image handles were open inside it.'
    } finally { foreach ($stream in $held) { $stream.Dispose() } }
    $raceBefore = Get-DirectoryListing $raceGeneration
    $race = @{ Module = [IntPtr]::Zero }
    $originalHook = ${function:Invoke-CaelestiaSchemePruneHook}
    try {
        # After the check passed and before the rename, a consumer maps an image.
        ${function:Invoke-CaelestiaSchemePruneHook} = { param($Stage, $Directory)
            if ($Stage -eq 'checked' -and $Directory -like '*b2b2b2*') { $race.Module = [TRace.K]::LoadLibraryW($raceDll) }
        }.GetNewClosure()
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        Assert ($race.Module -ne [IntPtr]::Zero) 'The race hook did not map the image.'
        Assert ((Test-Path -LiteralPath $raceGeneration) -and (Get-DirectoryListing $raceGeneration) -eq $raceBefore) 'A generation whose image was mapped after the check was left moved.'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $pruneRuntimes '.trash') -Force -ErrorAction SilentlyContinue).Count -eq 0) 'A generation whose image was mapped after the check stayed in .trash.'
    } finally {
        ${function:Invoke-CaelestiaSchemePruneHook} = $originalHook
        if ($race.Module -ne [IntPtr]::Zero) { $null = [TRace.K]::FreeLibrary($race.Module) }
    }
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (-not (Test-Path -LiteralPath $raceGeneration)) 'A generation was not removed once its image was unmapped.'

    # A read-only image is not in use. The write probe must clear that attribute
    # only for its open and put it back; before, these generations were never
    # pruned because the write open was denied by the attribute.
    $readOnlyGeneration = New-TestGeneration $pruneRuntimes ('d4' * 20) 'rev-z' ('d4' * 32)
    $readOnlyDirectory = Join-Path $readOnlyGeneration 'lib'
    New-Item -ItemType Directory -Force -Path $readOnlyDirectory | Out-Null
    $readOnlyImage = Join-Path $readOnlyDirectory 'version.dll'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\version.dll') -Destination $readOnlyImage
    (Get-Item -LiteralPath $readOnlyImage).IsReadOnly = $true
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (-not (Test-Path -LiteralPath $readOnlyGeneration)) 'A generation whose images are read-only was never pruned.'

    # A mapped read-only image is in use. The probe restores the attribute it
    # had to clear, so a kept generation is not silently changed.
    $readOnlyMapped = New-TestGeneration $pruneRuntimes ('e4' * 20) 'rev-z' ('e4' * 32)
    $readOnlyMappedDirectory = Join-Path $readOnlyMapped 'lib'
    New-Item -ItemType Directory -Force -Path $readOnlyMappedDirectory | Out-Null
    $readOnlyMappedImage = Join-Path $readOnlyMappedDirectory 'version.dll'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\version.dll') -Destination $readOnlyMappedImage
    (Get-Item -LiteralPath $readOnlyMappedImage).IsReadOnly = $true
    $readOnlyMappedBefore = Get-DirectoryListing $readOnlyMapped
    $readOnlyModule = [TRace.K]::LoadLibraryW($readOnlyMappedImage)
    try {
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        Assert ((Test-Path -LiteralPath $readOnlyMapped) -and (Get-DirectoryListing $readOnlyMapped) -eq $readOnlyMappedBefore) 'Pruning damaged a generation with a mapped read-only image.'
        Assert ((Get-Item -LiteralPath $readOnlyMappedImage).IsReadOnly) 'The image probe left a kept read-only image writable.'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $pruneRuntimes '.trash') -Force -ErrorAction SilentlyContinue).Count -eq 0) 'A mapped read-only image was moved to .trash.'
    } finally {
        if ($readOnlyModule -ne [IntPtr]::Zero) { $null = [TRace.K]::FreeLibrary($readOnlyModule) }
    }
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (-not (Test-Path -LiteralPath $readOnlyMapped)) 'A generation was not removed once its read-only image was unmapped.'

    # If the move back fails (here an open file inside blocks the rename) the
    # generation stays whole in .trash and a path-free structured line is
    # logged. The restore is journaled, so the next prune puts the generation
    # back once before deleting; after that it can be retired normally.
    $strandGeneration = New-TestGeneration $pruneRuntimes ('c3' * 20) 'rev-z' ('c3' * 32)
    New-Item -ItemType Directory -Force -Path (Join-Path $strandGeneration 'lib') | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\version.dll') -Destination (Join-Path $strandGeneration 'lib\version.dll')
    'sibling' | Set-Content -LiteralPath (Join-Path $strandGeneration 'lib\data.txt') -Encoding UTF8
    $strandBefore = Get-DirectoryListing $strandGeneration
    $strand = @{ Module = [IntPtr]::Zero; Stream = $null }
    $originalHook = ${function:Invoke-CaelestiaSchemePruneHook}
    try {
        ${function:Invoke-CaelestiaSchemePruneHook} = { param($Stage, $Directory)
            if ($Stage -eq 'moved' -and $Directory -like '*c3c3c3*') {
                $strand.Module = [TRace.K]::LoadLibraryW((Join-Path $Directory 'lib\version.dll'))
                $strand.Stream = [IO.File]::Open((Join-Path $Directory 'lib\data.txt'), 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            }
        }.GetNewClosure()
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        $stranded = @(Get-ChildItem -LiteralPath (Join-Path $pruneRuntimes '.trash') -Directory -Force -ErrorAction SilentlyContinue)
        Assert ($stranded.Count -eq 1 -and (Get-DirectoryListing $stranded[0].FullName) -eq $strandBefore) 'A generation that could not be moved back was damaged or lost.'
        Assert (-not (Test-Path -LiteralPath $strandGeneration)) 'The stranded generation is still at its original path.'
        $journalPath = Join-Path $pruneProfile 'scheme\prune-restore.json'
        Assert (Test-Path -LiteralPath $journalPath) 'A failed move-back was not journaled for recovery.'
        $strandLog = Get-Content -LiteralPath (Join-Path $pruneProfile 'logs\scheme-runtime.log') -Raw
        Assert ($strandLog -match 'event=scheme-prune' -and $strandLog -match 'stranded=1' -and $strandLog -match 'recovery=journal' -and
            $strandLog -notmatch [regex]::Escape($root)) 'The failed move-back was not logged as structured, path-free diagnostics.'
    } finally {
        ${function:Invoke-CaelestiaSchemePruneHook} = $originalHook
        if ($strand.Stream) { $strand.Stream.Dispose() }
        if ($strand.Module -ne [IntPtr]::Zero) { $null = [TRace.K]::FreeLibrary($strand.Module) }
    }
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert ((Test-Path -LiteralPath $strandGeneration) -and (Get-DirectoryListing $strandGeneration) -eq $strandBefore) 'The journal did not restore the generation that could not be moved back.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $pruneRuntimes '.trash'))) 'The restored generation stayed in .trash.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $pruneProfile 'scheme\prune-restore.json'))) 'The restore journal was not cleared after recovery.'
    # Recovery leaves the generation alone for that prune; the next one can
    # retire it now that nothing holds it.
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (-not (Test-Path -LiteralPath $strandGeneration)) 'The restored generation was not retired by a later prune.'

    # A journal that cannot be read is not an empty journal. Prune must leave
    # the trash generation alone, then restore it on a later run once the
    # file can be read again.
    $lockedGeneration = 'f5' * 20
    $lockedLeaf = $lockedGeneration + '.a1b2c3d4'
    $lockedTrash = Join-Path $pruneRuntimes ('.trash\' + $lockedLeaf)
    New-Item -ItemType Directory -Force -Path $lockedTrash | Out-Null
    'awaiting-restore' | Set-Content -LiteralPath (Join-Path $lockedTrash 'marker.txt') -Encoding UTF8
    $lockedJournal = Join-Path $pruneSchemeRoot 'prune-restore.json'
    @{ generation = $lockedGeneration; trash = $lockedLeaf } | ConvertTo-Json | Set-Content -LiteralPath $lockedJournal -Encoding UTF8
    $lockedBefore = Get-Content -LiteralPath $lockedJournal -Raw
    $lockedStream = [IO.File]::Open($lockedJournal, 'Open', 'Read', 'None')
    try {
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        Assert (Test-Path -LiteralPath (Join-Path $lockedTrash 'marker.txt')) 'Prune deleted a generation whose restore journal could not be read.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $pruneRuntimes $lockedGeneration))) 'Prune restored a generation while its journal was still unreadable.'
    } finally { $lockedStream.Dispose() }
    Assert ((Get-Content -LiteralPath $lockedJournal -Raw) -eq $lockedBefore) 'An unreadable restore journal was rewritten.'
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    $lockedRestored = Join-Path (Join-Path $pruneRuntimes $lockedGeneration) 'marker.txt'
    Assert ((Get-Content -LiteralPath $lockedRestored -Raw).Trim() -eq 'awaiting-restore') 'The locked journal did not restore the generation on the next prune.'
    Assert (-not (Test-Path -LiteralPath $lockedTrash)) 'The restored generation stayed in .trash.'
    Assert (-not (Test-Path -LiteralPath $lockedJournal)) 'The restore journal was not cleared after the locked generation was restored.'

    # Interrupted staging directories (no lock holder owns them) are pruned, and
    # a partially deleted trash entry is finished by the next prune.
    $staleStaging = Join-Path $pruneRuntimes ('.staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $staleStaging 'venv') | Out-Null
    'partial' | Set-Content -LiteralPath (Join-Path $staleStaging 'venv\partial.txt') -Encoding UTF8
    $leftover = Join-Path $pruneRuntimes '.trash\old.deadbeef'
    New-Item -ItemType Directory -Force -Path $leftover | Out-Null
    'held' | Set-Content -LiteralPath (Join-Path $leftover 'held.txt') -Encoding UTF8
    'free' | Set-Content -LiteralPath (Join-Path $leftover 'free.txt') -Encoding UTF8
    $leftoverStream = [IO.File]::Open((Join-Path $leftover 'held.txt'), 'Open', 'Read', 'None')
    try {
        Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
        Assert (-not (Test-Path -LiteralPath $staleStaging)) 'Pruning kept an interrupted staging directory.'
        Assert ((Test-Path -LiteralPath (Join-Path $leftover 'held.txt')) -and -not (Test-Path -LiteralPath (Join-Path $leftover 'free.txt'))) `
            'A partial delete was not left in .trash for the next prune.'
    } finally { $leftoverStream.Dispose() }
    Remove-CaelestiaSchemeGenerations $prunePrefix $pruneProfile
    Assert (-not (Test-Path -LiteralPath $leftover)) 'The next prune did not finish a partial delete.'
    Assert ((Test-Path -LiteralPath (Join-Path $pruneRuntimes $gA)) -and (Test-Path -LiteralPath (Join-Path $pruneRuntimes $gB))) 'Cleanup removed a retained generation.'
    Write-Output 'PASS prune: rename-first ownership keeps busy generations whole, staging and partial deletes are cleaned.'

    # Structured fields come before any free text: redacting an unquoted path
    # consumes the rest of the line, so step/exit/count diagnostics must survive.
    Write-CaelestiaSchemeRuntimeLog -ProfileRoot $pruneProfile -Event 'scheme-test' `
        -Fields ([ordered]@{ step = 'probe'; exit = 3 }) -Message ('failed at ' + (Join-Path $root 'user secret.txt') + ' after the path')
    $structuredLog = Get-Content -LiteralPath (Join-Path $pruneProfile 'logs\scheme-runtime.log') -Raw
    Assert ($structuredLog -match 'event=scheme-test exit=3 step=probe' -and
        $structuredLog -notmatch [regex]::Escape($root)) 'Structured diagnostics were swallowed by path redaction.'

    # Health is verified, not assumed: a lost base interpreter, a failing or a
    # hung venv python is unhealthy, and selection only ever considers verified
    # generations, newest first.
    $hp = Join-Path $root 'hp'
    $hprofile = Join-Path $root 'hprof'
    New-Item -ItemType Directory -Force -Path (Join-Path $hp 'scheme') | Out-Null
    foreach ($name in @('requirements.lock.txt', 'win_scheme.py', 'fcntl.py')) {
        "health-$name" | Set-Content -LiteralPath (Join-Path $hp "scheme\$name") -Encoding UTF8
    }
    $hid = (Get-CaelestiaSchemeIdentity $hp 'rev-h').Id
    $hRuntimes = Join-Path $hprofile 'scheme\runtimes'
    $now = [DateTime]::UtcNow
    $oldGood = New-TestGeneration $hRuntimes ('9' * 40) 'rev-h' $hid $now.AddMinutes(-30)
    $brokenNewest = New-TestGeneration $hRuntimes ('1' * 40) 'rev-h' $hid $now.AddMinutes(-1) -BrokenBase
    Assert (Test-CaelestiaSchemeHealth $oldGood) 'A working venv python was reported unhealthy.'
    Assert (-not (Test-CaelestiaSchemeBase $brokenNewest)) 'A venv whose base interpreter is gone passed the file check.'
    Assert (-not (Test-CaelestiaSchemeHealth $brokenNewest)) 'A venv whose base interpreter is gone was reported healthy.'
    @{ available = $true; revision = 'rev-h'; generation = ('1' * 40)
       python = (Join-Path $brokenNewest 'venv\Scripts\python.exe'); helper = (Join-Path $brokenNewest 'win_scheme.py') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $hprofile 'scheme\runtime.json') -Encoding UTF8
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $hprofile 'rev-h' $hp)) 'A runtime with a lost base interpreter was accepted by activation.'
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $hprofile 'rev-h' $hp -Verify)) 'A runtime with a lost base interpreter was accepted by a start.'
    # Names sort the broken (newest) generation first: the old first-by-name
    # choice would have picked it.
    $chosen = Update-SchemeRuntimeForRevision $hprofile 'rev-h' $hp
    Assert ($chosen -and $chosen.generation -eq ('9' * 40) -and (Read-Pointer $hprofile).generation -eq ('9' * 40)) 'Repoint chose an unverified generation.'
    $null = New-TestGeneration $hRuntimes ('5' * 40) 'rev-h' $hid $now.AddMinutes(-10)
    $chosen = Update-SchemeRuntimeForRevision $hprofile 'rev-h' $hp
    Assert ($chosen -and $chosen.generation -eq ('5' * 40)) 'Repoint did not prefer the newest verified generation.'
    $chosen = Update-SchemeRuntimeForRevision $hprofile 'rev-h' $hp
    Assert ((Read-Pointer $hprofile).generation -eq ('5' * 40)) 'A second activation undid the repaired generation.'
    Remove-Item -LiteralPath (Join-Path (Join-Path $hRuntimes ('5' * 40)) 'base\python.exe') -Force
    Remove-Item -LiteralPath (Join-Path (Join-Path $hRuntimes ('9' * 40)) 'base\python.exe') -Force
    Assert ($null -eq (Update-SchemeRuntimeForRevision $hprofile 'rev-h' $hp)) 'Repoint returned an unverified generation.'
    # A failed check revokes the published generation: it must not stay
    # activatable just because its files exist.
    $revoked = Read-Pointer $hprofile
    Assert ($revoked.available -eq $false -and $revoked.generation -eq ('5' * 40)) 'A failed check left the rejected generation published.'
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $hprofile 'rev-h' $hp)) 'Activation accepted a generation that failed its check.'

    $vprofile = Join-Path $root 'vp'
    $vGeneration = New-TestGeneration (Join-Path $vprofile 'scheme\runtimes') ('7' * 40) 'rev-h' $hid
    $published = Publish-CaelestiaSchemeRuntime $vprofile 'rev-h' $vGeneration
    Assert ($published.verification.baseInterpreter -and $published.verification.pyvenvSha256) 'The published record carries no verification receipt.'
    Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp -Verify)) 'A healthy runtime was rejected.'
    # Activation accepts a receipt by file metadata alone: no process starts.
    $probeLog = Join-Path $root 'probe.log'
    $env:CAELESTIA_TEST_PROVISION_LOG = $probeLog
    try {
        Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Activation rejected a runtime with a valid receipt.'
        Assert (-not (Test-Path -LiteralPath $probeLog)) 'Activation started a process to check the runtime.'
    } finally { $env:CAELESTIA_TEST_PROVISION_LOG = $null }
    # A check that fails (here: the venv python cannot import) revokes the
    # record, through repoint and through a start.
    $env:CAELESTIA_TEST_CHECK_EXIT = '3'
    try {
        Assert (-not (Test-CaelestiaSchemeHealth $vGeneration)) 'A venv python that fails its import was reported healthy.'
        Assert ($null -eq (Update-SchemeRuntimeForRevision $vprofile 'rev-h' $hp)) 'Repoint returned a generation whose python fails.'
        Assert ((Read-Pointer $vprofile).available -eq $false) 'A failed repoint left the rejected generation published.'
        Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Activation reused a generation that failed its check.'
    } finally { $env:CAELESTIA_TEST_CHECK_EXIT = $null }
    $null = Update-SchemeRuntimeForRevision $vprofile 'rev-h' $hp
    Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'A healthy generation was not republished.'
    $env:CAELESTIA_TEST_CHECK_EXIT = '3'
    try {
        Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp -Verify)) 'A start accepted a runtime whose python fails.'
        Assert ((Read-Pointer $vprofile).available -eq $false) 'A failed start check left the rejected generation published.'
    } finally { $env:CAELESTIA_TEST_CHECK_EXIT = $null }
    $null = Update-SchemeRuntimeForRevision $vprofile 'rev-h' $hp
    # The receipt covers the base interpreter and pyvenv.cfg. Changing either
    # invalidates it without a process: here pyvenv.cfg points at another
    # interpreter that exists but was never verified.
    $config = Join-Path $vGeneration 'venv\pyvenv.cfg'
    $configText = [IO.File]::ReadAllText($config)
    $otherBase = Join-Path $vGeneration 'base2'
    New-Item -ItemType Directory -Force -Path $otherBase | Out-Null
    Copy-Item -LiteralPath (Get-FakePythonFixture) -Destination (Join-Path $otherBase 'python.exe')
    [IO.File]::WriteAllText($config, "home = $otherBase`r`n")
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Activation accepted a changed pyvenv.cfg.'
    [IO.File]::WriteAllText($config, $configText)
    Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Restoring pyvenv.cfg did not restore the receipt.'
    $baseDirectory = Join-Path $vGeneration 'base'
    [IO.File]::WriteAllText((Join-Path $baseDirectory 'python312.dll'), 'runtime dll v1')
    [IO.File]::WriteAllText((Join-Path $baseDirectory 'python3.dll'), 'stable abi dll')
    $null = Update-SchemeRuntimeForRevision $vprofile 'rev-h' $hp
    Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'A receipt that covers runtime DLLs was rejected.'
    Assert ((Read-Pointer $vprofile).verification.runtimeDlls -match 'python312\.dll' -and (Read-Pointer $vprofile).verification.runtimeDlls -match 'python3\.dll') 'The receipt does not record the runtime DLLs.'
    $runtimeDll = Join-Path $baseDirectory 'python312.dll'
    $runtimeDllTime = (Get-Item -LiteralPath $runtimeDll).LastWriteTimeUtc
    [IO.File]::WriteAllText($runtimeDll, 'runtime dll v2, replaced')
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Activation accepted a replaced python3XX.dll.'
    [IO.File]::WriteAllText($runtimeDll, 'runtime dll v1')
    (Get-Item -LiteralPath $runtimeDll).LastWriteTimeUtc = $runtimeDllTime
    Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Restoring python3XX.dll did not restore the receipt.'
    (Get-Item -LiteralPath $runtimeDll).LastWriteTimeUtc = $runtimeDllTime.AddMinutes(-3)
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Activation accepted a python3XX.dll with a new timestamp.'
    (Get-Item -LiteralPath $runtimeDll).LastWriteTimeUtc = $runtimeDllTime
    $stableTime = (Get-Item -LiteralPath (Join-Path $baseDirectory 'python3.dll')).LastWriteTimeUtc
    Remove-Item -LiteralPath (Join-Path $baseDirectory 'python3.dll') -Force
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Activation accepted a missing python3.dll.'
    [IO.File]::WriteAllText((Join-Path $baseDirectory 'python3.dll'), 'stable abi dll')
    (Get-Item -LiteralPath (Join-Path $baseDirectory 'python3.dll')).LastWriteTimeUtc = $stableTime
    # A receipt that changes between selection and publish is final as well: no
    # second probe, and the record becomes "unavailable".
    $decision = Select-CaelestiaSchemeGeneration $vprofile 'rev-h' $hp
    Assert ($decision -and $decision.Root) 'Selection did not find the healthy generation.'
    (Get-Item -LiteralPath $runtimeDll).LastWriteTimeUtc = $runtimeDllTime.AddMinutes(-9)
    $lateLog = Join-Path $root 'late.log'
    $env:CAELESTIA_TEST_PROVISION_LOG = $lateLog
    try { $late = Set-CaelestiaSchemeRuntimeForRevision $vprofile 'rev-h' $hp -Verified $decision }
    finally { $env:CAELESTIA_TEST_PROVISION_LOG = $null }
    Assert ($null -eq $late) 'A changed receipt was published.'
    Assert (-not (Test-Path -LiteralPath $lateLog)) 'A changed receipt triggered another probe.'
    Assert ((Read-Pointer $vprofile).available -eq $false) 'A changed receipt left the record published.'
    (Get-Item -LiteralPath $runtimeDll).LastWriteTimeUtc = $runtimeDllTime
    $null = Update-SchemeRuntimeForRevision $vprofile 'rev-h' $hp
    Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Republishing after a restored receipt failed.'
    # The post-stop setter keeps the published record only while its receipt
    # matches, and never starts a process.
    $noProbeLog = Join-Path $root 'noprobe.log'
    $env:CAELESTIA_TEST_PROVISION_LOG = $noProbeLog
    try {
        $kept = Set-CaelestiaSchemeRuntimeForRevision $vprofile 'rev-h' $hp
        Assert ($kept -and $kept.generation -eq ('7' * 40)) 'A matching receipt was not kept by the post-stop setter.'
        (Get-Item -LiteralPath $runtimeDll).LastWriteTimeUtc = $runtimeDllTime.AddMinutes(-4)
        $dropped = Set-CaelestiaSchemeRuntimeForRevision $vprofile 'rev-h' $hp
        Assert ($null -eq $dropped -and (Read-Pointer $vprofile).available -eq $false) 'A changed receipt was kept by the post-stop setter.'
        Assert (-not (Test-Path -LiteralPath $noProbeLog)) 'The post-stop setter started a process.'
    } finally {
        $env:CAELESTIA_TEST_PROVISION_LOG = $null
        (Get-Item -LiteralPath $runtimeDll).LastWriteTimeUtc = $runtimeDllTime
    }
    $null = Update-SchemeRuntimeForRevision $vprofile 'rev-h' $hp
    Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Republishing after the no-probe check failed.'
    $baseExe = Join-Path $vGeneration 'base\python.exe'
    $baseTime = (Get-Item -LiteralPath $baseExe).LastWriteTimeUtc
    (Get-Item -LiteralPath $baseExe).LastWriteTimeUtc = $baseTime.AddMinutes(-7)
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Activation accepted a base interpreter that changed.'
    (Get-Item -LiteralPath $baseExe).LastWriteTimeUtc = $baseTime
    Assert ($null -ne (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp)) 'Restoring the base interpreter did not restore the receipt.'
    $env:CAELESTIA_TEST_CHECK_SECONDS = '30'
    try {
        $probeClock = [Diagnostics.Stopwatch]::StartNew()
        Assert (-not (Test-CaelestiaSchemeHealth $vGeneration 2)) 'A hung venv python was reported healthy.'
        Assert ($probeClock.Elapsed.TotalSeconds -lt 15) 'A hung interpreter was not bounded by its timeout.'
    } finally { $env:CAELESTIA_TEST_CHECK_SECONDS = $null }
    # One time budget covers all candidates, newest first, each probed for only
    # a slice of it; a healthy older generation is still reached.
    $bprofile = Join-Path $root 'bp'
    $bRuntimes = Join-Path $bprofile 'scheme\runtimes'
    foreach ($spec in @(@('4', -1), @('5', -2), @('6', -3))) {
        $hung = New-TestGeneration $bRuntimes ($spec[0] * 40) 'rev-h' $hid $now.AddMinutes($spec[1])
        'hang' | Set-Content -LiteralPath (Join-Path $hung 'venv\Scripts\hang.txt')
    }
    $null = New-TestGeneration $bRuntimes ('8' * 40) 'rev-h' $hid $now.AddMinutes(-30)
    $budgetClock = [Diagnostics.Stopwatch]::StartNew()
    $none = Update-SchemeRuntimeForRevision $bprofile 'rev-h' $hp -BudgetSeconds 6 -CandidateSeconds 2
    $budgetElapsed = $budgetClock.Elapsed.TotalSeconds
    Assert ($null -eq $none) 'Repoint returned a generation although the probe budget ran out on hung candidates.'
    Assert ($budgetElapsed -lt 12) "Three hung candidates cost $([Math]::Round($budgetElapsed, 1)) s; the budget was not enforced."
    Remove-Item -LiteralPath (Join-Path (Join-Path (Join-Path $bRuntimes ('5' * 40)) 'venv\Scripts') 'hang.txt'), (Join-Path (Join-Path (Join-Path $bRuntimes ('6' * 40)) 'venv\Scripts') 'hang.txt') -Force
    # Only the newest hangs now: the next candidate must still be tried.
    'hang' | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $bRuntimes ('4' * 40)) 'venv\Scripts') 'hang.txt')
    $budgetClock.Restart()
    $fallback = Update-SchemeRuntimeForRevision $bprofile 'rev-h' $hp -BudgetSeconds 6 -CandidateSeconds 2
    Assert ($fallback -and $fallback.generation -eq ('5' * 40)) 'A hung newest generation starved a healthy fallback.'
    Assert ($budgetClock.Elapsed.TotalSeconds -lt 10) 'The hung newest generation cost more than its slice.'

    # A real venv records its base in pyvenv.cfg; losing that base must fail the check.
    $realPy = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($realPy) {
        $realRoot = Join-Path $root 'rv'
        New-Item -ItemType Directory -Force -Path $realRoot | Out-Null
        & $realPy.Source -3 -m venv (Join-Path $realRoot 'venv') 2>$null
        $realVenvOk = $LASTEXITCODE -eq 0
        if (-not $realVenvOk) { Write-Output 'SKIP real venv: py could not create a virtual environment.' }
        if ($realVenvOk) {
            'x' | Set-Content -LiteralPath (Join-Path $realRoot 'win_scheme.py') -Encoding UTF8
            '{}' | Set-Content -LiteralPath (Join-Path $realRoot 'generation.json') -Encoding UTF8
            Assert (Test-CaelestiaSchemeBase $realRoot) 'A real venv failed the base check.'
            $config = Join-Path $realRoot 'venv\pyvenv.cfg'
            $text = [IO.File]::ReadAllText($config) -replace '(?m)^home\s*=.*$', ('home = ' + (Join-Path $root 'gone-python'))
            [IO.File]::WriteAllText($config, $text)
            Assert (-not (Test-CaelestiaSchemeBase $realRoot)) 'A real venv with a lost base interpreter passed the base check.'
        }
        $global:LASTEXITCODE = 0
        if ($realVenvOk) { Write-Output 'PASS real venv: pyvenv.cfg home is honoured; a lost base interpreter fails the check.' }
    } else {
        Write-Output 'SKIP real venv: the Python launcher (py) is not available on this machine.'
    }
    Write-Output 'PASS health: lost or failing base interpreters are rejected; selection is verified and newest-first; activation starts no process.'

    # Every file copied into a generation is part of its identity, so a shim or
    # helper change invalidates cached generations everywhere they are compared.
    $hp2 = Join-Path $root 'hp2'
    Copy-Item -LiteralPath $hp -Destination $hp2 -Recurse
    $idBefore = Get-CaelestiaSchemeIdentity $hp2 'rev-h'
    'changed shim' | Set-Content -LiteralPath (Join-Path $hp2 'scheme\fcntl.py') -Encoding UTF8
    $idAfter = Get-CaelestiaSchemeIdentity $hp2 'rev-h'
    Assert ($idBefore.Id -ne $idAfter.Id -and $idBefore.ShimSha256 -ne $idAfter.ShimSha256 -and $idBefore.HelperSha256 -eq $idAfter.HelperSha256) 'The fcntl shim is not part of the generation identity.'
    Assert ($null -eq (Get-CaelestiaPreparedSchemeRuntime $vprofile 'rev-h' $hp2)) 'Activation accepted a generation built with a different shim.'
    Assert ($null -eq (Update-SchemeRuntimeForRevision $vprofile 'rev-h' $hp2)) 'Repoint accepted a generation built with a different shim.'
    Assert ($null -ne (Update-SchemeRuntimeForRevision $vprofile 'rev-h' $hp)) 'Repoint rejected a generation built with the current inputs.'
    Write-Output 'PASS identity: shim and helper changes invalidate prepared and repointed generations.'

    # Diagnostics are redacted by pattern, so custom install, Python and temp
    # paths cannot reach logs. Markers start with Zq so a leak is unmistakable.
    $redacted = Protect-CaelestiaText (@(
        'failed at D:\ZqCustom Tools\Py 3.12\Scripts\pip.exe with exit 1',
        'cannot read \\zqserver\ZqShare\Team Dir\cache\wheel.whl',
        'open \\?\E:\ZqOpt\caelestia\lib\site.py failed',
        'bad file:///F:/ZqFile%20Where/a.txt here',
        '{"path":"G:\\ZqApps\\Caelestia\\x.json"}',
        'temp C:/Users/ZqPerson/AppData/Local/Temp/pip-1/x',
        'fetching https://pypi.org/simple/pillow/ exit code 3'
    ) -join "`n")
    Assert ($redacted -notmatch 'Zq|Py 3\.12|Team Dir|Scripts|AppData') "Redaction leaked a path fragment: $redacted"
    Assert ($redacted -match 'failed at <path>' -and $redacted -match 'bad <file-url>' -and $redacted -match '<path>\.json') 'Redaction did not keep the surrounding text and leaf extension.'
    Assert ($redacted -match 'https://pypi\.org/simple/pillow/ exit code 3') 'Redaction altered a web URL.'
    # File names with spaces, quotes, UNC, forward slashes and file URLs must
    # not leak any part of the name; over-redacting is acceptable.
    $spaced = @(
        'D:\Example\Confidential Person.txt',
        'could not open D:\Example Dir\Confidential Person.txt: access denied',
        'cannot read "D:\Example Dir\Confidential Person.txt" now',
        "cannot read 'D:\Example Dir\Confidential Person.txt' now",
        '\\fileserver\Example Share\Confidential Person.txt',
        'open \\fileserver\Example Share\Confidential Person.txt, then retry',
        'C:/Users/Example Person/Confidential Person.txt',
        'wrote "C:/Users/Example Person/Confidential Person.txt"; done',
        'file:///D:/Example%20Dir/Confidential%20Person.txt',
        'file:///D:/Example Dir/Confidential Person.txt',
        'path=''C:\Users\Bob''s Files\Confidential Person.txt'' end',
        '{"file":"D:\\Example Dir\\Confidential Person.txt","n":1}',
        'seen D:\Example\Confidential Person.txt | next'
    )
    foreach ($sample in $spaced) {
        $cleaned = Protect-CaelestiaText $sample
        Assert ($cleaned -notmatch 'Example|Confidential|Person|Bob|fileserver') "Redaction leaked part of '$sample': $cleaned"
        Assert ($cleaned -match '<path>|<file-url>') "Redaction left no placeholder for '$sample': $cleaned"
    }
    Assert ((Protect-CaelestiaText 'cannot read "D:\Example Dir\Confidential Person.txt" now') -eq 'cannot read "<path>.txt" now') 'A quoted path was not replaced as one unit.'
    Assert ((Protect-CaelestiaText 'exit 1 after 3 retries') -eq 'exit 1 after 3 retries') 'Redaction changed text with no path.'
    Write-Output 'PASS redaction: any absolute Windows path or file URL is replaced, whatever the prefix.'

    # Concurrency and immutability: installer prepare and a normal start race
    # on a cold profile with a fake Python that records its pip steps. One
    # provisioner may run, and a forced repair must publish a new generation
    # without touching the published one.
    $generationProfile = Join-Path $root 'generation-profile'
    [IO.Directory]::CreateDirectory($generationProfile) | Out-Null
    $fakePython = Get-FakePythonFixture
    $fakeDirectory = Split-Path -Parent $fakePython
    $fakeLog = Join-Path $root 'fake-python.log'
    $oldPath = $env:PATH
    $oldProvisionLog = $env:CAELESTIA_TEST_PROVISION_LOG
    $oldPipSeconds = $env:CAELESTIA_TEST_PIP_SECONDS
    try {
        $env:PATH = "$fakeDirectory;$oldPath"
        $env:CAELESTIA_TEST_PROVISION_LOG = $fakeLog
        $env:CAELESTIA_TEST_PIP_SECONDS = '2'
        # Both installer preparation and Start-Caelestia run this provisioning
        # step; drive it directly with the same lock waits they use.
        $calculator = Join-Path $PSScriptRoot 'Install-SchemeRuntime.ps1'
        function Start-SchemeProvision([int]$LockWaitSeconds, [string]$Name, [string]$Profile = $generationProfile) {
            $stdout = Join-Path $root "$Name.out"
            $stderr = Join-Path $root "$Name.err"
            $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $calculator +
                '" -ProfileRoot "' + $Profile + '" -LockWaitSeconds ' + $LockWaitSeconds
            $process = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList $arguments `
                -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            return [pscustomobject]@{ Process = $process; Stdout = $stdout }
        }
        $prepareJob = Start-SchemeProvision 30 'concurrent-prepare'
        # Wait for the installer's provisioner to reach the venv step while it
        # holds the lock, then start a normal start against the same profile.
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        $provisioning = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $fakeLog) {
                try {
                    if ((Get-Content -LiteralPath $fakeLog -Raw) -match 'venv') { $provisioning = $true; break }
                } catch { }
            }
            Start-Sleep -Milliseconds 50
        }
        Assert $provisioning 'Installer preparation did not start.'
        $startClock = [Diagnostics.Stopwatch]::StartNew()
        $startJob = Start-SchemeProvision 0 'concurrent-start'
        if (-not $startJob.Process.WaitForExit(10000)) {
            $startJob.Process.Kill()
            $startJob.Process.WaitForExit()
            throw 'A start waited for the provisioner.'
        }
        $startElapsed = $startClock.Elapsed.TotalSeconds
        if (-not $prepareJob.Process.WaitForExit(120000)) {
            $prepareJob.Process.Kill()
            $prepareJob.Process.WaitForExit()
            throw "Concurrent scheme provisioning timed out: $($prepareJob.Stdout)"
        }
        $startResult = Read-SchemeResult $startJob.Stdout
        $prepareResult = Read-SchemeResult $prepareJob.Stdout
        Assert ($null -ne $startResult -and $null -ne $prepareResult) 'A concurrent provisioning process produced no result.'
        Assert ($startResult.inProgress -eq $true -and $startResult.available -eq $false) 'A start did not report provisioning in progress.'
        Assert ($startElapsed -lt 5) "A start waited $([Math]::Round($startElapsed, 1)) s for the provisioner."
        Assert ($prepareResult.available -eq $true) 'Installer preparation did not publish a runtime.'
        $events = @(Get-Content -LiteralPath $fakeLog | ForEach-Object {
            $parts = $_ -split ','
            [pscustomobject]@{ Ticks = [long]$parts[0]; Event = $parts[2] }
        })
        $pipStarts = @($events | Where-Object Event -eq 'pip-start')
        $pipEnds = @($events | Where-Object Event -eq 'pip-end')
        Assert ($pipStarts.Count -eq 2 -and $pipEnds.Count -eq 2) "Expected one provisioner's two pip steps, saw $($pipStarts.Count) starts and $($pipEnds.Count) ends."
        $active = 0
        foreach ($event in @($events | Where-Object { $_.Event -in @('pip-start', 'pip-end') } | Sort-Object Ticks)) {
            if ($event.Event -eq 'pip-start') {
                $active++
                Assert ($active -le 1) 'Two provisioners ran pip at the same time.'
            } else {
                $active--
            }
        }
        $published = if ($startResult.available -eq $true) { [string]$startResult.generation } else { [string]$prepareResult.generation }
        Assert ($published) 'The concurrent run did not report its generation.'
        $generationRoot = Join-Path $generationProfile "scheme\runtimes\$published"
        $before = Get-DirectoryHash $generationRoot
        # A cache hit validates the published generation without touching it.
        $cacheOut = Join-Path $root 'cache.out'
        $cacheErr = Join-Path $root 'cache.err'
        $cacheArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $calculator +
            '" -ProfileRoot "' + $generationProfile + '" -LockWaitSeconds 30'
        $cacheRun = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList $cacheArguments `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $cacheOut -RedirectStandardError $cacheErr
        if (-not $cacheRun.WaitForExit(120000)) {
            $cacheRun.Kill()
            $cacheRun.WaitForExit()
            throw 'Cached scheme validation timed out.'
        }
        $cacheResult = Read-SchemeResult $cacheOut
        Assert ($cacheResult -and $cacheResult.available -eq $true -and $cacheResult.generation -eq $published) 'A cache hit did not reuse the published generation.'
        Assert ((Get-DirectoryHash $generationRoot) -eq $before) 'A cache hit modified the published generation.'
        $repairOut = Join-Path $root 'repair.out'
        $repairErr = Join-Path $root 'repair.err'
        $repairArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $calculator +
            '" -ProfileRoot "' + $generationProfile + '" -Force -LockWaitSeconds 30'
        $repair = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList $repairArguments `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $repairOut -RedirectStandardError $repairErr
        if (-not $repair.WaitForExit(120000)) {
            $repair.Kill()
            $repair.WaitForExit()
            throw 'Forced scheme repair timed out.'
        }
        $repairResult = Read-SchemeResult $repairOut
        Assert ($repairResult -and $repairResult.available -eq $true) 'Forced scheme repair did not publish a runtime.'
        Assert ($repairResult.generation -ne $published) 'Repair reused the published generation.'
        Assert ((Get-DirectoryHash $generationRoot) -eq $before) 'Repair modified a published runtime generation.'
        $history = Get-Content -LiteralPath (Join-Path $generationProfile 'scheme\provision.log') -Raw
        Assert ($history -notmatch [regex]::Escape($generationProfile)) 'Provisioning history exposed a profile path.'
        Write-Output 'PASS scheme generations: one provisioner at a time, repair publishes a new generation, published bytes stay unchanged.'

        # Every spelling of one profile path takes the same lock: a second
        # provisioner started with a different spelling must see it in progress
        # instead of running pip at the same time.
        $canonProfile = Join-Path $root 'cp'
        [IO.Directory]::CreateDirectory($canonProfile) | Out-Null
        $canonical = Get-CaelestiaCanonicalPath $canonProfile
        $spellings = @(
            ($canonProfile + '\'), ($canonProfile + '\\'), $canonProfile.ToUpperInvariant(), $canonProfile.Replace('\', '/'),
            ('\\?\' + $canonProfile), ($canonProfile + '\sub\..')
        )
        $shortPath = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($canonProfile).ShortPath
        if ($shortPath) { $spellings += $shortPath }
        foreach ($spelling in $spellings) {
            Assert ((Get-CaelestiaCanonicalPath $spelling) -eq $canonical) "A profile path spelling was not canonicalised: $spelling"
        }
        Assert ((Get-CaelestiaCanonicalPath 'C:\') -eq 'c:\' -and (Get-CaelestiaCanonicalPath 'C:\\') -eq 'c:\') 'A drive root lost its separator.'
        $canonLog = Join-Path $root 'canon.log'
        $env:CAELESTIA_TEST_PROVISION_LOG = $canonLog
        $env:CAELESTIA_TEST_PIP_SECONDS = '2'
        $first = Start-SchemeProvision 30 'canon-first' $canonProfile
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        $started = $false
        while ([DateTime]::UtcNow -lt $deadline -and -not $started) {
            if (Test-Path -LiteralPath $canonLog) { try { $started = (Get-Content -LiteralPath $canonLog -Raw) -match 'venv' } catch { } }
            if (-not $started) { Start-Sleep -Milliseconds 50 }
        }
        Assert $started 'The first provisioner did not start.'
        # A trailing separator reaches the script through the argument quoting.
        $second = Start-SchemeProvision 0 'canon-second' ($canonProfile.ToUpperInvariant() + '\\')
        if (-not $second.Process.WaitForExit(10000)) { $second.Process.Kill(); $second.Process.WaitForExit(); throw 'A second spelling waited for the provisioner.' }
        $secondResult = Read-SchemeResult $second.Stdout
        Assert ($secondResult -and $secondResult.inProgress -eq $true) 'A different spelling of the profile path took a different lock.'
        if (-not $first.Process.WaitForExit(120000)) { $first.Process.Kill(); $first.Process.WaitForExit(); throw 'The first provisioner timed out.' }
        $pipStarts = @((Get-Content -LiteralPath $canonLog) | Where-Object { $_ -match ',pip-start$' })
        Assert ($pipStarts.Count -eq 2) "Expected one provisioner's pip steps, saw $($pipStarts.Count)."
        Write-Output 'PASS lock identity: equivalent profile paths share one provisioning lock.'

        # A changed shim builds a new generation instead of reusing the cache,
        # and a lost base interpreter is repaired with a verified sibling that
        # activation then keeps.
        $env:CAELESTIA_TEST_PIP_SECONDS = '0'
        $ip = Join-Path $root 'ip'
        New-Item -ItemType Directory -Force -Path (Join-Path $ip 'scheme') | Out-Null
        foreach ($name in @('Install-SchemeRuntime.ps1', 'Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $ip
        }
        foreach ($name in @('requirements.lock.txt', 'win_scheme.py', 'fcntl.py')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot "scheme\$name") -Destination (Join-Path $ip 'scheme')
        }
        $ipProfile = Join-Path $root 'ipp'
        function Invoke-Provisioner([string[]]$Extra = @()) {
            $out = Join-Path $root ('prov-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.out')
            $err = $out + '.err'
            $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $ip 'Install-SchemeRuntime.ps1') +
                '" -ProfileRoot "' + $ipProfile + '" -CliRevision rev-x -LockWaitSeconds 30 ' + ($Extra -join ' ')
            $run = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList $arguments -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $out -RedirectStandardError $err
            if (-not $run.WaitForExit(120000)) { $run.Kill(); $run.WaitForExit(); throw 'The provisioner timed out.' }
            return [pscustomobject]@{ Result = (Read-SchemeResult $out); Stdout = $out; Stderr = $err }
        }
        $run1 = Invoke-Provisioner
        Assert ($run1.Result.available -eq $true -and $run1.Result.generation -and
            (Read-Pointer $ipProfile).generation -eq $run1.Result.generation) 'The first provision did not publish a generation.'
        $run2 = Invoke-Provisioner
        Assert ($run2.Result.available -eq $true -and $run2.Result.generation -eq $run1.Result.generation) 'An unchanged payload did not reuse its generation.'
        'a different shim' | Set-Content -LiteralPath (Join-Path $ip 'scheme\fcntl.py') -Encoding UTF8
        $run3 = Invoke-Provisioner
        Assert ($run3.Result.available -eq $true -and $run3.Result.generation -and
            $run3.Result.generation -ne $run1.Result.generation -and
            (Read-Pointer $ipProfile).generation -eq $run3.Result.generation) 'A changed shim did not publish a new generation.'
        $runtimes = Join-Path $ipProfile 'scheme\runtimes'
        Assert (Test-Path -LiteralPath (Join-Path $runtimes $run1.Result.generation)) 'A shim change removed the earlier generation.'
        $newShim = Join-Path $runtimes "$($run3.Result.generation)\venv\Lib\site-packages\fcntl.py"
        Assert ((Get-Content -LiteralPath $newShim -Raw).Trim() -eq 'a different shim') 'The new generation does not contain the new shim.'
        $newMeta = Get-Content -LiteralPath (Join-Path $runtimes "$($run3.Result.generation)\generation.json") -Raw | ConvertFrom-Json
        Assert ($newMeta.identity -eq (Get-CaelestiaSchemeIdentity $ip 'rev-x').Id -and $newMeta.shimSha256) 'The generation does not record the identity it was built from.'

        $pyvenvCfg = Join-Path $runtimes "$($run3.Result.generation)\venv\pyvenv.cfg"
        [IO.File]::WriteAllText($pyvenvCfg, "home = $(Join-Path $root 'gone-python')`r`n")
        $run4 = Invoke-Provisioner
        Assert ($run4.Result.available -eq $true -and $run4.Result.generation -ne $run3.Result.generation) 'A lost base interpreter was not repaired with a new generation.'
        $heldPointer = Read-Pointer $ipProfile
        Assert ($heldPointer.generation -eq $run4.Result.generation) 'The repaired generation was not published.'
        $kept = Update-SchemeRuntimeForRevision $ipProfile 'rev-x' $ip
        Assert ($kept.generation -eq $run4.Result.generation -and (Read-Pointer $ipProfile).generation -eq $run4.Result.generation) 'Activation swapped the repaired generation back to the broken one.'
        Write-Output 'PASS identity: a shim change builds a new generation; a lost base interpreter is repaired and stays repaired.'

        # A failing provision reports no machine paths in its warning, record
        # or history, whatever the install, Python or temp location.
        $env:CAELESTIA_TEST_PIP_FAIL = 'Z:\ZqCustom Prefix\Py 3.12\site.py'
        try {
            'a failing shim' | Set-Content -LiteralPath (Join-Path $ip 'scheme\fcntl.py') -Encoding UTF8
            $run5 = Invoke-Provisioner -Extra @('-Force')
        } finally { $env:CAELESTIA_TEST_PIP_FAIL = $null }
        Assert ($run5.Result.available -eq $false) 'The injected provisioning failure was not reported.'
        $leakSources = @(
            (Get-Content -LiteralPath $run5.Stdout -Raw), (Get-Content -LiteralPath $run5.Stderr -Raw),
            (Get-Content -LiteralPath (Join-Path $ipProfile 'scheme\provision.log') -Raw),
            (Get-Content -LiteralPath (Join-Path $ipProfile 'scheme\provision-state.json') -Raw)
        ) -join "`n"
        Assert ($leakSources -match 'could not open <path>\.py') 'The failure record lost its redacted detail.'
        $failedState = Get-Content -LiteralPath (Join-Path $ipProfile 'scheme\provision-state.json') -Raw | ConvertFrom-Json
        Assert ($failedState.exitCode -eq '1' -and $failedState.step -match 'materialyoucolor') 'The step and exit code are not recorded as fields of their own.'
        Assert ((Get-Content -LiteralPath (Join-Path $ipProfile 'scheme\provision.log') -Raw) -match 'FAILED step=installing materialyoucolor/pillow exit=1 :') 'The history line lost the step and exit code.'
        Assert ($leakSources -notmatch 'Zq|Py 3\.12') 'A custom-prefix path reached provisioning diagnostics.'
        Write-Output 'PASS diagnostics: a custom-prefix path is redacted from warnings, state and history.'
    } finally {
        $env:PATH = $oldPath
        $env:CAELESTIA_TEST_PROVISION_LOG = $oldProvisionLog
        $env:CAELESTIA_TEST_PIP_SECONDS = $oldPipSeconds
    }

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
    Assert ($failedProvision.available -eq $false) 'A provisioning failure escaped the installer phase.'
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
        catch { $refused = $true }
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
        catch { $refused = $true }
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
    # A cleanup problem is reported, but must not hide the failure that got us here.
    try { Remove-Item -LiteralPath $safe -Recurse -Force -ErrorAction Stop }
    catch { Write-Warning "Test directory was not fully deleted: $safe" }
}
