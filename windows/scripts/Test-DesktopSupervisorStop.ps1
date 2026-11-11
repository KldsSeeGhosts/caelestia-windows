[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-supervisor-stop-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$children = [Collections.Generic.List[Diagnostics.Process]]::new()
$watchdogs = [Collections.Generic.List[Diagnostics.Process]]::new()
$token = [guid]::NewGuid().ToString('N')
$mutexName = 'Local\CaelestiaDesktopTakeover-Test-' + $token
$powershell = Get-WindowsPowerShellPath

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Replace-Exactly([string]$Text, [string]$Old, [string]$New) {
    Assert ([regex]::Matches($Text, [regex]::Escape($Old)).Count -eq 1) 'Fixture injection boundary changed; refusing to run.'
    return $Text.Replace($Old, $New)
}
function Start-FixtureProcess([string]$Executable, [string]$Arguments, [string]$Directory, [string]$Log) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $Directory `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput ($Log + '.out') -RedirectStandardError ($Log + '.err')
    $null = $process.Handle
    $children.Add($process)
    return $process
}
function Wait-Until([scriptblock]$Condition, [string]$Message, [int]$Milliseconds = 15000) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($clock.ElapsedMilliseconds -ge $Milliseconds) { throw $Message }
        Start-Sleep -Milliseconds 25
    }
}
try {
    $scripts = Join-Path $root 'scripts'
    [IO.Directory]::CreateDirectory($scripts) | Out-Null
    foreach ($name in @('Start-Caelestia.ps1', 'Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts
    }
    # Only the named synchronization objects and isolated entrypoint change.
    # The launcher, IPC, supervisor Tick/Dispose and process discovery stay real.
    # Fail closed before executing any copy if either injection no longer matches.
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'DesktopTakeover.cs'))
    $source = Replace-Exactly $source `
        'return @"Local\CaelestiaDesktopTakeover-" + Process.GetCurrentProcess().SessionId;' `
        ('return @"' + $mutexName + '";')
    [IO.File]::WriteAllText((Join-Path $scripts 'DesktopTakeover.cs'), $source)
    $watch = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Watch-DesktopShell.ps1'))
    $watch = Replace-Exactly $watch `
        '[Caelestia.Takeover.Supervisor]::Run([IO.Path]::GetFullPath($LaunchSpec), $hideTaskbar, $restartOnCrash, ($suppression -ceq ''invisible''))' `
        ('[Caelestia.Takeover.Supervisor]::RunIsolatedTest([IO.Path]::GetFullPath($LaunchSpec), "' + $token + '")')
    [IO.File]::WriteAllText((Join-Path $scripts 'Watch-DesktopShell.ps1'), $watch)
    Add-Type -Path (Join-Path $scripts 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    $grace = [Caelestia.Takeover.Supervisor]::ChildExitGraceMs
    Assert ($grace + 45000 + 2000 + 1000 -lt [Caelestia.Takeover.Supervisor]::RecoveryBoundMs) 'Child grace consumes the restore budget.'

    # A console fake stands in for qs. The witness owns a hidden, offscreen
    # window only, never a visible window, AppBar, shortcut or taskbar change.
    $fake = Join-Path $root 'qs.exe'
    Add-Type -OutputAssembly $fake -OutputType ConsoleApplication -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
public sealed class StopFixtureWindow : NativeWindow, IDisposable {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern ushort GlobalAddAtom(string name);
    [DllImport("kernel32.dll")] static extern ushort GlobalDeleteAtom(ushort atom);
    [DllImport("user32.dll")] static extern bool SetProp(IntPtr window, IntPtr name, IntPtr value);
    [DllImport("user32.dll")] static extern IntPtr GetProp(IntPtr window, IntPtr name);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    struct Rect { public int Left, Top, Right, Bottom; }
    readonly ushort atom;
    public StopFixtureWindow() {
        CreateHandle(new CreateParams { Caption = "isolated stop fixture", Style = unchecked((int)0x80000000), ExStyle = 0x08000080 });
        atom = GlobalAddAtom("QuickshellTilingParked");
        ulong packed = 100UL | (100UL << 16) | (100UL << 32) | (100UL << 48);
        if (atom == 0 || !SetProp(Handle, new IntPtr(atom), new IntPtr(unchecked((long)packed)))
            || !SetWindowPos(Handle, IntPtr.Zero, -30000, -30000, 100, 100, 0x14))
            throw new InvalidOperationException("Could not prepare hidden fixture window.");
    }
    public bool Restored {
        get { Rect r; return GetProp(Handle, new IntPtr(atom)) == IntPtr.Zero
            && GetWindowRect(Handle, out r) && r.Left > -10000 && r.Top > -10000; }
    }
    public void Dispose() { DestroyHandle(); GlobalDeleteAtom(atom); }
}
public static class SupervisorStopFixture {
    [STAThread] public static int Main(string[] args) {
        if (args[0] == "--bystander") { Thread.Sleep(60000); return 0; }
        if (args[0] == "--witness") {
            using (var window = new StopFixtureWindow()) {
                File.WriteAllText("witness-ready", "ready");
                while (!File.Exists("witness-stop")) {
                    Application.DoEvents();
                    if (window.Restored) File.WriteAllText("witness-restored", "restored");
                    Thread.Sleep(25);
                }
            }
            return 0;
        }
        string prefix = Path.GetDirectoryName(System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName);
        string mode = File.ReadAllText(Path.Combine(prefix, "mode.txt"));
        if (args[0] == "--child") {
            File.AppendAllText(Path.Combine(prefix, "child-starts.txt"), "start\n");
            if (mode == "crash") return 7;
            while (true) {
                if (mode == "normal" && File.Exists(Path.Combine(prefix, "quit-called.txt"))) {
                    Thread.Sleep(700);
                    File.WriteAllText(Path.Combine(prefix, "normal-exit.txt"), "clean");
                    return 0;
                }
                Thread.Sleep(25);
            }
        }
        if (args[args.Length - 1] != "quit") return 9;
        File.WriteAllText(Path.Combine(prefix, "quit-called.txt"), "accepted");
        return mode == "ipc-failure" ? 3 : 0;
    }
}
'@
    foreach ($mode in @('hung', 'normal', 'ipc-failure', 'crash')) {
        $case = Join-Path $root $mode
        $prefix = Join-Path $case 'prefix'
        $profile = Join-Path $case 'profile'
        $state = Join-Path $profile 'runtime\supervisor-fixture'
        [IO.Directory]::CreateDirectory((Join-Path $prefix 'shell')) | Out-Null
        [IO.Directory]::CreateDirectory($state) | Out-Null
        Copy-Item -LiteralPath $fake -Destination (Join-Path $prefix 'qs.exe')
        [IO.File]::WriteAllText((Join-Path $prefix 'mode.txt'), $mode)
        # A disposable recovery helper proves lookup follows the executable,
        # not cwd. It does not load the real banner or desktop implementation.
        @'
param($StateDirectory, $Command)
[IO.File]::WriteAllText((Join-Path $StateDirectory 'banner-recovered.txt'), [Environment]::CurrentDirectory)
'@ | Set-Content -LiteralPath (Join-Path $prefix 'Banner-Suppression.ps1') -Encoding UTF8
        '{}' | Set-Content -LiteralPath (Join-Path $state 'banner-suppression.json') -Encoding UTF8
        @{ product = 'caelestia-windows'; version = 1; prefix = $prefix; profile = $profile } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $prefix 'install.json') -Encoding UTF8
        $bystander = Start-FixtureProcess $fake '--bystander' $case (Join-Path $case 'bystander')
        $witness = Start-FixtureProcess $fake '--witness' $case (Join-Path $case 'witness')
        Wait-Until { Test-Path -LiteralPath (Join-Path $case 'witness-ready') } 'Hidden restore witness did not start.'
        $spec = Join-Path $state 'launch.json'
        @{
            Executable = (Join-Path $prefix 'qs.exe'); Arguments = '--child'; WorkingDirectory = $case
            StateDirectory = $state; Environment = @{ CAELESTIA_STATE_DIR = $state }; TestWindowOwners = @($witness.Id)
            StdoutPath = (Join-Path $state 'shell.out'); StderrPath = (Join-Path $state 'shell.err')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $spec -Encoding UTF8
        $statusPath = Join-Path $state 'watchdog.json'
        $watchdog = Start-FixtureProcess $powershell `
            ('-NoProfile -Sta -File "' + $scripts + '\Watch-DesktopShell.ps1" -LaunchSpec "' + $spec + '"') `
            $case (Join-Path $case 'watchdog')
        $watchdogs.Add($watchdog)
        if ($mode -eq 'crash') {
            Assert ($watchdog.WaitForExit(15000)) 'Unrequested crash recovery did not finish.'
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            Assert ($status.phase -eq 'crash-give-up' -and $status.quickCrashes -eq 3 -and $watchdog.ExitCode -eq 7) 'Crash restart policy changed.'
            Assert (@(Get-Content -LiteralPath (Join-Path $prefix 'child-starts.txt')).Count -eq 3) 'Crash path did not restart its child twice.'
            Assert (-not $status.forcedChildTermination) 'An unrequested exit was force-terminated.'
        } else {
            Wait-Until {
                try { (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).phase -eq 'running' } catch { $false }
            } 'Supervisor did not launch its fake child.'
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $owned = [Diagnostics.Process]::GetProcessById($status.shellPid)
            $null = $owned.Handle
            $children.Add($owned)
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $quit = Start-FixtureProcess $powershell `
                ('-NoProfile -File "' + $scripts + '\Start-Caelestia.ps1" -Prefix "' + $prefix + '" -Command Quit') `
                $case (Join-Path $case 'quit')
            Assert ($quit.WaitForExit(20000)) 'Quit did not finish within the isolated stop bound.'
            Assert ($quit.ExitCode -eq 0) ("Quit failed: " + (Get-Content -LiteralPath (Join-Path $case 'quit.err') -Raw))
            Assert ($watchdog.WaitForExit(1000) -and $watchdog.ExitCode -eq 0) 'Supervisor did not exit successfully after Quit.'
            Assert ($owned.HasExited) 'The owned child survived Quit.'
            Assert ($clock.ElapsedMilliseconds -lt $grace + 12000) 'Stop exceeded grace plus test startup/cleanup allowance.'
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            Assert ($status.phase -in @('recovered', 'clean-exit')) 'Quit skipped the normal restore/exit path.'
            Assert (Test-Path -LiteralPath (Join-Path $prefix 'quit-called.txt')) 'Quit did not attempt IPC.'
            $forceLog = Join-Path $state 'watchdog-error.log'
            if ($mode -eq 'normal') {
                Assert ($owned.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $prefix 'normal-exit.txt'))) 'Normal child did not exit on its own.'
                Assert (-not $status.forcedChildTermination -and -not (Test-Path -LiteralPath $forceLog)) 'Normal child was force-terminated.'
            } else {
                Assert ($owned.ExitCode -ne 0 -and $status.forcedChildTermination) 'Hung child was not force-terminated.'
                Assert ((Get-Content -LiteralPath $forceLog -Raw).Trim() -ceq 'forced child termination after requested stop grace expired') 'Forced termination diagnostic was missing or contained unexpected data.'
                Assert ($clock.ElapsedMilliseconds -ge $grace) 'Hung child was killed before its exit grace.'
            }
            Assert (@(Get-Content -LiteralPath (Join-Path $prefix 'child-starts.txt')).Count -eq 1) 'Intentional stop restarted the child.'
        }
        Wait-Until { Test-Path -LiteralPath (Join-Path $case 'witness-restored') } 'Supervisor did not restore its hidden parked-window fixture.'
        Assert (-not $bystander.HasExited -and -not $witness.HasExited) 'Supervisor terminated an unowned same-name process.'
        Assert (Test-Path -LiteralPath (Join-Path $state 'desktop-before.json')) 'Supervisor did not persist its restore snapshot.'
        Assert (Test-CaelestiaSamePath (Get-Content -LiteralPath (Join-Path $state 'banner-recovered.txt') -Raw) $case) 'Banner recovery did not find the helper beside qs.exe or use the launch cwd.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'banner-recovery.log'))) 'Banner recovery failed with cwd outside the payload.'
        Assert (@(Get-CaelestiaSupervisors $profile).Count -eq 0) 'Exited supervisor still owns the disposable profile.'
        $mutex = [Threading.Mutex]::new($false, $mutexName)
        try {
            $acquired = $false
            try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { throw 'Supervisor abandoned session ownership instead of releasing it.' }
            Assert $acquired 'Supervisor did not release isolated session ownership.'
            $mutex.ReleaseMutex()
        } finally { $mutex.Dispose() }
        [IO.File]::WriteAllText((Join-Path $case 'witness-stop'), 'stop')
        Assert ($witness.WaitForExit(2000)) 'Restore witness did not finish.'
        $bystander.Kill()
        $null = $bystander.WaitForExit(2000)
        Write-Output "PASS supervisor $mode`: owned-child shutdown, restore, unrelated-process safety and session release."
    }
} finally {
    # On an assertion failure let the isolated owner reap its child too, even
    # if the failure happened before the test captured that child's handle.
    try {
        $recovery = [Threading.EventWaitHandle]::OpenExisting($mutexName + '-Recovery')
        try { $null = $recovery.Set() } finally { $recovery.Dispose() }
    } catch [Threading.WaitHandleCannotBeOpenedException] { }
    foreach ($watchdog in $watchdogs) {
        if (-not $watchdog.HasExited) { $null = $watchdog.WaitForExit(10000) }
    }
    # Every handle here belongs to a process this fixture started or the
    # supervisor's recorded child. Never discover or terminate by process name.
    foreach ($process in $children) {
        try { if (-not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(2000) } } finally { $process.Dispose() }
    }
    $safeRoot = Resolve-CaelestiaDirectory $root
    Assert ((Split-Path -Parent $safeRoot) -eq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and
        (Split-Path -Leaf $safeRoot) -like 'caelestia-supervisor-stop-*') 'Unsafe supervisor fixture cleanup path.'
    Assert-CaelestiaNoReparsePoints $safeRoot
    Remove-Item -LiteralPath $safeRoot -Recurse -Force
}
