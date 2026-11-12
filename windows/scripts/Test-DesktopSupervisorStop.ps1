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
    Assert ([regex]::Matches($Text, [regex]::Escape($Old)).Count -eq 1) ("Fixture injection boundary changed; refusing to run: " + $Old)
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
    # Disposable copies isolate synchronization, Explorer identities and native
    # restoration. Launcher IPC, Tick/Dispose and process discovery stay real.
    # Fail closed before executing a copy if any injection no longer matches.
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'DesktopTakeover.cs'))
    $source = Replace-Exactly $source `
        'return @"Local\CaelestiaDesktopTakeover-" + Process.GetCurrentProcess().SessionId;' `
        ('return @"' + $mutexName + '";')
    # Accept only qs.exe inside this disposable root, never the live shell
    # which also owns a Shell_TrayWnd and has the same process name.
    $source = Replace-Exactly $source `
        'return String.Equals(process.ProcessName, "explorer", StringComparison.OrdinalIgnoreCase);' `
        ('return String.Equals(process.ProcessName, "qs", StringComparison.OrdinalIgnoreCase) && process.MainModule.FileName.StartsWith(@"' + $root + '\", StringComparison.OrdinalIgnoreCase);')
    $source = Replace-Exactly $source `
        '(name == "Shell_TrayWnd" || name == "Shell_SecondaryTrayWnd");' `
        'Explorer(owner);'
    # Keep the production cleanup order, replacing only the desktop mutation.
    # The real owner-filtered parked-window rescue still follows this marker.
    $source = Replace-Exactly $source `
        'if (!isolatedTest) Native.RestoreOwned(saved, ownedPid, launch.RestoreWorkAreas, hide || adoptedUncleanBaseline);' `
        'File.AppendAllText(Path.Combine(launch.StateDirectory, "restore-order.txt"), "desktop\n");'
    # A crash that restarts releases only the dead shell's AppBars: no full
    # desktop restore and no parked-window rescue before the new shell.
    $source = Replace-Exactly $source `
        'else if (!isolatedTest) Native.RestoreOwned(saved, ownedPid, launch.RestoreWorkAreas, delay != 0 && hide);' `
        'else File.AppendAllText(Path.Combine(launch.StateDirectory, "restore-order.txt"), "appbars\n");'
    $source = Replace-Exactly $source `
        'finally { Native.RescueParkedWindows(tilerMutex, rescueFilter); }' `
        'finally { Native.RescueParkedWindows(tilerMutex, rescueFilter); File.AppendAllText(Path.Combine(launch.StateDirectory, "restore-order.txt"), "rescue\n"); }'
    # Exercise a real cross-process blocked call through the production bound.
    # The HWND comes only from this test's hidden fake, never window discovery.
    $source = Replace-Exactly $source 'public sealed class Supervisor : NativeWindow, IDisposable {' @'
public static class HungExplorerFixture {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
    static readonly BoundedExplorerCall call = new BoundedExplorerCall();
    public static void Reconcile(string directory) {
        string path = Path.Combine(directory, "fake-window.txt");
        if (!File.Exists(path)) return;
        IntPtr window = new IntPtr(Int64.Parse(File.ReadAllText(path)));
        uint owner;
        GetWindowThreadProcessId(window, out owner);
        var region = Native.CaptureRegion(new Bar { Handle = window.ToInt64(), Owner = owner });
        if (region != null) Native.ApplyEmptyRegion(region);
        IntPtr result;
        if (call.Try(delegate { return SendMessage(window, 0x8001, IntPtr.Zero, IntPtr.Zero); }, out result)
            && result.ToInt64() == 42) File.WriteAllText(Path.Combine(directory, "fake-retried"), "ok");
        // Simulate an unforeseen synchronous call outside the new guard too.
        if (File.Exists(Path.Combine(directory, "block-supervisor")))
            SendMessage(window, 0x8001, IntPtr.Zero, IntPtr.Zero);
    }
}
public sealed class Supervisor : NativeWindow, IDisposable {
'@
    $source += @'

namespace Caelestia.Takeover {
    public static class TaskbarEventFixture {
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string name, string title);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
        public static void Verify(string directory, uint owner, uint decoyOwner) {
            var fake = new IntPtr(Int64.Parse(File.ReadAllText(Path.Combine(directory, "taskbar-ready"))));
            var decoy = new IntPtr(Int64.Parse(File.ReadAllText(Path.Combine(directory, "decoy-ready"))));
            uint fakePid, decoyPid;
            GetWindowThreadProcessId(fake, out fakePid);
            GetWindowThreadProcessId(decoy, out decoyPid);
            if (fakePid != owner || decoyPid != decoyOwner
                || !SetWindowPos(fake, decoy, 0, 0, 0, 0, 0x13))
                throw new Exception("Could not order the two verified fixture windows.");
            // Do not reorder any live windows. Among our two fixtures, require
            // the decoy before the accepted owner in the actual class lookup.
            uint firstOwner = 0;
            var candidate = IntPtr.Zero;
            while ((candidate = FindWindowEx(IntPtr.Zero, candidate, "Shell_TrayWnd", null)) != IntPtr.Zero) {
                uint pid; GetWindowThreadProcessId(candidate, out pid);
                if (pid == owner || pid == decoyOwner) { firstOwner = pid; break; }
            }
            if (firstOwner != decoyOwner) throw new Exception("Decoy did not precede the fake Explorer taskbar.");
            var real = Native.ExplorerTaskbar();
            uint actual;
            GetWindowThreadProcessId(real, out actual);
            if (actual != owner || Native.ExplorerTaskbarOwner() != owner)
                throw new Exception("Explorer lookup selected the decoy.");
            var actions = new List<TaskbarAction>();
            var policy = new TaskbarShowPolicy(Stopwatch.Frequency);
            var handler = new TaskbarShowHandler(policy, Native.EventTaskbar, Native.HideObserved, actions.Add);
            Native.WinEventCallback callback = delegate(IntPtr hook, uint type, IntPtr window, int obj, int child, uint thread, uint time) {
                handler.Handle(owner, window, obj, child, Stopwatch.GetTimestamp());
            };
            var binding = new TaskbarHookBinding(delegate(uint pid) { return Native.HookShows(pid, callback); }, Native.UnhookShows);
            using (binding) {
                binding.Refresh(owner, false);
                if (binding.Owner != owner) throw new Exception("Fake taskbar show hook failed.");
                // No timer or audit runs here. Both shows must reach the real
                // WinEvent callback and the production show-to-hide handler.
                for (int pass = 0; pass < 2; pass++) {
                    actions.Clear();
                    File.WriteAllText(Path.Combine(directory, "taskbar-show-" + pass), "show");
                    var clock = Stopwatch.StartNew();
                    while (!actions.Exists(a => a.Operation == "hide") && clock.ElapsedMilliseconds < 2000) {
                        Application.DoEvents(); Thread.Sleep(5);
                    }
                    var hidden = actions.Find(a => a.Operation == "hide");
                    if (hidden == null || hidden.Source != "event" || !hidden.ShowToHideMilliseconds.HasValue
                        || hidden.ShowToHideMilliseconds >= 2000)
                        throw new Exception("Taskbar re-show was not re-hidden by the event before the audit.");
                    while (Native.EventTaskbar(real, owner).Visible && clock.ElapsedMilliseconds < 2000) {
                        Application.DoEvents(); Thread.Sleep(5);
                    }
                    if (Native.EventTaskbar(real, owner).Visible) throw new Exception("Posted hide did not take effect.");
                }
            }
            GC.KeepAlive(callback);
            var bar = new Bar { Handle = real.ToInt64(), Owner = owner, Visible = true };
            policy.Reset();
            policy.RememberHide(bar, 0);
            bool entered;
            for (int i = 1; i <= 12; i++) {
                long now = i * Stopwatch.Frequency / 100;
                if (policy.AllowImmediate(bar, now, out entered)) policy.RememberHide(bar, now);
            }
            if (!policy.PollingRequired(Stopwatch.Frequency) || policy.PollingRequired(6 * Stopwatch.Frequency))
                throw new Exception("Fight-loop polling fallback changed.");
        }
    }
}
'@
    $boundary = [regex]::Match($source, '(?m)^                if \(!child.HasExited\) \{\r?$').Value
    $source = Replace-Exactly $source ($boundary + "`n") ("                if (isolatedTest) HungExplorerFixture.Reconcile(launch.WorkingDirectory);`n" + $boundary + "`n")
    [IO.File]::WriteAllText((Join-Path $scripts 'DesktopTakeover.cs'), $source)
    $watch = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Watch-DesktopShell.ps1'))
    $watch = Replace-Exactly $watch `
        '[Caelestia.Takeover.Supervisor]::Run([IO.Path]::GetFullPath($LaunchSpec), $hideTaskbar, $restartOnCrash, ($suppression -ceq ''invisible''))' `
        ('[Caelestia.Takeover.Supervisor]::RunIsolatedTest([IO.Path]::GetFullPath($LaunchSpec), "' + $token + '")')
    [IO.File]::WriteAllText((Join-Path $scripts 'Watch-DesktopShell.ps1'), $watch)
    $restore = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Restore-Desktop.ps1'))
    $restore = Replace-Exactly $restore '[Caelestia.Takeover.Native]::Restore($snapshot, 0)' `
        '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "fixture-restored"), "restored")'
    $restore = Replace-Exactly $restore '[Caelestia.Takeover.Native]::Capture() | ConvertTo-Json -Depth 6' `
        'Write-Output "{}"'
    [IO.File]::WriteAllText((Join-Path $scripts 'Restore-Desktop.ps1'), $restore)
    Add-Type -Path (Join-Path $scripts 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    # The supervisor owns both switches. The shell filters Explorer's taskbar
    # shortcuts only while this supervisor hides the taskbar, and only the
    # shell's own crash relaunch is off. An inherited value never applies.
    foreach ($hide in @($false, $true)) {
        $variables = New-Object Collections.Specialized.StringDictionary
        $variables['QS_WINDOWS_TASKBAR_SHORTCUT_FILTER'] = '1'
        $variables['QS_DISABLE_CRASH_HANDLER'] = '1'
        [Caelestia.Takeover.LaunchEnvironment]::Apply($variables, $hide)
        Assert ($variables['QS_DISABLE_CRASH_RELAUNCH'] -eq '1') 'Supervised launch no longer disables the shell crash relaunch.'
        Assert ($null -eq $variables['QS_DISABLE_CRASH_HANDLER']) 'Supervised launch still disables the whole crash handler.'
        Assert ((($variables['QS_WINDOWS_TASKBAR_SHORTCUT_FILTER'] -eq '1')) -eq $hide) 'Taskbar shortcut filter does not follow the hidden taskbar.'
    }
    Write-Output 'PASS launch environment: taskbar shortcut filter only while the taskbar is hidden; only the shell crash relaunch is disabled.'
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
public sealed class HungExplorerWindow : NativeWindow, IDisposable {
    public HungExplorerWindow() {
        CreateHandle(new CreateParams { Caption = "hidden fake Explorer", Style = unchecked((int)0x80000000), ExStyle = 0x08000080 });
        File.WriteAllText("fake-window.txt", Handle.ToInt64().ToString());
    }
    protected override void WndProc(ref Message message) {
        if (message.Msg == 0x8001) {
            File.WriteAllText("fake-entered", "blocked");
            while (!File.Exists("fake-release")) Thread.Sleep(25);
            message.Result = new IntPtr(42);
            return;
        }
        base.WndProc(ref message);
    }
    public void Dispose() { DestroyHandle(); }
}
public sealed class FakeTaskbarWindow : IDisposable {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClass(ref WindowClass value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr DefWindowProc(IntPtr window, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(uint extended, string name, string title, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
    delegate IntPtr WindowProc(IntPtr window, uint message, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WindowClass {
        public uint Style; public WindowProc Proc; public int ClassExtra, WindowExtra;
        public IntPtr Instance, Icon, Cursor, Background;
        public string Menu, Name;
    }
    readonly WindowProc proc = DefWindowProc;
    readonly IntPtr window;
    public FakeTaskbarWindow(string ready) {
        var wc = new WindowClass { Proc = proc, Name = "Shell_TrayWnd", Instance = GetModuleHandle(null) };
        if (RegisterClass(ref wc) == 0) throw new Exception("Fake taskbar class registration failed.");
        window = CreateWindowEx(0x08000080, "Shell_TrayWnd", ready, 0x80000000,
            -30000, -30000, 100, 20, IntPtr.Zero, IntPtr.Zero, wc.Instance, IntPtr.Zero);
        if (window == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        File.WriteAllText(ready, window.ToInt64().ToString());
    }
    public void Show() { ShowWindowAsync(window, 8); }
    public void Dispose() { DestroyWindow(window); GC.KeepAlive(proc); }
}
public static class SupervisorStopFixture {
    [STAThread] public static int Main(string[] args) {
        if (args[0] == "--bystander") { Thread.Sleep(60000); return 0; }
        if (args[0] == "--taskbar" || args[0] == "--decoy") {
            using (var window = new FakeTaskbarWindow(args[0].Substring(2) + "-ready")) {
                int pass = 0;
                while (!File.Exists("taskbars-stop")) {
                    if (args[0] == "--taskbar" && File.Exists("taskbar-show-" + pass)) { window.Show(); pass++; }
                    Application.DoEvents(); Thread.Sleep(5);
                }
            }
            return 0;
        }
        if (args[0] == "--explorer") {
            using (var window = new HungExplorerWindow()) {
                while (!File.Exists("fake-stop")) { Application.DoEvents(); Thread.Sleep(25); }
            }
            return 0;
        }
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
            if (mode == "clean") return 0;
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
    $taskbars = Join-Path $root 'taskbars'
    [IO.Directory]::CreateDirectory($taskbars) | Out-Null
    $decoyExe = Join-Path $root 'decoy.exe'
    Copy-Item -LiteralPath $fake -Destination $decoyExe
    $decoy = Start-FixtureProcess $decoyExe '--decoy' $taskbars (Join-Path $taskbars 'decoy')
    Wait-Until { Test-Path -LiteralPath (Join-Path $taskbars 'decoy-ready') } 'Decoy taskbar did not start.'
    $taskbar = Start-FixtureProcess $fake '--taskbar' $taskbars (Join-Path $taskbars 'taskbar')
    Wait-Until {
        if ($taskbar.HasExited) { throw ('Fake taskbar exited: ' + [IO.File]::ReadAllText((Join-Path $taskbars 'taskbar.err'))) }
        Test-Path -LiteralPath (Join-Path $taskbars 'taskbar-ready')
    } 'Fake taskbar did not start.'
    [Caelestia.Takeover.TaskbarEventFixture]::Verify($taskbars, $taskbar.Id, $decoy.Id)
    [IO.File]::WriteAllText((Join-Path $taskbars 'taskbars-stop'), 'stop')
    Assert ($taskbar.WaitForExit(2000) -and $decoy.WaitForExit(2000)) 'Fake taskbars did not stop.'
    Write-Output 'PASS taskbar events: owner-checked lookup skips a first-in-order decoy; real show events re-hide twice without an audit; fight-loop fallback remains bounded.'
    foreach ($mode in @('hung', 'normal', 'ipc-failure', 'clean', 'crash', 'explorer-hung', 'explorer-retry', 'stuck-quit', 'stuck-start')) {
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
$order = Join-Path $StateDirectory 'restore-order.txt'
if (Test-Path -LiteralPath $order) {
    $lines = @(Get-Content -LiteralPath $order)
    $restart = $lines.Count -ge 1 -and $lines[-1] -eq 'appbars'
    $terminal = $lines.Count -ge 2 -and $lines[-2] -eq 'desktop' -and $lines[-1] -eq 'rescue'
    if (-not $restart -and -not $terminal) {
        throw 'Banner work started before desktop and parked-window restoration.'
    }
    Add-Content -LiteralPath $order -Value 'banner'
    # Deliberately slow work begins only after the desktop has returned.
    Start-Sleep -Milliseconds 300
} elseif ((Get-Content -LiteralPath (Join-Path $StateDirectory 'watchdog.json') -Raw | ConvertFrom-Json).phase -eq 'restoring') {
    throw 'Banner work started without desktop restoration.'
}
[IO.File]::WriteAllText((Join-Path $StateDirectory 'banner-recovered.txt'), [Environment]::CurrentDirectory)
'@ | Set-Content -LiteralPath (Join-Path $prefix 'Banner-Suppression.ps1') -Encoding UTF8
        '{}' | Set-Content -LiteralPath (Join-Path $state 'banner-suppression.json') -Encoding UTF8
        @{ product = 'caelestia-windows'; version = 1; prefix = $prefix; profile = $profile } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $prefix 'install.json') -Encoding UTF8
        $bystander = Start-FixtureProcess $fake '--bystander' $case (Join-Path $case 'bystander')
        $witness = Start-FixtureProcess $fake '--witness' $case (Join-Path $case 'witness')
        Wait-Until { Test-Path -LiteralPath (Join-Path $case 'witness-ready') } 'Hidden restore witness did not start.'
        $explorer = $null
        if ($mode -like 'explorer-*' -or $mode -like 'stuck-*') {
            $explorer = Start-FixtureProcess $fake '--explorer' $case (Join-Path $case 'fake-explorer')
            Wait-Until { Test-Path -LiteralPath (Join-Path $case 'fake-window.txt') } 'Fake Explorer did not create its hidden window.'
        }
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
        if ($mode -eq 'clean') {
            Assert ($watchdog.WaitForExit(15000) -and $watchdog.ExitCode -eq 0) 'Unrequested clean exit did not finish.'
            $status = Read-CaelestiaSupervisorStatus $statusPath
            Assert ($status.phase -eq 'clean-exit' -and $status.quickCrashes -eq 0) 'Clean exit changed the restart policy.'
            Assert (@(Get-Content -LiteralPath (Join-Path $prefix 'child-starts.txt')).Count -eq 1) 'Clean exit restarted the child.'
        } elseif ($mode -eq 'crash') {
            Assert ($watchdog.WaitForExit(15000)) 'Unrequested crash recovery did not finish.'
            $status = Read-CaelestiaSupervisorStatus $statusPath
            Assert ($status.phase -eq 'crash-give-up' -and $status.quickCrashes -eq 3 -and $watchdog.ExitCode -eq 7) 'Crash restart policy changed.'
            Assert (@(Get-Content -LiteralPath (Join-Path $prefix 'child-starts.txt')).Count -eq 3) 'Crash path did not restart its child twice.'
            Assert (-not $status.forcedChildTermination) 'An unrequested exit was force-terminated.'
        } else {
            Wait-Until {
                try { (Read-CaelestiaSupervisorStatus $statusPath).phase -eq 'running' } catch { $false }
            } 'Supervisor did not launch its fake child.'
            $status = Read-CaelestiaSupervisorStatus $statusPath
            $owned = [Diagnostics.Process]::GetProcessById($status.shellPid)
            $null = $owned.Handle
            $children.Add($owned)
            if ($explorer) {
                Wait-Until { Test-Path -LiteralPath (Join-Path $case 'fake-entered') } 'Supervisor did not call the fake window.'
                $heartbeat = $status.utc
                Wait-Until {
                    (Read-CaelestiaSupervisorStatus $statusPath).utc -ne $heartbeat
                } 'Fake Explorer blocked the supervisor heartbeat.'
                if ($mode -eq 'explorer-retry') {
                    $restoreAttempt = Start-FixtureProcess $powershell `
                        ('-NoProfile -File "' + $scripts + '\Restore-Desktop.ps1" -InactiveOnly') `
                        $case (Join-Path $case 'inactive-restore')
                    Assert ($restoreAttempt.WaitForExit(10000) -and $restoreAttempt.ExitCode -ne 0) 'Inactive recovery did not refuse a live session owner.'
                    Assert ((Get-Content -LiteralPath (Join-Path $case 'inactive-restore.err') -Raw) -match 'Another desktop supervisor owns this session') 'Inactive recovery reached desktop operations or signaled the live supervisor.'
                    Assert (-not $watchdog.HasExited) 'Inactive recovery stopped the live supervisor.'
                    [IO.File]::WriteAllText((Join-Path $case 'fake-release'), 'release')
                    Wait-Until { Test-Path -LiteralPath (Join-Path $case 'fake-retried') } 'Explorer work did not retry after responsiveness returned.'
                }
                if ($mode -eq 'explorer-hung') {
                    Repair-CaelestiaStaleSupervisors $profile
                    Assert (-not $watchdog.HasExited -and -not $owned.HasExited) 'Start recovery stopped a supervisor with a healthy heartbeat.'
                    $owned.Kill()
                    Assert ($owned.WaitForExit(2000)) 'Fake child did not stop.'
                    Wait-Until {
                        $s = Read-CaelestiaSupervisorStatus $statusPath
                        $s.phase -eq 'running' -and $s.shellPid -ne $owned.Id
                    } 'Blocked fake Explorer prevented child restart.'
                    $owned = [Diagnostics.Process]::GetProcessById((Read-CaelestiaSupervisorStatus $statusPath).shellPid)
                    $null = $owned.Handle
                    $children.Add($owned)
                }
                if ($mode -like 'stuck-*') {
                    [IO.File]::WriteAllText((Join-Path $case 'block-supervisor'), 'block')
                    Start-Sleep -Milliseconds 600
                    $supervisor = @(Get-CaelestiaSupervisors $profile)[0]
                    # Verify ownership rejection before exercising forced stop.
                    $wrong = [pscustomobject]@{ Process = $bystander; StatusPath = $statusPath }
                    $rejected = $false
                    try { Stop-CaelestiaSupervisor $wrong 0 } catch { $rejected = $true }
                    Assert ($rejected -and -not $bystander.HasExited) 'Forced recovery accepted an unrelated process.'
                    $wrongProfile = [pscustomobject]@{
                        Process = $watchdog
                        StatusPath = (Join-Path $case 'other-profile\runtime\supervisor-fixture\watchdog.json')
                    }
                    $rejected = $false
                    try { Stop-CaelestiaSupervisor $wrongProfile 0 } catch { $rejected = $true }
                    Assert ($rejected -and -not $watchdog.HasExited) 'Forced recovery accepted another profile.'
                    $wrongSession = [pscustomobject]@{
                        Process = [pscustomobject]@{ Id = $watchdog.Id; HasExited = $false; SessionId = ([Diagnostics.Process]::GetCurrentProcess().SessionId + 1) }
                        StatusPath = $statusPath
                    }
                    $rejected = $false
                    try { Stop-CaelestiaSupervisor $wrongSession 0 } catch { $rejected = $true }
                    Assert ($rejected -and -not $watchdog.HasExited) 'Forced recovery accepted another session.'
                    & {
                        function Invoke-CimMethod { return [pscustomobject]@{ ReturnValue = 0; Sid = 'S-1-0-0' } }
                        $rejected = $false
                        try { Stop-CaelestiaSupervisor $supervisor 0 } catch { $rejected = $true }
                        Assert ($rejected -and -not $watchdog.HasExited) 'Forced recovery accepted another user SID.'
                    }
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    if ($mode -eq 'stuck-start') {
                        # The Start entrypoint uses this exact profile-scoped helper.
                        # Shorten only the recovery wait in the disposable copy.
                        $definition = ${function:Stop-CaelestiaSupervisor}.ToString().Replace('[int]$RecoveryTimeoutMs = 60000', '[int]$RecoveryTimeoutMs = 1000')
                        Set-Item Function:Stop-CaelestiaSupervisor ([scriptblock]::Create($definition))
                        Repair-CaelestiaStaleSupervisors $profile
                    } else {
                        $commonPath = Join-Path $scripts 'Caelestia-InstallCommon.ps1'
                        $common = Replace-Exactly ([IO.File]::ReadAllText($commonPath)) `
                            '[int]$RecoveryTimeoutMs = 60000' '[int]$RecoveryTimeoutMs = 1000'
                        [IO.File]::WriteAllText($commonPath, $common)
                        $quit = Start-FixtureProcess $powershell `
                            ('-NoProfile -File "' + $scripts + '\Start-Caelestia.ps1" -Prefix "' + $prefix + '" -Command Quit') `
                            $case (Join-Path $case 'stuck-quit')
                        Assert ($quit.WaitForExit(10000) -and $quit.ExitCode -eq 0) ("Stuck Quit failed: " + (Get-Content -LiteralPath (Join-Path $case 'stuck-quit.err') -Raw))
                        Assert (Test-Path -LiteralPath (Join-Path $scripts 'fixture-restored')) 'Forced Quit skipped emergency snapshot restoration.'
                    }
                    Assert ($clock.ElapsedMilliseconds -lt 12000 -and $watchdog.HasExited -and $owned.HasExited) 'Stuck supervisor recovery exceeded its bound or left its child.'
                    Assert (-not $bystander.HasExited -and -not $witness.HasExited) 'Forced recovery killed a bystander.'
                    Assert (@(Get-CaelestiaSupervisors $profile).Count -eq 0) 'Forced recovery left profile ownership.'
                    [IO.File]::WriteAllText((Join-Path $case 'fake-release'), 'release')
                    Remove-Item -LiteralPath (Join-Path $case 'block-supervisor')
                    $replacement = Start-FixtureProcess $powershell `
                        ('-NoProfile -Sta -File "' + $scripts + '\Watch-DesktopShell.ps1" -LaunchSpec "' + $spec + '"') `
                        $case (Join-Path $case 'replacement')
                    $watchdogs.Add($replacement)
                    Wait-Until {
                        $s = Read-CaelestiaSupervisorStatus $statusPath
                        $s.phase -eq 'running' -and $s.watchdogPid -eq $replacement.Id
                    } 'A fresh supervisor could not acquire ownership after forced recovery.'
                    $replacementChild = [Diagnostics.Process]::GetProcessById((Read-CaelestiaSupervisorStatus $statusPath).shellPid)
                    $null = $replacementChild.Handle
                    $children.Add($replacementChild)
                    [Caelestia.Takeover.Supervisor]::RecoverActive()
                    Assert ($replacement.WaitForExit(2000) -and $replacement.ExitCode -eq 0 -and $replacementChild.HasExited) 'Replacement supervisor did not shut down.'
                    Wait-Until { Test-Path -LiteralPath (Join-Path $case 'witness-restored') } 'Replacement supervisor did not restore the journal witness.'
                    [IO.File]::WriteAllText((Join-Path $case 'fake-stop'), 'stop')
                    Assert ($explorer.WaitForExit(2000)) 'Fake Explorer did not stop.'
                    [IO.File]::WriteAllText((Join-Path $case 'witness-stop'), 'stop')
                    Assert ($witness.WaitForExit(2000)) 'Witness did not stop.'
                    $bystander.Kill()
                    Write-Output "PASS supervisor $mode`: bounded profile recovery, owned-child stop and bystander safety."
                    continue
                }
            }
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $quit = Start-FixtureProcess $powershell `
                ('-NoProfile -File "' + $scripts + '\Start-Caelestia.ps1" -Prefix "' + $prefix + '" -Command Quit') `
                $case (Join-Path $case 'quit')
            Assert ($quit.WaitForExit(20000)) 'Quit did not finish within the isolated stop bound.'
            Assert ($quit.ExitCode -eq 0) ("Quit failed: " + (Get-Content -LiteralPath (Join-Path $case 'quit.err') -Raw))
            Assert ($watchdog.WaitForExit(1000) -and $watchdog.ExitCode -eq 0) ("Supervisor did not exit successfully after Quit: " + $watchdog.ExitCode + ' ' + (Get-Content -LiteralPath (Join-Path $case 'watchdog.err') -Raw))
            Assert ($owned.HasExited) 'The owned child survived Quit.'
            Assert ($clock.ElapsedMilliseconds -lt $grace + 12000) 'Stop exceeded grace plus test startup/cleanup allowance.'
            $status = Read-CaelestiaSupervisorStatus $statusPath
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
            $expectedStarts = if ($mode -eq 'explorer-hung') { 2 } else { 1 }
            Assert (@(Get-Content -LiteralPath (Join-Path $prefix 'child-starts.txt')).Count -eq $expectedStarts) 'Intentional stop restarted the child.'
        }
        Wait-Until { Test-Path -LiteralPath (Join-Path $case 'witness-restored') } 'Supervisor did not restore its hidden parked-window fixture.'
        Assert (-not $bystander.HasExited -and -not $witness.HasExited) 'Supervisor terminated an unowned same-name process.'
        Assert (Test-Path -LiteralPath (Join-Path $state 'desktop-before.json')) 'Supervisor did not persist its restore snapshot.'
        Assert (Test-CaelestiaSamePath (Get-Content -LiteralPath (Join-Path $state 'banner-recovered.txt') -Raw) $case) 'Banner recovery did not find the helper beside qs.exe or use the launch cwd.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'banner-recovery.log'))) 'Banner recovery failed with cwd outside the payload.'
        $order = @(Get-Content -LiteralPath (Join-Path $state 'restore-order.txt'))
        Assert (($order -join ',') -match '^(appbars,banner,)*desktop,rescue,banner$') 'Desktop, parked-window and banner recovery order changed.'
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
        if ($explorer) {
            [IO.File]::WriteAllText((Join-Path $case 'fake-release'), 'release')
            [IO.File]::WriteAllText((Join-Path $case 'fake-stop'), 'stop')
            Assert ($explorer.WaitForExit(2000)) 'Fake Explorer did not stop.'
        }
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
