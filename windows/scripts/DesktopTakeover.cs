// Windows-only supervisor. Compiled in the watchdog process, never in qs.exe.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Caelestia.Takeover {
    public sealed class Launch {
        public string Executable, Arguments, WorkingDirectory, ConfigPath, StateDirectory;
        public string StdoutPath, StderrPath;
        public bool RestoreWorkAreas;
        public Dictionary<string, string> Environment = new Dictionary<string, string>();
        // Isolated test supervisors rescue only windows of these processes.
        // A production supervisor rescues the whole session, apart from the
        // tiler guard, so this is ignored outside isolated mode.
        public List<int> TestWindowOwners = new List<int>();
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
    public sealed class SavedRegion {
        public long Handle, ProcessStartTicks;
        public uint Owner;
        // Null means no explicit region; otherwise this is RGNDATA in base64.
        public string RegionData;
    }
    public sealed class Snapshot {
        public ulong TaskbarFlags;
        // Default true keeps snapshots written by older versions compatible.
        public bool TaskbarFlagsSaved = true;
        // Explorer's "Show my taskbar on all displays" (MMTaskbarEnabled) before
        // the supervisor turned it off. Null means the value was absent.
        public bool MultiMonitorTaskbarSaved;
        public int? MultiMonitorTaskbar;
        public List<Display> Displays = new List<Display>();
        public List<Bar> Bars = new List<Bar>();
        public List<SavedRegion> Regions = new List<SavedRegion>();
    }
    public static class DpiScope {
        public static T Run<T>(Func<IntPtr, IntPtr> set, Func<T> action) {
            var previous = set(new IntPtr(-4)); // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
            if (previous == IntPtr.Zero) throw new InvalidOperationException("Unable to set per-monitor v2 DPI awareness.");
            try { return action(); }
            finally { set(previous); }
        }
    }
    public static class RegionBatch {
        // No mutation is allowed until every capture and the single persist succeeds.
        public static void Prepare(Snapshot snapshot, IList<Bar> bars,
            Func<Bar, SavedRegion> capture, Action<Snapshot> persist) {
            var captured = new List<SavedRegion>();
            foreach (var bar in bars) {
                var region = capture(bar);
                if (region == null) throw new InvalidOperationException("Taskbar disappeared during capture.");
                captured.Add(region);
            }
            snapshot.Regions = captured;
            persist(snapshot);
        }
    }
    public static class SupervisorSafety {
        // A diagnostic write must never prevent cleanup. Snapshot persistence
        // is deliberately not routed through this helper.
        public static void Log(Action write) {
            try { write(); } catch (IOException) {} catch (UnauthorizedAccessException) {}
        }
        public static void Fail(Action log, Action cleanup) {
            try { Log(log); } finally { cleanup(); }
        }
    }
    // Shell APIs have no timeout and a responsiveness check alone races a
    // subsequent hang. Keep at most one outstanding native call, never queue
    // retries, and never hold the supervisor's message pump waiting for it.
    public sealed class BoundedExplorerCall {
        int busy;
        public bool Try<T>(Func<T> action, out T result) {
            result = default(T);
            if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) return false;
            T value = default(T);
            Exception failure = null;
            var worker = new Thread(delegate() {
                try { value = action(); }
                catch (Exception error) { failure = error; }
                finally { Interlocked.Exchange(ref busy, 0); }
            });
            worker.IsBackground = true;
            worker.Start();
            if (!worker.Join(100)) return false;
            if (failure != null) throw failure;
            result = value;
            return true;
        }
    }
    // Null DataReceived marks EOF after all preceding callbacks have returned.
    // Per-child state remains valid even if a deadline expires before EOF.
    public sealed class LogDrain {
        int pending;
        public LogDrain(bool stdout, bool stderr) { pending = (stdout ? 1 : 0) + (stderr ? 1 : 0); }
        public bool Complete { get { return Interlocked.CompareExchange(ref pending, 0, 0) == 0; } }
        public void EndStream() { Interlocked.Decrement(ref pending); }
        // Read and written under the supervisor log lock: once retired, a
        // late callback from this child can no longer reach the shared logs.
        public bool Retired;
    }
    public static class RestartPolicy {
        // One immediate recovery, then backoff. The third quick failure still
        // gives up, so a bad build cannot spin in an unbounded restart loop.
        public static int DelaySeconds(int quickCrashes) {
            return quickCrashes <= 1 ? 0 : Math.Min(30, 1 << Math.Min(5, quickCrashes - 2));
        }
    }
    public static class TransientIo {
        // A scanner or indexer can hold a file for a moment. Retry a few times
        // with doubling pauses (25, 50, 100, 200 ms), then surface the error.
        public static void Retry(Action action, Action<int> pause) {
            for (int attempt = 0; ; attempt++) {
                try { action(); return; }
                catch (Exception error) {
                    if (!(error is IOException || error is UnauthorizedAccessException) || attempt >= 4) throw;
                }
                pause(25 << attempt);
            }
        }
    }
    // The first snapshot must be durable before any takeover. A lock that
    // outlasts the retries defers startup instead of ending the session.
    public sealed class StartupPersistence {
        readonly Action persist;
        readonly Action<Exception> report;
        readonly int maxFailures;
        int failures;
        bool durable;
        public StartupPersistence(Action persist, Action<Exception> report) : this(persist, report, 0) {}
        // maxFailures > 0 bounds the retries; the last error is then surfaced
        // instead of leaving an invisible supervisor retrying forever.
        public StartupPersistence(Action persist, Action<Exception> report, int maxFailures) {
            this.persist = persist; this.report = report; this.maxFailures = maxFailures;
        }
        public bool Ready() {
            if (durable) return true;
            try { persist(); durable = true; }
            catch (Exception error) {
                if (!(error is IOException || error is UnauthorizedAccessException)) throw;
                if (maxFailures > 0 && ++failures >= maxFailures) throw;
                report(error);
            }
            return durable;
        }
    }
    public static class RegionCapture {
        public static SavedRegion TryCapture(Func<SavedRegion> capture, Func<bool> vanished) {
            try {
                var result = capture();
                return result == null || vanished() ? null : result;
            }
            catch (Exception) {
                // Only discard an error if the enumerated identity has
                // actually disappeared. Other native failures remain fatal.
                if (vanished()) return null;
                throw;
            }
        }
    }
    // Persist ownership before any mutation, including newly discovered HWNDs.
    // Native operations are injected so bookkeeping is testable without a desktop.
    public sealed class RegionSuppression {
        readonly Snapshot snapshot;
        readonly Func<Bar, SavedRegion> capture;
        readonly Action<SavedRegion> persist, apply, restore;
        public RegionSuppression(Snapshot snapshot, Func<Bar, SavedRegion> capture,
            Action<SavedRegion> persist, Action<SavedRegion> apply, Action<SavedRegion> restore) {
            this.snapshot = snapshot; this.capture = capture; this.persist = persist;
            this.apply = apply; this.restore = restore;
        }
        public void Reconcile(Bar bar) {
            var current = capture(bar);
            if (current == null) return;
            var saved = snapshot.Regions.Find(r => r.Handle == current.Handle &&
                r.Owner == current.Owner && r.ProcessStartTicks == current.ProcessStartTicks);
            if (saved == null) {
                snapshot.Regions.Add(current);
                try { persist(current); } catch { snapshot.Regions.Remove(current); throw; }
                saved = current;
            }
            apply(saved);
        }
        public void Restore() {
            foreach (var region in snapshot.Regions) restore(region);
        }
    }
    public sealed class TaskbarAction {
        public string Operation, Device, Utc, Source;
        public long Handle;
        public uint Owner;
        public bool VisibleBefore, RequestedVisible, VisibleAfter;
        // Ticks are Stopwatch/QPC ticks, not wall-clock or WinEvent's ms time.
        public long MonotonicTicks, TickFrequency;
        public long? ShowObservedTicks;
        public double? ShowToHideMilliseconds;
    }
    // All timestamps are supplied by the caller, allowing deterministic tests.
    // Count only rapid same-HWND recurrences after our hides. Twelve within
    // two seconds trigger five seconds of polling-only operation.
    public sealed class TaskbarShowPolicy {
        sealed class WindowState {
            public long LastHide;
            public readonly Queue<long> Recurrences = new Queue<long>();
        }
        readonly long frequency;
        readonly Dictionary<string, WindowState> windows = new Dictionary<string, WindowState>();
        long backoffUntil;
        public TaskbarShowPolicy(long frequency) { this.frequency = frequency; }
        static string Key(Bar bar) { return bar.Owner.ToString() + ":" + bar.Handle.ToString(); }
        void Prune(long now) {
            var expired = new List<string>();
            foreach (var entry in windows)
                if (now - entry.Value.LastHide >= 2 * frequency) expired.Add(entry.Key);
            foreach (var key in expired) windows.Remove(key);
        }
        public bool AllowImmediate(Bar bar, long now, out bool enteredBackoff) {
            enteredBackoff = false;
            if (now < backoffUntil) return false;
            Prune(now);
            WindowState state;
            if (windows.TryGetValue(Key(bar), out state)) {
                while (state.Recurrences.Count > 0 && now - state.Recurrences.Peek() >= 2 * frequency)
                    state.Recurrences.Dequeue();
                long elapsed = now - state.LastHide;
                if (elapsed >= 0 && elapsed <= frequency * 75 / 1000) {
                    state.Recurrences.Enqueue(now);
                    if (state.Recurrences.Count >= 12) {
                        windows.Clear();
                        backoffUntil = now + 5 * frequency;
                        enteredBackoff = true;
                        return false;
                    }
                }
            }
            return true;
        }
        public void RememberHide(Bar bar, long ticks) {
            WindowState state;
            var key = Key(bar);
            if (!windows.TryGetValue(key, out state)) {
                state = new WindowState();
                windows.Add(key, state);
            }
            state.LastHide = ticks;
        }
        public void Reset() { windows.Clear(); backoffUntil = 0; }
        public bool PollingRequired(long now) { return now < backoffUntil; }
    }
    // Hook ownership and replacement are injectable, so restart/failure and
    // disposal can be exercised without registering a real desktop hook.
    public sealed class TaskbarHookBinding : IDisposable {
        readonly Func<uint, IntPtr> install;
        readonly Action<IntPtr> remove;
        IntPtr hook;
        public uint Owner { get; private set; }
        public bool Matches(IntPtr value) { return hook != IntPtr.Zero && hook == value; }
        public TaskbarHookBinding(Func<uint, IntPtr> install, Action<IntPtr> remove) {
            this.install = install; this.remove = remove;
        }
        public void Refresh(uint owner, bool force) {
            if (!force && owner == Owner && hook != IntPtr.Zero) return;
            Dispose();
            if (owner == 0) return;
            hook = install(owner);
            if (hook != IntPtr.Zero) Owner = owner;
        }
        public void Dispose() {
            if (hook != IntPtr.Zero) remove(hook);
            hook = IntPtr.Zero;
            Owner = 0;
        }
    }
    public sealed class TaskbarShowHandler {
        readonly TaskbarShowPolicy policy;
        readonly Func<IntPtr, uint, Bar> resolve;
        readonly Action<Bar> suppress;
        readonly Func<Bar, long, TaskbarAction> hide;
        readonly Action<TaskbarAction> record;
        public TaskbarShowHandler(TaskbarShowPolicy policy, Func<IntPtr, uint, Bar> resolve,
            Func<Bar, long, TaskbarAction> hide, Action<TaskbarAction> record) {
            this.policy = policy; this.resolve = resolve; this.hide = hide; this.record = record;
            this.suppress = delegate(Bar bar) {};
        }
        public TaskbarShowHandler(TaskbarShowPolicy policy, Func<IntPtr, uint, Bar> resolve,
            Action<Bar> suppress, Func<Bar, long, TaskbarAction> hide, Action<TaskbarAction> record) {
            this.policy = policy; this.resolve = resolve; this.suppress = suppress;
            this.hide = hide; this.record = record;
        }
        public void Handle(uint owner, IntPtr window, int objectId, int childId, long ticks) {
            if (owner == 0 || objectId != 0 || childId != 0) return;
            var bar = resolve(window, owner);
            if (bar == null) return;
            var observed = Native.ObserveShow(bar, ticks);
            observed.Source = "event";
            bool enteredBackoff = false;
            bool immediate = bar.Visible && policy.AllowImmediate(bar, ticks, out enteredBackoff);
            // Hide before disk I/O. Delayed events can describe a window
            // that is already hidden; record them without another hide.
            var hidden = immediate && bar.Visible ? hide(bar, ticks) : null;
            if (hidden != null) {
                hidden.Source = "event";
                policy.RememberHide(bar, hidden.MonotonicTicks);
            }
            // Region capture and its durable journal can involve slow Explorer
            // calls during a display transition. Hide first; Reconcile still
            // journals the original region before changing that region.
            if (immediate) suppress(bar);
            record(observed);
            if (hidden != null) record(hidden);
            if (enteredBackoff) {
                var backoff = Native.ObserveShow(bar, ticks);
                backoff.Operation = "event-backoff";
                backoff.Source = "event";
                record(backoff);
            }
        }
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
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string name, string title);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr window);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint parameter, ref Rect rect, uint flags);
        [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint message, ref AppBarData data);
        static readonly BoundedExplorerCall explorerCalls = new BoundedExplorerCall();
        public static bool ExplorerWorkDeferred { get; private set; }
        static bool TryAppBar(uint message, AppBarData data, out ulong result) {
            // SHAppBarMessage talks to Explorer, not necessarily data.Window.
            foreach (var bar in Taskbars())
                if (IsHungAppWindow(new IntPtr(bar.Handle))) { result = 0; ExplorerWorkDeferred = true; return false; }
            bool ready = explorerCalls.Try(delegate { return SHAppBarMessage(message, ref data).ToUInt64(); }, out result);
            if (!ready) ExplorerWorkDeferred = true;
            return ready;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string message);
        [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
        [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr window, IntPtr update, IntPtr region, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr window, uint message,
            UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
        [StructLayout(LayoutKind.Sequential)]
        struct PlacementPoint { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)]
        struct WindowPlacement {
            public int Length, Flags, ShowCmd;
            public PlacementPoint Minimum, Maximum;
            public Rect Normal;
        }
        [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr window, ref WindowPlacement placement);
        [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr window, ref WindowPlacement placement);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr window);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref Rect rect, uint flags);
        [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after,
            int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetProp(IntPtr window, IntPtr name);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr RemoveProp(IntPtr window, IntPtr name);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern ushort GlobalFindAtom(string name);
        // The tiler's own session owner guard, opened the same way it does.
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenMutex(uint access, bool inherit, string name);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        const uint Synchronize = 0x00100000;
        // TilingManager creates this mutex while it tiles; the shell's next
        // start runs its own rescue once the mutex is free again.
        public const string TilingMutex = @"Local\QuickshellTiling";
        const string ParkedProperty = "QuickshellTilingParked";
        const uint MonitorDefaultToNull = 0, MonitorDefaultToNearest = 2;
        const uint SwpNoZOrder = 0x0004, SwpNoActivate = 0x0010, SwpNoOwnerZOrder = 0x0200, SwpAsyncWindowPos = 0x4000;

        const string ExplorerAdvanced = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";
        static int? ReadMultiMonitorTaskbar() {
            using (var key = Registry.CurrentUser.OpenSubKey(ExplorerAdvanced)) {
                var value = key == null ? null : key.GetValue("MMTaskbarEnabled");
                return value is int ? (int?)(int)value : null;
            }
        }
        static void WriteMultiMonitorTaskbar(int? value) {
            using (var key = Registry.CurrentUser.CreateSubKey(ExplorerAdvanced)) {
                if (value.HasValue) key.SetValue("MMTaskbarEnabled", value.Value, RegistryValueKind.DWord);
                else key.DeleteValue("MMTaskbarEnabled", false);
            }
            // Settings broadcasts the same notification; Explorer then creates or
            // destroys the secondary taskbars without restarting.
            UIntPtr ignored;
            SendMessageTimeout(new IntPtr(0xFFFF), 0x001A, UIntPtr.Zero, "TraySettings", 0x0002, 3000, out ignored);
        }
        // Explorer replaces a secondary taskbar's window region while it re-lays
        // the taskbar out after a display mode change (for example an HDR
        // toggle), so it is drawn for a few hundred milliseconds before the
        // region can be suppressed again. Without secondary taskbars there is
        // nothing to flash. The original value is persisted before the change.
        public static void SuppressSecondaryTaskbars(Snapshot snapshot, Action persist) {
            if (!snapshot.MultiMonitorTaskbarSaved) {
                snapshot.MultiMonitorTaskbar = ReadMultiMonitorTaskbar();
                snapshot.MultiMonitorTaskbarSaved = true;
                // Roll back so a retry persists again instead of mutating unsaved.
                try { persist(); } catch { snapshot.MultiMonitorTaskbarSaved = false; throw; }
            }
            if (ReadMultiMonitorTaskbar() != 0) WriteMultiMonitorTaskbar(0);
        }
        static void RestoreSecondaryTaskbars(Snapshot saved) {
            if (saved == null || !saved.MultiMonitorTaskbarSaved) return;
            // Leave a value the user changed while the shell was running.
            if (ReadMultiMonitorTaskbar() == 0 && saved.MultiMonitorTaskbar != 0)
                WriteMultiMonitorTaskbar(saved.MultiMonitorTaskbar);
        }
        public delegate void WinEventCallback(IntPtr hook, uint eventType, IntPtr window,
            int objectId, int childId, uint thread, uint eventTime);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWinEventHook(
            uint first, uint last, IntPtr module, WinEventCallback callback, uint process, uint thread, uint flags);
        [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll", SetLastError = true)] static extern int GetWindowRgn(IntPtr window, IntPtr region);
        [DllImport("user32.dll", SetLastError = true)] static extern int SetWindowRgn(IntPtr window, IntPtr region, bool redraw);
        [DllImport("gdi32.dll", SetLastError = true)] static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
        [DllImport("gdi32.dll", SetLastError = true)] static extern uint GetRegionData(IntPtr region, uint size, byte[] data);
        [DllImport("gdi32.dll", SetLastError = true)] static extern IntPtr ExtCreateRegion(IntPtr transform, uint size, byte[] data);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
        [DllImport("kernel32.dll")] static extern void SetLastError(uint error);

        public static void SaveSnapshot(string path, Snapshot snapshot) {
            var temporary = path + ".tmp";
            var text = new JavaScriptSerializer().Serialize(snapshot);
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(stream)) {
                writer.Write(text);
                writer.Flush();
                stream.Flush(true);
            }
            TransientIo.Retry(delegate {
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }, System.Threading.Thread.Sleep);
        }
        public static void PrepareRegions(string path, Snapshot snapshot, List<Bar> bars) {
            RegionBatch.Prepare(snapshot, bars, CaptureRegion,
                delegate(Snapshot value) { SaveSnapshot(path, value); });
        }
        static long ProcessStart(uint owner) {
            using (var process = Process.GetProcessById((int)owner)) return process.StartTime.ToUniversalTime().Ticks;
        }
        static bool SameRegionWindow(SavedRegion saved) {
            var window = new IntPtr(saved.Handle);
            uint owner;
            if (!IsWindow(window)) return false;
            GetWindowThreadProcessId(window, out owner);
            if (owner != saved.Owner || !Explorer(owner)) return false;
            try {
                if (ProcessStart(owner) != saved.ProcessStartTicks) return false;
                var name = new StringBuilder(128);
                GetClassName(window, name, name.Capacity);
                return IsExplorerTaskbar(name.ToString(), owner, saved.Owner);
            } catch (ArgumentException) { return false; }
              catch (InvalidOperationException) { return false; }
              catch (System.ComponentModel.Win32Exception) { return false; }
        }
        public static SavedRegion CaptureRegion(Bar bar) {
            if (IsHungAppWindow(new IntPtr(bar.Handle))) return null;
            SavedRegion result;
            return explorerCalls.Try(delegate { return DpiScope.Run(SetThreadDpiAwarenessContext, delegate {
                return RegionCapture.TryCapture(delegate { return CaptureRegionCore(bar); },
                    delegate { return !CurrentTaskbar(bar); });
            }); }, out result) ? result : null;
        }
        static bool CurrentTaskbar(Bar bar) {
            var window = new IntPtr(bar.Handle);
            uint owner;
            if (!IsWindow(window)) return false;
            GetWindowThreadProcessId(window, out owner);
            var name = new StringBuilder(128);
            GetClassName(window, name, name.Capacity);
            return IsExplorerTaskbar(name.ToString(), owner, bar.Owner) && Explorer(owner);
        }
        static SavedRegion CaptureRegionCore(Bar bar) {
            var saved = new SavedRegion { Handle = bar.Handle, Owner = bar.Owner, ProcessStartTicks = ProcessStart(bar.Owner) };
            if (!SameRegionWindow(saved)) return null;
            var region = CreateRectRgn(0, 0, 0, 0);
            if (region == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try {
                // ERROR also means no explicit region. Reject an explicit
                // last-error value, although the API does not promise one.
                SetLastError(0);
                int kind = GetWindowRgn(new IntPtr(bar.Handle), region);
                int error = Marshal.GetLastWin32Error();
                if (kind == 0 && error != 0) throw new System.ComponentModel.Win32Exception(error, "GetWindowRgn failed");
                if (kind != 0) {
                    uint size = GetRegionData(region, 0, null);
                    if (size == 0) throw new System.ComponentModel.Win32Exception();
                    var data = new byte[size];
                    if (GetRegionData(region, size, data) != size) throw new System.ComponentModel.Win32Exception();
                    saved.RegionData = Convert.ToBase64String(data);
                }
                return SameRegionWindow(saved) ? saved : null;
            } finally { DeleteObject(region); }
        }
        static void SetRegion(SavedRegion saved, IntPtr region) {
            if (!SameRegionWindow(saved)) { if (region != IntPtr.Zero) DeleteObject(region); return; }
            if (SetWindowRgn(new IntPtr(saved.Handle), region, true) == 0) {
                int error = Marshal.GetLastWin32Error();
                if (region != IntPtr.Zero) DeleteObject(region);
                if (!SameRegionWindow(saved)) return;
                throw new System.ComponentModel.Win32Exception(error, "SetWindowRgn failed");
            }
            // The system owns a successfully assigned region.
        }
        public static void ApplyEmptyRegion(SavedRegion saved) {
            if (IsHungAppWindow(new IntPtr(saved.Handle))) return;
            bool ignored;
            explorerCalls.Try(delegate { return DpiScope.Run(SetThreadDpiAwarenessContext, delegate {
                ApplyEmptyRegionCore(saved);
                return true;
            }); }, out ignored);
        }
        static void ApplyEmptyRegionCore(SavedRegion saved) {
            if (!SameRegionWindow(saved)) return;
            var window = new IntPtr(saved.Handle);
            var existing = CreateRectRgn(0, 0, 0, 0);
            if (existing == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try { if (GetWindowRgn(window, existing) == 1) return; } // NULLREGION
            finally { DeleteObject(existing); }
            var empty = CreateRectRgn(0, 0, 0, 0);
            if (empty == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            SetRegion(saved, empty);
        }
        public static void RestoreRegion(SavedRegion saved) {
            if (IsHungAppWindow(new IntPtr(saved.Handle))) { ExplorerWorkDeferred = true; return; }
            bool ignored;
            if (!explorerCalls.Try(delegate { return DpiScope.Run(SetThreadDpiAwarenessContext, delegate {
                RestoreRegionCore(saved);
                return true;
            }); }, out ignored)) ExplorerWorkDeferred = true;
        }
        static void RestoreRegionCore(SavedRegion saved) {
            if (!SameRegionWindow(saved)) return;
            IntPtr region = IntPtr.Zero;
            if (saved.RegionData != null) {
                var data = Convert.FromBase64String(saved.RegionData);
                region = ExtCreateRegion(IntPtr.Zero, (uint)data.Length, data);
                if (region == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            }
            SetRegion(saved, region);
        }

        public static IntPtr HookShows(uint owner, WinEventCallback callback) {
            // EVENT_OBJECT_SHOW; out-of-context callbacks run on this UI thread.
            return SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, callback, owner, 0, 0x0002);
        }
        public static void UnhookShows(IntPtr hook) { UnhookWinEvent(hook); }
        static bool Explorer(uint owner) {
            if (owner == 0) return false;
            try {
                using (var process = Process.GetProcessById((int)owner))
                    return String.Equals(process.ProcessName, "explorer", StringComparison.OrdinalIgnoreCase);
            } catch (ArgumentException) { return false; }
              catch (InvalidOperationException) { return false; }
              catch (System.ComponentModel.Win32Exception) { return false; }
        }
        public static IntPtr ExplorerTaskbar() {
            // FindWindow can return Quickshell's tray hook, which shares the
            // Shell_TrayWnd class and moves itself to the front.
            var window = IntPtr.Zero;
            while ((window = FindWindowEx(IntPtr.Zero, window, "Shell_TrayWnd", null)) != IntPtr.Zero) {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (Explorer(owner)) return window;
            }
            return IntPtr.Zero;
        }
        public static uint ExplorerTaskbarOwner() {
            var window = ExplorerTaskbar();
            if (window == IntPtr.Zero) return 0;
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            return owner;
        }
        public static Bar EventTaskbar(IntPtr window, uint expectedOwner) {
            if (window == IntPtr.Zero || expectedOwner == 0 || !IsWindow(window)) return null;
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            var name = new StringBuilder(128);
            GetClassName(window, name, name.Capacity);
            if (!IsExplorerTaskbar(name.ToString(), owner, expectedOwner)) return null;
            var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
            GetMonitorInfo(MonitorFromWindow(window, 2), ref info);
            return new Bar { Handle = window.ToInt64(), Owner = owner, Device = info.Device,
                Visible = IsWindowVisible(window) };
        }
        public static bool IsExplorerTaskbar(string name, uint owner, uint expectedOwner) {
            return expectedOwner != 0 && owner == expectedOwner &&
                (name == "Shell_TrayWnd" || name == "Shell_SecondaryTrayWnd");
        }
        static TaskbarAction ActionFor(Bar bar, string operation, long ticks) {
            return new TaskbarAction { Operation = operation, Handle = bar.Handle, Owner = bar.Owner,
                Device = bar.Device, VisibleBefore = bar.Visible, MonotonicTicks = ticks,
                TickFrequency = Stopwatch.Frequency, Utc = DateTime.UtcNow.ToString("o") };
        }
        public static TaskbarAction ObserveShow(Bar bar, long ticks) {
            var action = ActionFor(bar, "show", ticks);
            action.RequestedVisible = true;
            action.VisibleAfter = bar.Visible;
            action.ShowObservedTicks = ticks;
            return action;
        }
        public static void Record(TaskbarAction action) {
            if (RecordAction != null && action != null) RecordAction(action);
        }

        static AppBarData AppBar(IntPtr window) {
            return new AppBarData { Size = (uint)Marshal.SizeOf(typeof(AppBarData)), Window = window };
        }
        public static List<Bar> Taskbars() {
            return DpiScope.Run(SetThreadDpiAwarenessContext, TaskbarsCore);
        }
        static List<Bar> TaskbarsCore() {
            var bars = new List<Bar>();
            EnumWindows(delegate(IntPtr window, IntPtr data) {
                var name = new StringBuilder(128);
                GetClassName(window, name, name.Capacity);
                if (name.ToString() != "Shell_TrayWnd" && name.ToString() != "Shell_SecondaryTrayWnd") return true;
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                // Quickshell's tray hook also registers a Shell_TrayWnd window.
                if (!Explorer(owner)) return true;
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
                result.TaskbarFlagsSaved = TryAppBar(4, data, out result.TaskbarFlags);
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
        public static bool CaptureMissingTaskbarFlags(Snapshot snapshot) {
            if (snapshot.TaskbarFlagsSaved) return false;
            ulong flags;
            if (!TryAppBar(4, AppBar(IntPtr.Zero), out flags)) return false;
            snapshot.TaskbarFlags = flags;
            snapshot.TaskbarFlagsSaved = true;
            return true;
        }
        static TaskbarAction Visibility(Bar bar, bool visible, string operation, long? showTicks) {
            var window = new IntPtr(bar.Handle);
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (!IsWindow(window) || owner != bar.Owner) return null;
            if (IsHungAppWindow(window)) { ExplorerWorkDeferred = true; return null; }
            ShowWindowAsync(window, visible ? 8 : 0); // SW_SHOWNA avoids taking focus
            long ticks = Stopwatch.GetTimestamp();
            var action = ActionFor(bar, operation, ticks);
            action.RequestedVisible = visible;
            action.VisibleAfter = IsWindowVisible(window);
            action.ShowObservedTicks = showTicks;
            if (showTicks.HasValue) action.ShowToHideMilliseconds =
                (ticks - showTicks.Value) * 1000.0 / Stopwatch.Frequency;
            return action;
        }
        public static TaskbarAction HideObserved(Bar bar, long ticks) {
            return Visibility(bar, false, "hide", ticks);
        }
        public static void Hide(bool recordUnchanged) {
            foreach (var bar in Taskbars()) {
                if (!bar.Visible && !recordUnchanged) continue;
                long ticks = Stopwatch.GetTimestamp();
                var show = bar.Visible ? ObserveShow(bar, ticks) : null;
                var action = Visibility(bar, false, "hide", bar.Visible ? (long?)ticks : null);
                if (show != null) show.Source = recordUnchanged ? "reconcile" : "poll";
                if (action != null) action.Source = recordUnchanged ? "reconcile" : "poll";
                Record(show);
                Record(action);
            }
        }
        // The backend records AppBar HWND -> PID here. Never remove a live
        // registration or a registration belonging to a different live shell.
        static readonly HashSet<int> deferredAppBarOwners = new HashSet<int>();
        public static void RetryStaleAppBars() {
            foreach (var owner in new List<int>(deferredAppBarOwners)) RemoveStaleAppBars(owner);
        }
        public static int RemoveStaleAppBars(int owner) {
            deferredAppBarOwners.Remove(owner);
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
                    ulong ignored;
                    if (!TryAppBar(1, data, out ignored)) {
                        deferredAppBarOwners.Add(owner);
                        continue; // retry from the retained registry journal
                    }
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
            ExplorerWorkDeferred = false;
            var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
            try {
                var regionErrors = new List<string>();
                int removed = owner >= 0 ? RemoveStaleAppBars(owner) : 0;
                if (taskbars) {
                    RestoreSecondaryTaskbars(saved);
                    if (saved != null && saved.Regions != null)
                        foreach (var region in saved.Regions) {
                            try { RestoreRegion(region); }
                            catch (Exception error) { regionErrors.Add(region.Handle + ": " + error.Message); }
                        }
                    var data = AppBar(ExplorerTaskbar());
                    ulong currentFlags;
                    bool flagsReady = TryAppBar(4, data, out currentFlags);
                    // Emergency recovery deliberately makes the real taskbar
                    // accessible. Exact lifecycle restoration uses saved flags.
                    ulong targetFlags = saved == null ? currentFlags & ~1UL : saved.TaskbarFlags;
                    if (flagsReady && (saved == null || saved.TaskbarFlagsSaved) && currentFlags != targetFlags) {
                        data.Parameter = new IntPtr((long)targetFlags);
                        ulong ignored;
                        TryAppBar(10, data, out ignored);
                    }
                    foreach (var bar in Taskbars()) {
                        Bar original = saved == null ? null : saved.Bars.Find(b => b.Device == bar.Device);
                        Record(Visibility(bar, original == null || original.Visible, "restore", null));
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
                // Invalidate without RDW_UPDATENOW, which synchronously paints
                // foreign desktop children.
                RedrawWindow(GetDesktopWindow(), IntPtr.Zero, IntPtr.Zero, 0x81);
                if (regionErrors.Count != 0)
                    throw new InvalidOperationException("Taskbar region restoration failed: " + String.Join("; ", regionErrors.ToArray()));
            } finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
        }
        // A tiler parks a window off screen and tags it with the rectangle to
        // restore, packed as x | y << 16 | width << 32 | height << 48. The
        // shell rescues them from its own next start; when it crashed and the
        // supervisor stops restarting it, this process is the only one left to
        // do it. Mirrors TilingManager::rescueParked.
        // tilerMutex is the guard that a live tiler holds while it owns parked
        // windows. owned, when set, narrows the pass to those processes; an
        // isolated test supervisor uses it so it can never touch a real shell.
        public static int RescueParkedWindows(string tilerMutex, Func<int, bool> owned) {
            var tiler = OpenMutex(Synchronize, false, tilerMutex);
            if (tiler != IntPtr.Zero) { CloseHandle(tiler); return 0; }
            var atom = GlobalFindAtom(ParkedProperty);
            if (atom == 0) return 0;
            var tag = new IntPtr(atom);
            var windows = new List<IntPtr>();
            EnumWindows(delegate(IntPtr window, IntPtr data) { windows.Add(window); return true; }, IntPtr.Zero);
            var rescued = 0;
            // The tiler works in physical pixels, so the packed rectangle is physical.
            var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
            try {
                foreach (var window in windows) {
                    if (owned != null) {
                        uint owner;
                        GetWindowThreadProcessId(window, out owner);
                        if (!owned((int)owner)) continue;
                    }
                    var packed = GetProp(window, tag);
                    if (packed == IntPtr.Zero) continue;
                    // The tag is consumed whether or not the window needs a move.
                    RemoveProp(window, tag);
                    var restore = OnScreen(UnpackRect(unchecked((ulong)packed.ToInt64())));
                    if (IsIconic(window) || IsZoomed(window)) {
                        var placement = new WindowPlacement { Length = Marshal.SizeOf(typeof(WindowPlacement)) };
                        if (!GetWindowPlacement(window, ref placement)) continue;
                        // A visible restore point needs no move.
                        var normal = placement.Normal;
                        var offset = PlacementOffset(window, MonitorFromWindow(window, MonitorDefaultToNearest));
                        normal.Left += offset.X; normal.Top += offset.Y;
                        normal.Right += offset.X; normal.Bottom += offset.Y;
                        if (MonitorFromRect(ref normal, MonitorDefaultToNull) != IntPtr.Zero) continue;
                        placement.Normal = ScreenToPlacement(window, restore);
                        placement.Flags |= 4; // WPF_ASYNCWINDOWPLACEMENT
                        SetWindowPlacement(window, ref placement);
                        rescued++;
                        continue;
                    }
                    if (MonitorFromWindow(window, MonitorDefaultToNull) != IntPtr.Zero) continue;
                    SetWindowPos(window, IntPtr.Zero, restore.Left, restore.Top,
                        restore.Right - restore.Left, restore.Bottom - restore.Top,
                        SwpNoZOrder | SwpNoOwnerZOrder | SwpNoActivate | SwpAsyncWindowPos);
                    rescued++;
                }
            } finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
            return rescued;
        }
        // WINDOWPLACEMENT is in workspace coordinates for ordinary top-level
        // windows, but not for tool windows.
        static PlacementPoint PlacementOffset(IntPtr window, IntPtr monitor) {
            if ((GetWindowLongPtr(window, -20 /* GWL_EXSTYLE */).ToInt64() & 0x80 /* WS_EX_TOOLWINDOW */) != 0)
                return new PlacementPoint();
            var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
            if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info)) return new PlacementPoint();
            return new PlacementPoint { X = info.Work.Left - info.Monitor.Left, Y = info.Work.Top - info.Monitor.Top };
        }
        static Rect ScreenToPlacement(IntPtr window, Rect rect) {
            var offset = PlacementOffset(window, MonitorFromRect(ref rect, MonitorDefaultToNearest));
            return new Rect { Left = rect.Left - offset.X, Top = rect.Top - offset.Y,
                Right = rect.Right - offset.X, Bottom = rect.Bottom - offset.Y };
        }
        static Rect UnpackRect(ulong packed) {
            var left = unchecked((short)(packed & 0xFFFF));
            var top = unchecked((short)((packed >> 16) & 0xFFFF));
            return new Rect { Left = left, Top = top,
                Right = left + (int)((packed >> 32) & 0xFFFF), Bottom = top + (int)((packed >> 48) & 0xFFFF) };
        }
        static Rect OnScreen(Rect rect) {
            if (MonitorFromRect(ref rect, MonitorDefaultToNull) != IntPtr.Zero) return rect;
            var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
            if (!GetMonitorInfo(MonitorFromRect(ref rect, MonitorDefaultToNearest), ref info)) return rect;
            var width = info.Work.Right - info.Work.Left;
            var height = info.Work.Bottom - info.Work.Top;
            if (width <= 0 || height <= 0) return rect;
            var w = Math.Min(rect.Right - rect.Left, width);
            var h = Math.Min(rect.Bottom - rect.Top, height);
            var left = Bound(rect.Left, info.Work.Left, info.Work.Left + width - w);
            var top = Bound(rect.Top, info.Work.Top, info.Work.Top + height - h);
            return new Rect { Left = left, Top = top, Right = left + w, Bottom = top + h };
        }
        static int Bound(int value, int minimum, int maximum) {
            return value < minimum ? minimum : (value > maximum ? maximum : value);
        }
    }

    public static class LaunchEnvironment {
        public const string TaskbarShortcutFilter = "QS_WINDOWS_TASKBAR_SHORTCUT_FILTER";
        public const string DisableCrashRelaunch = "QS_DISABLE_CRASH_RELAUNCH";
        public const string DisableCrashHandler = "QS_DISABLE_CRASH_HANDLER";
        // The child inherits this supervisor's environment, so every switch is
        // set or removed here and an inherited value never applies.
        // The shell's own keyboard hook filters Explorer's taskbar shortcuts
        // only while this supervisor hides the taskbar. The supervisor owns the
        // restart, so a crash keeps its minidump and desktop cleanup and skips
        // only the shell's own relaunch.
        public static void Apply(System.Collections.Specialized.StringDictionary variables, bool hide) {
            variables.Remove(DisableCrashHandler);
            variables[DisableCrashRelaunch] = "1";
            variables.Remove(TaskbarShortcutFilter);
            if (hide) variables[TaskbarShortcutFilter] = "1";
        }
    }

    public sealed class Supervisor : NativeWindow, IDisposable {
        readonly Launch launch;
        readonly bool hide, restart, invisible;
        readonly bool isolatedTest;
        readonly bool adoptedUncleanBaseline;
        readonly int testLogDelayMs;
        readonly Snapshot saved;
        readonly System.Threading.EventWaitHandle recovery;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        readonly uint taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
        readonly TaskbarShowPolicy showPolicy = new TaskbarShowPolicy(Stopwatch.Frequency);
        readonly Native.WinEventCallback showCallback;
        readonly TaskbarHookBinding showHook;
        readonly TaskbarShowHandler showHandler;
        readonly RegionSuppression regions;
        readonly StartupPersistence startup;
        readonly string tilerMutex;
        // Isolated tests rescue only the windows of the processes this
        // supervisor launched and any the test named in its spec.
        readonly List<int> rescueOwners;
        readonly Func<int, bool> rescueFilter;
        Process child;
        LogDrain childDrain;
        long drainDeadline;
        long stopDeadline;
        bool recovering;
        bool forcedChildTermination;
        bool childCleanupComplete;
        DateTime started, nextStart;
        int quickCrashes;
        int ownedPid = -1;
        uint lastHookFailure;
        DateTime nextPersistLog;
        DateTime nextExplorerRetry;
        DateTime nextHeartbeat;
        DateTime nextTaskbarAudit;
        string statusPhase;
        int statusPid;
        bool done;
        public int ExitCode;

        public static string MutexName { get { return @"Local\CaelestiaDesktopTakeover-" + Process.GetCurrentProcess().SessionId; } }
        public static string EventName { get { return MutexName + "-Recovery"; } }
        // Desktop restoration runs first, then banner recovery may take 45 s.
        // "restoring" covers both; Quit and recovery callers wait for ownership
        // to be released, not just for the desktop to become accessible.
        public const int RecoveryBoundMs = 60000;
        // Leave room for the 45 s banner restore, 2 s log drain and cleanup
        // within RecoveryBoundMs. Only an explicit recovery starts this clock.
        public const int ChildExitGraceMs = 5000;
        public static void RecoverActive() {
            RecoverActive(RecoveryBoundMs);
        }
        public static void RecoverActive(int timeoutMs) {
            if (timeoutMs < 0 || timeoutMs > RecoveryBoundMs) throw new ArgumentOutOfRangeException("timeoutMs");
            try { using (var handle = System.Threading.EventWaitHandle.OpenExisting(EventName)) handle.Set(); }
            catch (System.Threading.WaitHandleCannotBeOpenedException) {}
            // Wait for the owner to finish restoring before emergency fallback.
            using (var mutex = new System.Threading.Mutex(false, MutexName)) {
                bool acquired;
                try { acquired = mutex.WaitOne(timeoutMs); }
                catch (System.Threading.AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new InvalidOperationException("Supervisor has not stopped. Retry recovery after it exits.");
                mutex.ReleaseMutex();
            }
        }
        public static int Run(string specPath, bool hide, bool restart, bool invisible) {
            return RunCore(specPath, hide, restart, invisible, MutexName, EventName, false, 0);
        }
        // Used only by the non-desktop regression harness. Its unique names
        // cannot acquire or signal the real session supervisor.
        public static int RunIsolatedTest(string specPath, string token) {
            return RunIsolatedTest(specPath, token, 0);
        }
        public static int RunIsolatedTest(string specPath, string token, int logDelayMs) {
            Guid parsed;
            if (!Guid.TryParseExact(token, "N", out parsed)) throw new ArgumentException("Invalid test token.");
            if (logDelayMs < 0 || logDelayMs > 5000) throw new ArgumentOutOfRangeException("logDelayMs");
            string name = @"Local\CaelestiaDesktopTakeover-Test-" + parsed.ToString("N");
            return RunCore(specPath, false, true, false, name, name + "-Recovery", true, logDelayMs);
        }
        static int RunCore(string specPath, bool hide, bool restart, bool invisible,
            string mutexName, string eventName, bool isolatedTest, int testLogDelayMs) {
            using (var mutex = new System.Threading.Mutex(false, mutexName)) {
                bool acquired;
                try { acquired = mutex.WaitOne(0); }
                catch (System.Threading.AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new InvalidOperationException("A desktop supervisor already owns this Windows session.");
                try {
                    var launch = new JavaScriptSerializer().Deserialize<Launch>(File.ReadAllText(specPath));
                    // An isolated supervisor must not be blocked by the live
                    // shell's tiler guard, so it uses its own unheld name.
                    string tilerMutex = isolatedTest ? mutexName + "-Tiling" : Native.TilingMutex;
                    using (var supervisor = new Supervisor(launch, hide, restart, invisible, eventName, tilerMutex, isolatedTest, testLogDelayMs)) {
                        Application.Run();
                        return supervisor.ExitCode;
                    }
                } finally { mutex.ReleaseMutex(); }
            }
        }
        Supervisor(Launch launch, bool hide, bool restart, bool invisible, string eventName,
            string tilerMutex, bool isolatedTest, int testLogDelayMs) {
            this.launch = launch; this.hide = hide; this.restart = restart; this.invisible = invisible && hide;
            this.isolatedTest = isolatedTest;
            this.tilerMutex = tilerMutex;
            this.testLogDelayMs = testLogDelayMs;
            if (isolatedTest) {
                rescueOwners = new List<int>();
                if (launch.TestWindowOwners != null) rescueOwners.AddRange(launch.TestWindowOwners);
                rescueFilter = OwnsRescuedWindow;
            }
            Directory.CreateDirectory(launch.StateDirectory);
            // Create and reset the recovery event before publishing "starting" so
            // any RecoverActive() signal during banner recovery is preserved.
            recovery = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.ManualReset, eventName);
            recovery.Reset();
            Status("starting", 0);
            RestoreBanners();
            showCallback = OnTaskbarShow; // Root the delegate for the entire hook lifetime.
            showHook = new TaskbarHookBinding(
                delegate(uint owner) { return Native.HookShows(owner, showCallback); },
                Native.UnhookShows);
            showHandler = new TaskbarShowHandler(showPolicy, Native.EventTaskbar,
                delegate(Bar bar) { if (invisible) Reconcile(bar); }, Native.HideObserved, Native.Record);
            saved = isolatedTest ? new Snapshot() : Native.Capture();
            string adoptedBaseline = isolatedTest ? null : AdoptUncleanBaseline(saved);
            adoptedUncleanBaseline = adoptedBaseline != null;
            regions = new RegionSuppression(saved, Native.CaptureRegion, delegate(SavedRegion ignored) { SaveSnapshot(); },
                Native.ApplyEmptyRegion, Native.RestoreRegion);
            // Durable before the first native change, usable if this helper is
            // killed. Tick retries it until it succeeds; nothing starts before.
            startup = new StartupPersistence(delegate {
                SaveSnapshot();
                RetireBaseline(adoptedBaseline);
                if (hide) Native.SuppressSecondaryTaskbars(saved, SaveSnapshot);
            }, LogPersistFailure, 60);
            Native.RecordAction = delegate(TaskbarAction action) {
                SupervisorSafety.Log(delegate {
                    File.AppendAllText(Path.Combine(launch.StateDirectory, "taskbar-actions.jsonl"),
                        json.Serialize(action) + Environment.NewLine);
                });
            };
            // A hidden top-level window receives Explorer's broadcast. A
            // message-only HWND would not receive TaskbarCreated.
            CreateHandle(new CreateParams { Caption = "Caelestia desktop watchdog", Style = unchecked((int)0x80000000) });
            timer.Interval = 250;
            timer.Tick += Tick;
            timer.Start();
            nextStart = DateTime.UtcNow;
        }
        // A hard-killed supervisor never restored the desktop, so the current
        // state (for example a hidden taskbar) is not the user's original. Reuse
        // the newest unrestored sibling snapshot as this run's baseline.
        string AdoptUncleanBaseline(Snapshot target) {
            try {
                var parent = Path.GetDirectoryName(launch.StateDirectory.TrimEnd('\\'));
                string own = Path.GetFileName(launch.StateDirectory.TrimEnd('\\'));
                if (parent == null || !Directory.Exists(parent)) return null;
                string best = null; DateTime bestTime = DateTime.MinValue;
                foreach (var dir in Directory.GetDirectories(parent, "supervisor-*")) {
                    if (String.Equals(Path.GetFileName(dir), own, StringComparison.OrdinalIgnoreCase)) continue;
                    var file = Path.Combine(dir, "desktop-before.json");
                    if (!File.Exists(file) || SupervisorAlive(Path.Combine(dir, "watchdog.json"))) continue;
                    var time = File.GetLastWriteTimeUtc(file);
                    if (time > bestTime) { best = file; bestTime = time; }
                }
                if (best == null) return null;
                var prior = json.Deserialize<Snapshot>(File.ReadAllText(best));
                if (prior == null) return null;
                target.TaskbarFlags = prior.TaskbarFlags;
                target.TaskbarFlagsSaved = prior.TaskbarFlagsSaved;
                target.MultiMonitorTaskbarSaved = prior.MultiMonitorTaskbarSaved;
                target.MultiMonitorTaskbar = prior.MultiMonitorTaskbar;
                if (prior.Displays != null && prior.Displays.Count != 0) target.Displays = prior.Displays;
                if (prior.Bars != null && prior.Bars.Count != 0) target.Bars = prior.Bars;
                if (prior.Regions != null) target.Regions = prior.Regions;
                return best;
            } catch (Exception error) {
                if (!(error is IOException || error is UnauthorizedAccessException || error is ArgumentException
                    || error is InvalidOperationException)) throw;
                return null;
            }
        }
        // True while the recorded watchdog is still running, or finished cleanly.
        static bool SupervisorAlive(string statusPath) {
            try {
                if (!File.Exists(statusPath)) return false;
                var status = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(statusPath));
                object phase;
                if (status.TryGetValue("phase", out phase) && phase != null) {
                    var name = phase.ToString();
                    if (name == "clean-exit" || name == "recovered" || name == "crash-give-up" || name == "watchdog-error") return true;
                }
                object pid;
                if (!status.TryGetValue("watchdogPid", out pid)) return false;
                using (var process = Process.GetProcessById(Convert.ToInt32(pid))) {
                    if (process.HasExited) return false;
                    var procName = process.ProcessName ?? "";
                    if (!String.Equals(procName, "powershell", StringComparison.OrdinalIgnoreCase)
                        && !String.Equals(procName, "pwsh", StringComparison.OrdinalIgnoreCase)) return false;
                    object utc;
                    if (status.TryGetValue("utc", out utc) && utc != null) {
                        DateTimeOffset recorded;
                        if (DateTimeOffset.TryParse(utc.ToString(), out recorded)) {
                            try {
                                if (process.StartTime.ToUniversalTime() > recorded.UtcDateTime.AddSeconds(5)) return false;
                            } catch (System.ComponentModel.Win32Exception) { }
                        }
                    }
                    return true;
                }
            } catch (ArgumentException) { return false; }
              catch (InvalidOperationException) { return false; }
              // A reused PID owned by a protected or elevated process denies
              // access; our own watchdog never would, so it is not alive.
              catch (System.ComponentModel.Win32Exception) { return false; }
              catch (IOException) { return true; }
        }
        // The adopted snapshot now lives in this run's journal; retire the old
        // one so a later run cannot mistake it for a still-unrestored baseline.
        static void RetireBaseline(string path) {
            if (path == null) return;
            SupervisorSafety.Log(delegate { File.Move(path, path + ".adopted"); });
        }
        void SaveSnapshot() {
            Native.SaveSnapshot(Path.Combine(launch.StateDirectory, "desktop-before.json"), saved);
        }
        // Banner recovery must never stop the shell from starting, restarting
        // or restoring the desktop. A failure keeps the journal for the next try.
        void RestoreBanners() {
            try { RunBannerRecovery(); }
            catch (Exception error) {
                SupervisorSafety.Log(() => File.AppendAllText(Path.Combine(launch.StateDirectory, "banner-recovery.log"),
                    DateTime.UtcNow.ToString("o") + " " + error.Message + Environment.NewLine));
            }
        }
        void RunBannerRecovery() {
            string state;
            if (launch.Environment == null || !launch.Environment.TryGetValue("CAELESTIA_STATE_DIR", out state)
                || String.IsNullOrEmpty(state)) return;
            // Most sessions never suppress banners. Avoid spawning PowerShell
            // on every launch, crash and quit when there is nothing to restore.
            if (!File.Exists(Path.Combine(state, "banner-suppression.json"))) return;
            string helper = Path.Combine(Path.GetDirectoryName(launch.Executable), "Banner-Suppression.ps1");
            if (!File.Exists(helper)) {
                if (File.Exists(Path.Combine(state, "banner-suppression.json")))
                    throw new InvalidOperationException("Banner recovery helper is missing: " + helper);
                return;
            }
            var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                "-NoProfile -File \"" + helper + "\" -StateDirectory \"" + state + "\" -Command Restore") {
                WorkingDirectory = launch.WorkingDirectory,
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true
            };
            var errors = new StringBuilder();
            using (var recoveryProcess = Process.Start(info)) {
                recoveryProcess.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                    if (e.Data != null) lock (errors) {
                        // Diagnostics are best effort and must remain bounded.
                        if (errors.Length < 8192) errors.AppendLine(e.Data);
                    }
                };
                recoveryProcess.BeginErrorReadLine();
                if (!recoveryProcess.WaitForExit(45000)) {
                    recoveryProcess.Kill();
                    throw new InvalidOperationException("Banner recovery timed out; the journal was retained.");
                }
                if (recoveryProcess.ExitCode != 0)
                    lock (errors) throw new InvalidOperationException("Banner recovery failed: " + errors.ToString());
            }
        }
        // A snapshot that still cannot be written after retries leaves that
        // bar untouched (persist precedes apply). Keep the shell running and
        // retry on the next tick instead of ending the session.
        void Reconcile(Bar bar) {
            try { regions.Reconcile(bar); }
            catch (Exception error) {
                if (!(error is IOException || error is UnauthorizedAccessException)) throw;
                LogPersistFailure(error);
            }
        }
        void LogPersistFailure(Exception error) {
            if (DateTime.UtcNow < nextPersistLog) return; // at most one log line a minute
            nextPersistLog = DateTime.UtcNow.AddMinutes(1);
            SupervisorSafety.Log(delegate {
                File.AppendAllText(Path.Combine(launch.StateDirectory, "watchdog-error.log"),
                    "snapshot persist failed, will retry: " + error + Environment.NewLine);
            });
        }
        void SuppressRegions() {
            if (invisible) foreach (var bar in Native.Taskbars()) Reconcile(bar);
        }
        void MaintainTaskbars(bool recordUnchanged) {
            RefreshShowHook(false);
            Native.Hide(recordUnchanged);
            SuppressRegions();
            nextTaskbarAudit = DateTime.UtcNow.AddSeconds(5);
        }
        protected override void WndProc(ref Message message) {
            // WM_SETTINGCHANGE and WM_DISPLAYCHANGE also cover work-area,
            // taskbar preference and monitor topology changes.
            if ((message.Msg == taskbarCreated || message.Msg == 0x001A || message.Msg == 0x007E)
                && child != null && !child.HasExited && hide) {
                // Quickshell's tray hook also sends TaskbarCreated to re-announce
                // icons. Rebind only when Explorer's process actually changed.
                try {
                    MaintainTaskbars(true);
                } catch (Exception error) {
                    Fail(error, "");
                }
            }
            base.WndProc(ref message);
        }
        void RefreshShowHook(bool force) {
            uint owner = Native.ExplorerTaskbarOwner();
            uint previous = showHook.Owner;
            showHook.Refresh(owner, force);
            if (previous != showHook.Owner) showPolicy.Reset();
            if (showHook.Owner != 0 && (force || previous != showHook.Owner)) {
                LogHook("hook-installed", showHook.Owner);
                lastHookFailure = 0;
            } else if (owner != 0 && showHook.Owner == 0 && owner != lastHookFailure) {
                LogHook("hook-failed", owner);
                lastHookFailure = owner;
            } else if (owner == 0) lastHookFailure = 0;
        }
        void LogHook(string operation, uint owner) {
            Native.Record(new TaskbarAction { Operation = operation, Source = "event", Owner = owner,
                Utc = DateTime.UtcNow.ToString("o"), MonotonicTicks = Stopwatch.GetTimestamp(),
                TickFrequency = Stopwatch.Frequency });
        }
        void OnTaskbarShow(IntPtr hook, uint eventType, IntPtr window, int objectId,
            int childId, uint thread, uint eventTime) {
            // This is the callback-delivery timestamp, not the actual show time.
            long ticks = Stopwatch.GetTimestamp();
            try {
                if (done || !hide || child == null || child.HasExited || !showHook.Matches(hook)) return;
                showHandler.Handle(showHook.Owner, window, objectId, childId, ticks);
            } catch (Exception error) {
                // Do not let a persistence failure escape an unmanaged callback
                // or leave a partially suppressed desktop running.
                Fail(error, "WinEvent: ");
            }
        }
        void Fail(Exception error, string prefix) {
            SupervisorSafety.Fail(delegate {
                File.AppendAllText(Path.Combine(launch.StateDirectory, "watchdog-error.log"),
                    prefix + error + Environment.NewLine);
            }, delegate { Finish("watchdog-error", 1); });
        }
        void Status(string phase, int pid) {
            statusPhase = phase;
            statusPid = pid;
            SupervisorSafety.Log(delegate {
                var path = Path.Combine(launch.StateDirectory, "watchdog.json");
                var text = json.Serialize(new { phase = phase, shellPid = pid, watchdogPid = Process.GetCurrentProcess().Id,
                    quickCrashes = quickCrashes, hideTaskbar = hide, restartOnCrash = restart, exitCode = ExitCode,
                    forcedChildTermination = forcedChildTermination,
                    // Tells Start this owner refreshes utc while alive. Older
                    // supervisors wrote it once, so staleness says nothing there.
                    heartbeat = true,
                    utc = DateTime.UtcNow.ToString("o") });
                File.WriteAllText(path + ".tmp", text);
                if (File.Exists(path)) File.Replace(path + ".tmp", path, null);
                else File.Move(path + ".tmp", path);
            });
        }
        void Start() {
            // Child-exit recovery returned Explorer's secondary-taskbar setting
            // too. Reapply the existing takeover setting on every restart.
            if (hide) Native.SuppressSecondaryTaskbars(saved, SaveSnapshot);
            var info = new ProcessStartInfo(launch.Executable, launch.Arguments) {
                WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true
            };
            foreach (var entry in launch.Environment) info.EnvironmentVariables[entry.Key] = entry.Value;
            info.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
            info.EnvironmentVariables.Remove("ELECTRON_NO_ASAR");
            // Only this supervisor decides these child switches, and only one
            // keyboard hook filters taskbar shortcuts: the shell's own.
            LaunchEnvironment.Apply(info.EnvironmentVariables, hide);
            info.RedirectStandardOutput = !String.IsNullOrEmpty(launch.StdoutPath);
            info.RedirectStandardError = !String.IsNullOrEmpty(launch.StderrPath);
            var process = new Process { StartInfo = info };
            var drain = new LogDrain(info.RedirectStandardOutput, info.RedirectStandardError);
            if (info.RedirectStandardOutput)
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                    if (e.Data == null) drain.EndStream();
                    else { if (testLogDelayMs > 0) Thread.Sleep(testLogDelayMs); Append(launch.StdoutPath, e.Data, drain); }
                };
            if (info.RedirectStandardError)
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                    if (e.Data == null) drain.EndStream();
                    else { if (testLogDelayMs > 0) Thread.Sleep(testLogDelayMs); Append(launch.StderrPath, e.Data, drain); }
                };
            // Snapshot is durable and the supervisor owns restoration before
            // the child can register its AppBars. Retain the post-start pass.
            if (hide) MaintainTaskbars(true);
            process.Start();
            child = process;
            childDrain = drain;
            drainDeadline = 0;
            ownedPid = child.Id;
            if (rescueOwners != null) rescueOwners.Add(child.Id);
            if (info.RedirectStandardOutput) child.BeginOutputReadLine();
            if (info.RedirectStandardError) child.BeginErrorReadLine();
            started = DateTime.UtcNow;
            if (hide) MaintainTaskbars(true);
            Status("running", child.Id);
        }
        static readonly object logLock = new object();
        static void Append(string path, string line, LogDrain drain) {
            SupervisorSafety.Log(delegate { lock (logLock) { if (!drain.Retired) File.AppendAllText(path, line + Environment.NewLine); } });
        }
        static void Retire(LogDrain drain) { lock (logLock) drain.Retired = true; }
        void Tick(object sender, EventArgs args) {
            try {
                // Refresh even during intentional backoff and snapshot retries.
                // Once a second is enough for Start's stale-owner check and
                // keeps the status file from being rewritten on every tick.
                if (DateTime.UtcNow >= nextHeartbeat) {
                    nextHeartbeat = DateTime.UtcNow.AddSeconds(1);
                    Status(statusPhase, statusPid);
                }
                if (!recovering && recovery.WaitOne(0)) {
                    recovering = true;
                    stopDeadline = Stopwatch.GetTimestamp() + ChildExitGraceMs * Stopwatch.Frequency / 1000;
                }
                if (child == null) {
                    if (recovering) { Finish("recovered", 0); return; }
                    if (DateTime.UtcNow < nextStart) return;
                    if (startup.Ready()) Start();
                    else nextStart = DateTime.UtcNow.AddSeconds(1); // locked snapshot: retry, no takeover
                    return;
                }
                if (!child.HasExited) {
                    if (recovering) {
                        if (!forcedChildTermination && Stopwatch.GetTimestamp() >= stopDeadline) {
                            // Use the retained Process, never a name/PID lookup.
                            child.Kill();
                            forcedChildTermination = true;
                            BeginDrain();
                            SupervisorSafety.Log(delegate {
                                File.AppendAllText(Path.Combine(launch.StateDirectory, "watchdog-error.log"),
                                    "forced child termination after requested stop grace expired" + Environment.NewLine);
                            });
                        }
                        if (forcedChildTermination && Stopwatch.GetTimestamp() >= drainDeadline) Finish("recovered", 0);
                        return;
                    }
                    // The show hook handles re-shows immediately. Audit only
                    // every five seconds unless its existing fight-loop policy
                    // explicitly falls back to polling for five seconds.
                    if (hide && (DateTime.UtcNow >= nextTaskbarAudit
                        || showPolicy.PollingRequired(Stopwatch.GetTimestamp())))
                        MaintainTaskbars(false);
                    if (!isolatedTest && DateTime.UtcNow >= nextExplorerRetry) {
                        nextExplorerRetry = DateTime.UtcNow.AddSeconds(1);
                        if (Native.CaptureMissingTaskbarFlags(saved)) {
                            try { SaveSnapshot(); }
                            catch (Exception error) {
                                if (!(error is IOException || error is UnauthorizedAccessException)) throw;
                                saved.TaskbarFlagsSaved = false;
                                LogPersistFailure(error);
                            }
                        }
                        Native.RetryStaleAppBars();
                    }
                    return;
                }
                showHook.Dispose();
                showPolicy.Reset();
                BeginDrain();
                // Keep pumping the UI and recovery event while waiting for
                // both EOF callbacks, but never wait beyond the shared deadline.
                if (!childDrain.Complete && Stopwatch.GetTimestamp() < drainDeadline) return;
                if (recovering) { Finish("recovered", 0); return; }
                int code = child.ExitCode;
                // Past EOF or the deadline: drop any stalled tail so it cannot
                // interleave with a restarted child's log.
                Retire(childDrain);
                child.Dispose(); child = null;
                childDrain = null;
                Status("restoring", 0);
                // Decide the outcome first, so the desktop work matches it and
                // always precedes a potentially slow banner replay.
                if (code != 0) quickCrashes = (DateTime.UtcNow - started).TotalSeconds < 30 ? quickCrashes + 1 : 0;
                bool terminal = code == 0 || !restart || quickCrashes >= 3;
                int delay = terminal ? 0 : RestartPolicy.DelaySeconds(quickCrashes);
                try {
                    // The shell is not coming back: return the whole desktop.
                    if (terminal) RestoreDesktop();
                    // A restart follows. Release the dead shell's AppBars, and
                    // show the taskbar only while backing off. An immediate
                    // restart keeps it hidden and leaves parked windows to the
                    // new shell, so one crash does not flash the taskbar.
                    else if (!isolatedTest) Native.RestoreOwned(saved, ownedPid, launch.RestoreWorkAreas, delay != 0 && hide);
                } finally { RestoreBanners(); }
                if (terminal) {
                    childCleanupComplete = true;
                    Finish(code == 0 ? "clean-exit" : "crash-give-up", code);
                    return;
                }
                nextStart = DateTime.UtcNow.AddSeconds(delay);
                Status("restart-backoff", 0);
                // Start in this tick rather than spending another 250 ms with
                // no shell. The supervisor keeps ownership during this retry.
                if (delay == 0) Start();
            } catch (Exception error) {
                Fail(error, "");
            }
        }
        void BeginDrain() {
            if (drainDeadline == 0) drainDeadline = Stopwatch.GetTimestamp() + 2 * Stopwatch.Frequency;
        }
        void Finish(string phase, int code) {
            ExitCode = code;
            Status("restoring", 0);
            try { Dispose(); }
            catch (Exception error) {
                ExitCode = 1;
                SupervisorSafety.Log(delegate {
                    File.AppendAllText(Path.Combine(launch.StateDirectory, "watchdog-error.log"),
                        "Cleanup: " + error + Environment.NewLine);
                });
            }
            finally {
                // Keep the journal eligible for adoption if Explorer could not
                // restore yet. Quit still releases ownership and stops the child.
                try { Status(!isolatedTest && Native.ExplorerWorkDeferred ? "restore-pending" : phase, 0); }
                finally { Application.ExitThread(); }
            }
        }
        bool OwnsRescuedWindow(int pid) { return rescueOwners.Contains(pid); }
        void RestoreDesktop() {
            try { if (!isolatedTest) Native.RestoreOwned(saved, ownedPid, launch.RestoreWorkAreas, hide || adoptedUncleanBaseline); }
            // No shell is left to run TilingManager::rescueParked, so the
            // windows it parked must come back before banner recovery.
            finally { Native.RescueParkedWindows(tilerMutex, rescueFilter); }
        }
        public void Dispose() {
            if (done) return;
            done = true;
            timer.Stop(); timer.Dispose();
            showHook.Dispose();
            // On helper failure do not leave an unsupervised shell reserving
            // space. Normal clean exit reaches here after qs has exited.
            try {
                if (child != null) {
                    if (!child.HasExited) { child.Kill(); child.WaitForExit(1000); }
                    child.Dispose(); child = null;
                }
            } finally {
                try {
                    if (!childCleanupComplete) {
                        try { RestoreDesktop(); }
                        finally { RestoreBanners(); }
                    }
                } finally {
                    Native.RecordAction = null;
                    recovery.Dispose();
                    DestroyHandle();
                }
            }
        }
    }
}
