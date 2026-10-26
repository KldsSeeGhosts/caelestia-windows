// Windows-only supervisor. Compiled in the watchdog process, never in qs.exe.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Caelestia.Takeover {
    public sealed class Launch {
        public string Executable, Arguments, WorkingDirectory, ConfigPath, StateDirectory;
        public string StdoutPath, StderrPath;
        public bool RestoreWorkAreas;
        public Dictionary<string, string> Environment = new Dictionary<string, string>();
    }
    public struct Rect {
        public int Left, Top, Right, Bottom;
    }
    public sealed class Display {
        public string Device;
        public Rect Bounds, Work;
    }
    public sealed class Bar {
        public long Handle;
        public uint Owner;
        public string Device;
        public bool Visible;
        public Rect Bounds;
    }
    public sealed class Snapshot {
        public ulong TaskbarFlags;
        public List<Display> Displays = new List<Display>();
        public List<Bar> Bars = new List<Bar>();
    }
    public sealed class TaskbarAction {
        public string Operation, Device, Utc;
        public long Handle;
        public uint Owner;
        public bool VisibleBefore, RequestedVisible, VisibleAfter;
    }
    public static class Native {
        // Per-process observer for the supervisor's own native calls. Another
        // shell can immediately change global state after these observations.
        public static Action<TaskbarAction> RecordAction;
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct MonitorInfo {
            public int Size;
            public Rect Monitor, Work;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct AppBarData {
            public uint Size;
            public IntPtr Window;
            public uint Callback, Edge;
            public Rect Bounds;
            public IntPtr Parameter;
        }
        delegate bool WindowCallback(IntPtr window, IntPtr data);
        delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string name, string title);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint parameter, ref Rect rect, uint flags);
        [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint message, ref AppBarData data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string message);
        [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
        [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr window, IntPtr update, IntPtr region, uint flags);

        static AppBarData AppBar(IntPtr window) {
            return new AppBarData { Size = (uint)Marshal.SizeOf(typeof(AppBarData)), Window = window };
        }
        public static List<Bar> Taskbars() {
            var bars = new List<Bar>();
            EnumWindows(delegate(IntPtr window, IntPtr data) {
                var name = new StringBuilder(128);
                GetClassName(window, name, name.Capacity);
                if (name.ToString() != "Shell_TrayWnd" && name.ToString() != "Shell_SecondaryTrayWnd") return true;
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
                GetMonitorInfo(MonitorFromWindow(window, 2), ref info);
                Rect rect;
                GetWindowRect(window, out rect);
                bars.Add(new Bar { Handle = window.ToInt64(), Owner = owner, Device = info.Device,
                    Visible = IsWindowVisible(window), Bounds = rect });
                return true;
            }, IntPtr.Zero);
            return bars;
        }
        public static Snapshot Capture() {
            var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
            try {
                var result = new Snapshot();
                var data = AppBar(IntPtr.Zero);
                result.TaskbarFlags = SHAppBarMessage(4, ref data).ToUInt64();
                result.Bars = Taskbars();
                EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
                    delegate(IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr unused) {
                        var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
                        if (GetMonitorInfo(monitor, ref info))
                            result.Displays.Add(new Display { Device = info.Device, Bounds = info.Monitor, Work = info.Work });
                        return true;
                    }, IntPtr.Zero);
                return result;
            } finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
        }
        static void Visibility(Bar bar, bool visible, string operation) {
            var window = new IntPtr(bar.Handle);
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (!IsWindow(window) || owner != bar.Owner) return;
            ShowWindow(window, visible ? 8 : 0); // SW_SHOWNA avoids taking focus
            if (RecordAction != null) RecordAction(new TaskbarAction {
                Operation = operation, Handle = bar.Handle, Owner = bar.Owner, Device = bar.Device,
                VisibleBefore = bar.Visible, RequestedVisible = visible, VisibleAfter = IsWindowVisible(window),
                Utc = DateTime.UtcNow.ToString("o")
            });
        }
        public static void Hide(bool recordUnchanged) {
            foreach (var bar in Taskbars())
                if (bar.Visible || recordUnchanged) Visibility(bar, false, "hide");
        }
        // The backend records AppBar HWND -> PID here. Never remove a live
        // registration or a registration belonging to a different live shell.
        public static int RemoveStaleAppBars(int owner) {
            int removed = 0;
            using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Quickshell\AppBars", true)) {
                if (key == null) return 0;
                foreach (var name in key.GetValueNames()) {
                    long handle;
                    if (!Int64.TryParse(name, System.Globalization.NumberStyles.HexNumber, null, out handle)) continue;
                    if (owner != 0 && Convert.ToInt64(key.GetValue(name)) != owner) continue;
                    var window = new IntPtr(handle);
                    if (IsWindow(window)) continue;
                    var data = AppBar(window);
                    SHAppBarMessage(1, ref data); // ABM_REMOVE, including destroyed HWNDs
                    key.DeleteValue(name, false);
                    removed++;
                }
            }
            return removed;
        }
        static bool Same(Rect a, Rect b) {
            return a.Left == b.Left && a.Top == b.Top && a.Right == b.Right && a.Bottom == b.Bottom;
        }
        public static void Restore(Snapshot saved, int owner) {
            RestoreDesktop(saved, owner, true, true);
        }
        public static void RestoreOwned(Snapshot saved, int owner, bool workAreas, bool taskbars) {
            RestoreDesktop(saved, owner, workAreas, taskbars);
        }
        static void RestoreDesktop(Snapshot saved, int owner, bool workAreas, bool taskbars) {
            var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
            try {
                int removed = owner >= 0 ? RemoveStaleAppBars(owner) : 0;
                if (taskbars) {
                    var data = AppBar(FindWindow("Shell_TrayWnd", null));
                    ulong currentFlags = SHAppBarMessage(4, ref data).ToUInt64();
                    // Emergency recovery deliberately makes the real taskbar
                    // accessible. Exact lifecycle restoration uses saved flags.
                    ulong targetFlags = saved == null ? currentFlags & ~1UL : saved.TaskbarFlags;
                    if (currentFlags != targetFlags) {
                        data.Parameter = new IntPtr((long)targetFlags);
                        SHAppBarMessage(10, ref data);
                    }
                    foreach (var bar in Taskbars()) {
                        Bar original = saved == null ? null : saved.Bars.Find(b => b.Device == bar.Device);
                        Visibility(bar, original == null || original.Visible, "restore");
                    }
                }
                var current = Capture();
                foreach (var display in current.Displays) {
                    if (!workAreas && removed == 0) continue;
                    var original = saved == null ? null : saved.Displays.Find(d => d.Device == display.Device && Same(d.Bounds, display.Bounds));
                    Rect work = original == null ? display.Bounds : original.Work;
                    if (original == null && (current.TaskbarFlags & 1) == 0) {
                        foreach (var bar in current.Bars) {
                            if (bar.Device != display.Device || !bar.Visible) continue;
                            var r = bar.Bounds;
                            // Only subtract a real edge-aligned taskbar. Full-width
                            // bars reserve top/bottom; full-height bars left/right.
                            if (r.Right - r.Left >= display.Bounds.Right - display.Bounds.Left) {
                                if (r.Top <= display.Bounds.Top) work.Top = Math.Max(work.Top, r.Bottom);
                                else work.Bottom = Math.Min(work.Bottom, r.Top);
                            } else if (r.Bottom - r.Top >= display.Bounds.Bottom - display.Bounds.Top) {
                                if (r.Left <= display.Bounds.Left) work.Left = Math.Max(work.Left, r.Right);
                                else work.Right = Math.Min(work.Right, r.Left);
                            }
                        }
                    }
                    if (!Same(work, display.Work) && !SystemParametersInfo(47, 0, ref work, 0))
                        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SPI_SETWORKAREA failed");
                }
                // qs-owned background children die with qs. Do not destroy
                // Explorer's WorkerW/Progman, which host other applications.
                RedrawWindow(GetDesktopWindow(), IntPtr.Zero, IntPtr.Zero, 0x181);
            } finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
        }
    }

    public sealed class Supervisor : NativeWindow, IDisposable {
        readonly Launch launch;
        readonly bool hide, restart;
        readonly Snapshot saved;
        readonly System.Threading.EventWaitHandle recovery;
        readonly Timer timer = new Timer();
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        readonly uint taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
        Process child;
        DateTime started, nextStart;
        int quickCrashes;
        int ownedPid = -1;
        bool done;
        public int ExitCode;

        public static string MutexName { get { return @"Local\CaelestiaDesktopTakeover-" + Process.GetCurrentProcess().SessionId; } }
        public static string EventName { get { return MutexName + "-Recovery"; } }
        public static void RecoverActive() {
            try { using (var handle = System.Threading.EventWaitHandle.OpenExisting(EventName)) handle.Set(); }
            catch (System.Threading.WaitHandleCannotBeOpenedException) {}
            // Wait for the owner to finish restoring before emergency fallback.
            using (var mutex = new System.Threading.Mutex(false, MutexName)) {
                bool acquired;
                try { acquired = mutex.WaitOne(10000); }
                catch (System.Threading.AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new InvalidOperationException("Supervisor has not stopped. Retry recovery after it exits.");
                mutex.ReleaseMutex();
            }
        }
        public static int Run(string specPath, bool hide, bool restart) {
            using (var mutex = new System.Threading.Mutex(false, MutexName)) {
                bool acquired;
                try { acquired = mutex.WaitOne(0); }
                catch (System.Threading.AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new InvalidOperationException("A desktop supervisor already owns this Windows session.");
                try {
                    var launch = new JavaScriptSerializer().Deserialize<Launch>(File.ReadAllText(specPath));
                    using (var supervisor = new Supervisor(launch, hide, restart)) {
                        Application.Run();
                        return supervisor.ExitCode;
                    }
                } finally { mutex.ReleaseMutex(); }
            }
        }
        Supervisor(Launch launch, bool hide, bool restart) {
            this.launch = launch; this.hide = hide; this.restart = restart;
            Directory.CreateDirectory(launch.StateDirectory);
            saved = Native.Capture();
            // Durable before the first native change, usable if this helper is killed.
            File.WriteAllText(Path.Combine(launch.StateDirectory, "desktop-before.json"), json.Serialize(saved));
            Native.RecordAction = delegate(TaskbarAction action) {
                try {
                    File.AppendAllText(Path.Combine(launch.StateDirectory, "taskbar-actions.jsonl"),
                        json.Serialize(action) + Environment.NewLine);
                } catch (IOException) {
                    // Logging must never prevent desktop restoration.
                } catch (UnauthorizedAccessException) {}
            };
            recovery = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.ManualReset, EventName);
            recovery.Reset();
            // A hidden top-level window receives Explorer's broadcast. A
            // message-only HWND would not receive TaskbarCreated.
            CreateHandle(new CreateParams { Caption = "Caelestia desktop watchdog", Style = unchecked((int)0x80000000) });
            timer.Interval = 250;
            timer.Tick += Tick;
            timer.Start();
            nextStart = DateTime.UtcNow;
        }
        protected override void WndProc(ref Message message) {
            if (message.Msg == taskbarCreated && child != null && !child.HasExited && hide) Native.Hide(true);
            base.WndProc(ref message);
        }
        void Status(string phase, int pid) {
            var path = Path.Combine(launch.StateDirectory, "watchdog.json");
            var text = json.Serialize(new { phase = phase, shellPid = pid, watchdogPid = Process.GetCurrentProcess().Id,
                quickCrashes = quickCrashes, hideTaskbar = hide, restartOnCrash = restart, exitCode = ExitCode,
                utc = DateTime.UtcNow.ToString("o") });
            File.WriteAllText(path + ".tmp", text);
            if (File.Exists(path)) File.Replace(path + ".tmp", path, null);
            else File.Move(path + ".tmp", path);
        }
        void Start() {
            var info = new ProcessStartInfo(launch.Executable, launch.Arguments) {
                WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true
            };
            foreach (var entry in launch.Environment) info.EnvironmentVariables[entry.Key] = entry.Value;
            // qs normally starts its own crash relauncher. The supervisor must
            // own the actual shell process and its bounded restart policy.
            info.EnvironmentVariables["QS_DISABLE_CRASH_HANDLER"] = "1";
            info.RedirectStandardOutput = !String.IsNullOrEmpty(launch.StdoutPath);
            info.RedirectStandardError = !String.IsNullOrEmpty(launch.StderrPath);
            var process = new Process { StartInfo = info };
            if (info.RedirectStandardOutput)
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) Append(launch.StdoutPath, e.Data); };
            if (info.RedirectStandardError)
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) Append(launch.StderrPath, e.Data); };
            process.Start();
            child = process;
            ownedPid = child.Id;
            if (info.RedirectStandardOutput) child.BeginOutputReadLine();
            if (info.RedirectStandardError) child.BeginErrorReadLine();
            started = DateTime.UtcNow;
            if (hide) Native.Hide(true);
            Status("running", child.Id);
        }
        static readonly object logLock = new object();
        static void Append(string path, string line) {
            lock (logLock) { File.AppendAllText(path, line + Environment.NewLine); }
        }
        void Tick(object sender, EventArgs args) {
            try {
                if (recovery.WaitOne(0)) {
                    if (child != null && !child.HasExited) { child.Kill(); child.WaitForExit(); }
                    Finish("recovered", 0);
                    return;
                }
                if (child == null) { if (DateTime.UtcNow >= nextStart) Start(); return; }
                if (!child.HasExited) { if (hide) Native.Hide(false); return; }
                child.WaitForExit(); // drain redirected log callbacks
                int code = child.ExitCode, pid = child.Id;
                child.Dispose(); child = null;
                if (code == 0) { Finish("clean-exit", 0); return; }
                quickCrashes = (DateTime.UtcNow - started).TotalSeconds < 30 ? quickCrashes + 1 : 0;
                if (!restart || quickCrashes >= 3) { Finish("crash-give-up", code); return; }
                Native.RestoreOwned(saved, pid, launch.RestoreWorkAreas, hide);
                nextStart = DateTime.UtcNow.AddSeconds(Math.Min(30, Math.Pow(2, Math.Max(1, quickCrashes))));
                Status("restart-backoff", 0);
            } catch (Exception error) {
                File.AppendAllText(Path.Combine(launch.StateDirectory, "watchdog-error.log"), error + Environment.NewLine);
                Finish("watchdog-error", 1);
            }
        }
        void Finish(string phase, int code) {
            ExitCode = code;
            Dispose();
            Status(phase, 0);
            Application.ExitThread();
        }
        public void Dispose() {
            if (done) return;
            done = true;
            timer.Stop(); timer.Dispose();
            // On helper failure do not leave an unsupervised shell reserving
            // space. Normal clean exit reaches here after qs has exited.
            if (child != null) {
                if (!child.HasExited) { child.Kill(); child.WaitForExit(); }
                child.Dispose(); child = null;
            }
            Native.RestoreOwned(saved, ownedPid, launch.RestoreWorkAreas, hide);
            Native.RecordAction = null;
            recovery.Dispose();
            DestroyHandle();
        }
    }
}
