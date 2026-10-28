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
        bool durable;
        public StartupPersistence(Action persist, Action<Exception> report) {
            this.persist = persist; this.report = report;
        }
        public bool Ready() {
            if (durable) return true;
            try { persist(); durable = true; }
            catch (Exception error) {
                if (!(error is IOException || error is UnauthorizedAccessException)) throw;
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
    // Explorer taskbar shortcuts that would reveal or focus a hidden taskbar.
    // Matching is exact: a chord with an extra modifier is left alone, so
    // unrelated Win chords (Win+A, Win+N, Win+L, a lone Win tap) keep working.
    public static class TaskbarShortcutPolicy {
        public static bool IsDigit(int vk) { return vk >= 0x30 && vk <= 0x39; }
        public static bool IsWin(int vk) { return vk == 0x5B || vk == 0x5C; }
        public static bool Matches(int vk, bool shift, bool ctrl, bool alt, bool win) {
            if (!win) return false;
            switch (vk) {
            case 0x54: // T: Win+T cycles, Win+Shift+T cycles backward.
                return !ctrl && !alt;
            case 0x42: // B: set focus to the first notification-area icon.
                return !shift && !ctrl && !alt;
            case 0x0D: // Enter: Win+Alt+Enter opens taskbar settings.
                return alt && !shift && !ctrl;
            }
            if (!IsDigit(vk)) return false;
            if (alt) return !shift && !ctrl; // Win+Alt+digit opens a jump list.
            // Win+digit, Win+Shift+digit and Win+Ctrl+digit. Microsoft also
            // documents Win+Ctrl+Shift+digit (launch as administrator), but it
            // is outside this task's exact-modifier set and is left alone.
            return !(shift && ctrl);
        }
    }
    // Tracks swallowed key-downs so their matching key-up is consumed, and
    // masks the Win release after a consumed chord. The mask tap and the
    // replayed Win-up are injected before the physical Win-up is swallowed.
    // 256 bits, no hook allocation.
    public sealed class TaskbarShortcutFilter {
        readonly ulong[] down = new ulong[4];
        readonly Func<int, uint, bool, uint> injectMaskedRelease;
        bool maskPending;
        bool leftWinDown, rightWinDown;
        public bool MaskPending { get { return maskPending; } }
        public TaskbarShortcutFilter(Func<int, uint, bool, uint> injectMaskedRelease) {
            this.injectMaskedRelease = injectMaskedRelease;
        }
        public bool Handle(int vk, bool up, bool injected, ulong injectionMarker,
            bool shift, bool ctrl, bool alt, bool win, bool otherWinDown,
            uint scanCode, bool extended) {
            if (vk < 0 || vk > 255) return false;
            // Our own mask/replay and the shell's injected events carry this
            // signature. Everything else, including remapped chords, is
            // eligible for suppression. qs.exe uses the same mask key and
            // signature, so the two hooks recognize each other's injections.
            if (injected && injectionMarker == Native.InjectionMarker) {
                // Keep Win tracking aligned when a marker replay is the only
                // Win-up this hook sees.
                if (up && TaskbarShortcutPolicy.IsWin(vk)) {
                    if (vk == Native.VkLWin) leftWinDown = false;
                    else rightWinDown = false;
                }
                return false;
            }
            if (up) {
                if (TaskbarShortcutPolicy.IsWin(vk)) {
                    if (vk == Native.VkLWin) leftWinDown = false;
                    else rightWinDown = false;
                    if (!maskPending || otherWinDown) return false;
                    maskPending = false;
                    return injectMaskedRelease(vk, scanCode, extended) == 3;
                }
                int index = vk >> 6;
                ulong bit = 1UL << (vk & 63);
                if ((down[index] & bit) == 0) return false;
                down[index] &= ~bit;
                return true;
            }
            if (TaskbarShortcutPolicy.IsWin(vk)) {
                bool repeat = vk == Native.VkLWin ? leftWinDown : rightWinDown;
                if (repeat) return false;
                // A new Win while the other side is still held continues the
                // same sequence. A new sequence after a lost Win-up starts
                // clean.
                if (maskPending && !otherWinDown) maskPending = false;
                if (vk == Native.VkLWin) leftWinDown = true;
                else rightWinDown = true;
                return false;
            }
            int downIndex = vk >> 6;
            ulong downBit = 1UL << (vk & 63);
            if ((down[downIndex] & downBit) != 0) return true; // Auto-repeat.
            if (!TaskbarShortcutPolicy.Matches(vk, shift, ctrl, alt, win)) return false;
            down[downIndex] |= downBit;
            maskPending = true;
            return true;
        }
        public void Reset() {
            Array.Clear(down, 0, down.Length);
            maskPending = false;
            leftWinDown = rightWinDown = false;
        }
    }
    // Owns a dedicated message-loop thread. The thread does nothing but pump
    // hook callbacks; disk I/O and supervisor work stay on the UI thread. The
    // hook is installed before the shell child starts so the shell's later
    // hook remains first in the chain. Only volatile lifecycle and activation
    // flags cross threads. The supervisor reports results after the handshake;
    // the hook thread never logs or waits on supervisor work.
    public sealed class TaskbarShortcutHook : IDisposable {
        readonly Func<Native.LowLevelKeyboardProc, IntPtr> install;
        readonly Action<IntPtr> remove;
        readonly Action<string> report;
        readonly int timeoutMilliseconds;
        readonly TaskbarShortcutFilter filter;
        readonly Native.LowLevelKeyboardProc callback;
        readonly ManualResetEvent ready = new ManualResetEvent(false);
        Thread thread;
        volatile bool active;
        volatile bool installed;
        volatile bool resetRequested;
        volatile bool cancel;
        volatile int threadId;
        bool disposed;
        public bool Installed { get { return installed; } }
        public bool Active { get { return active; } }
        public bool Running { get { Thread value = thread; return value != null && value.IsAlive; } }
        public TaskbarShortcutHook(Func<Native.LowLevelKeyboardProc, IntPtr> install, Action<IntPtr> remove,
            Func<int, uint, bool, uint> injectMaskedRelease, Action<string> report)
            : this(install, remove, injectMaskedRelease, report, 5000) {}
        public TaskbarShortcutHook(Func<Native.LowLevelKeyboardProc, IntPtr> install, Action<IntPtr> remove,
            Func<int, uint, bool, uint> injectMaskedRelease, Action<string> report, int timeoutMilliseconds) {
            this.install = install;
            this.remove = remove;
            this.report = report;
            this.timeoutMilliseconds = timeoutMilliseconds;
            filter = new TaskbarShortcutFilter(injectMaskedRelease);
            callback = OnKeyboard; // Root the delegate for the hook lifetime.
        }
        public bool EnsureStarted() {
            if (disposed) return false;
            if (installed && Running) return true;
            if (thread != null) Stop();
            ready.Reset();
            cancel = false;
            threadId = 0;
            thread = new Thread(ThreadMain);
            thread.IsBackground = true;
            thread.Name = "Caelestia taskbar shortcut hook";
            thread.Start();
            // Do not let the shell start before the install attempt: a later
            // install would put this hook ahead of the shell's hook.
            if (!ready.WaitOne(timeoutMilliseconds)) {
                // An in-flight native install cannot be interrupted safely.
                // Cancel, then join before starting the child, even if the
                // install itself takes longer than the startup timeout.
                Stop();
                report("shortcut-hook-timeout");
                return false;
            }
            bool success = installed;
            if (!success) Stop();
            report(success ? "shortcut-hook-installed" : "shortcut-hook-failed");
            return success;
        }
        public void Activate() { resetRequested = true; active = true; }
        public void Deactivate() { active = false; resetRequested = true; }
        public void Stop() {
            active = false;
            resetRequested = true;
            cancel = true;
            Thread current = thread;
            if (current == null) { installed = false; return; }
            int id = threadId;
            if (id != 0) Native.PostThreadMessage((uint)id, Native.WmQuit, IntPtr.Zero, IntPtr.Zero);
            if (current.IsAlive) current.Join();
            thread = null;
            threadId = 0;
            installed = false;
            filter.Reset();
        }
        void ThreadMain() {
            IntPtr hook = IntPtr.Zero;
            try {
                Native.Msg message;
                Native.PeekMessage(out message, IntPtr.Zero, 0, 0, 0);
                threadId = (int)Native.GetCurrentThreadId();
                if (cancel) return;
                hook = install(callback);
                if (cancel) return;
                installed = hook != IntPtr.Zero;
                ready.Set();
                if (hook == IntPtr.Zero) return;
                while (Native.GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
                    Native.TranslateMessage(ref message);
                    Native.DispatchMessage(ref message);
                }
            } catch (Exception) {
                // No I/O or logging here. The finally reports one failure.
            } finally {
                if (hook != IntPtr.Zero) remove(hook);
                installed = false;
                filter.Reset();
                ready.Set();
            }
        }
        IntPtr OnKeyboard(int code, IntPtr wParam, IntPtr lParam) {
            try {
                if (code < 0) return Native.NextKeyboardHook(code, wParam, lParam);
                int message = wParam.ToInt32();
                if (message != Native.WmKeyDown && message != Native.WmKeyUp &&
                    message != Native.WmSysKeyDown && message != Native.WmSysKeyUp)
                    return Native.NextKeyboardHook(code, wParam, lParam);
                // Keep this callback free of I/O, locks and supervisor work.
                var info = (Native.KbdLlHookStruct)Marshal.PtrToStructure(lParam, typeof(Native.KbdLlHookStruct));
                if (!active) return Native.NextKeyboardHook(code, wParam, lParam);
                if (resetRequested) {
                    filter.Reset();
                    resetRequested = false;
                }
                bool up = message == Native.WmKeyUp || message == Native.WmSysKeyUp;
                bool shift = !up && Native.KeyDown(Native.VkShift);
                bool ctrl = !up && Native.KeyDown(Native.VkControl);
                bool alt = !up && Native.KeyDown(Native.VkMenu);
                bool win = !up && (Native.KeyDown(Native.VkLWin) || Native.KeyDown(Native.VkRWin));
                int other = Native.OtherSide((int)info.VirtualKey);
                bool otherWin = other != 0 && Native.KeyDown(other);
                if (filter.Handle((int)info.VirtualKey, up, (info.Flags & Native.LlkhfInjected) != 0,
                    info.ExtraInfo.ToUInt64(), shift, ctrl, alt, win, otherWin,
                    info.ScanCode, (info.Flags & Native.LlkhfExtended) != 0))
                    return new IntPtr(1);
                return Native.NextKeyboardHook(code, wParam, lParam);
            } catch (Exception) {
                // Never throw out of an unmanaged hook callback.
                return Native.NextKeyboardHook(code, wParam, lParam);
            }
        }
        public void Dispose() {
            if (disposed) return;
            Stop();
            disposed = true;
            ready.Close();
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
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string name, string title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string name, string title);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint parameter, ref Rect rect, uint flags);
        [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint message, ref AppBarData data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string message);
        [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
        [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr window, IntPtr update, IntPtr region, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr window, uint message,
            UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);

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
        public delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);
        [StructLayout(LayoutKind.Sequential)]
        public struct KbdLlHookStruct {
            public uint VirtualKey, ScanCode, Flags, Time;
            public UIntPtr ExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct MouseInput {
            public int Dx, Dy;
            public uint MouseData, Flags, Time;
            public UIntPtr ExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct KeyboardInput {
            public ushort VirtualKey, ScanCode;
            public uint Flags, Time;
            public UIntPtr ExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct HardwareInput {
            public uint Message;
            public ushort ParamL, ParamH;
        }
        [StructLayout(LayoutKind.Explicit)]
        struct InputUnion {
            [FieldOffset(0)] public MouseInput Mouse;
            [FieldOffset(0)] public KeyboardInput Keyboard;
            [FieldOffset(0)] public HardwareInput Hardware;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Input {
            public uint Type;
            public InputUnion Data;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct Msg {
            public IntPtr Window;
            public uint Message;
            public UIntPtr WParam;
            public IntPtr LParam;
            public uint Time;
            public int X, Y;
            public uint Private;
        }
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc callback, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError = true)] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll")] public static extern bool PeekMessage(out Msg message, IntPtr window, uint filterMin, uint filterMax, uint remove);
        [DllImport("user32.dll")] public static extern int GetMessage(out Msg message, IntPtr window, uint filterMin, uint filterMax);
        [DllImport("user32.dll")] public static extern bool TranslateMessage(ref Msg message);
        [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref Msg message);
        public const int WhKeyboardLl = 13;
        public const int WmKeyDown = 0x0100, WmKeyUp = 0x0101, WmSysKeyDown = 0x0104, WmSysKeyUp = 0x0105;
        public const uint WmQuit = 0x0012;
        public const int VkShift = 0x10, VkControl = 0x11, VkMenu = 0x12, VkLWin = 0x5B, VkRWin = 0x5C;
        public const uint LlkhfInjected = 0x10;
        public const uint LlkhfExtended = 0x01;
        public const byte MaskKey = 0xE8; // Same unassigned VK qs.exe masks with.
        public const uint InjectionMarker = 0x5153484B; // qs.exe INJECTION_MARKER.
        const uint InputKeyboard = 1, KeyeventfExtendedKey = 0x0001, KeyeventfKeyUp = 0x0002;
        public static IntPtr InstallKeyboardHook(LowLevelKeyboardProc callback) {
            return SetWindowsHookEx(WhKeyboardLl, callback, GetModuleHandle(null), 0);
        }
        public static void RemoveKeyboardHook(IntPtr hook) {
            if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        }
        public static IntPtr NextKeyboardHook(int code, IntPtr wParam, IntPtr lParam) {
            return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        }
        public static bool KeyDown(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }
        public static int OtherSide(int vk) {
            if (vk == VkLWin) return VkRWin;
            if (vk == VkRWin) return VkLWin;
            return 0;
        }
        static Input KeyInput(int vk, bool up, uint scanCode, bool extended) {
            var input = new Input();
            input.Type = InputKeyboard;
            input.Data.Keyboard = new KeyboardInput {
                VirtualKey = (ushort)vk,
                ScanCode = (ushort)scanCode,
                Flags = (up ? KeyeventfKeyUp : 0u) | (extended ? KeyeventfExtendedKey : 0u),
                ExtraInfo = new UIntPtr(InjectionMarker)
            };
            return input;
        }
        public static uint InjectMaskedRelease(int vk, uint scanCode, bool extended) {
            var inputs = new Input[3];
            inputs[0] = KeyInput(MaskKey, false, 0, false);
            inputs[1] = KeyInput(MaskKey, true, 0, false);
            inputs[2] = KeyInput(vk, true, scanCode, extended);
            return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));
        }
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
            return DpiScope.Run(SetThreadDpiAwarenessContext, delegate {
                return RegionCapture.TryCapture(delegate { return CaptureRegionCore(bar); },
                    delegate { return !CurrentTaskbar(bar); });
            });
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
            DpiScope.Run(SetThreadDpiAwarenessContext, delegate {
                ApplyEmptyRegionCore(saved);
                return true;
            });
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
            DpiScope.Run(SetThreadDpiAwarenessContext, delegate {
                RestoreRegionCore(saved);
                return true;
            });
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
        public static uint ExplorerTaskbarOwner() {
            // FindWindow can return Quickshell's tray hook, which shares the
            // Shell_TrayWnd class and moves itself to the front.
            var window = IntPtr.Zero;
            while ((window = FindWindowEx(IntPtr.Zero, window, "Shell_TrayWnd", null)) != IntPtr.Zero) {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (Explorer(owner)) return owner;
            }
            return 0;
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
        static TaskbarAction Visibility(Bar bar, bool visible, string operation, long? showTicks) {
            var window = new IntPtr(bar.Handle);
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (!IsWindow(window) || owner != bar.Owner) return null;
            ShowWindow(window, visible ? 8 : 0); // SW_SHOWNA avoids taking focus
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
                var regionErrors = new List<string>();
                int removed = owner >= 0 ? RemoveStaleAppBars(owner) : 0;
                if (taskbars) {
                    RestoreSecondaryTaskbars(saved);
                    if (saved != null && saved.Regions != null)
                        foreach (var region in saved.Regions) {
                            try { RestoreRegion(region); }
                            catch (Exception error) { regionErrors.Add(region.Handle + ": " + error.Message); }
                        }
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
                RedrawWindow(GetDesktopWindow(), IntPtr.Zero, IntPtr.Zero, 0x181);
                if (regionErrors.Count != 0)
                    throw new InvalidOperationException("Taskbar region restoration failed: " + String.Join("; ", regionErrors.ToArray()));
            } finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
        }
    }

    public sealed class Supervisor : NativeWindow, IDisposable {
        readonly Launch launch;
        readonly bool hide, restart, invisible;
        readonly bool isolatedTest;
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
        readonly TaskbarShortcutHook shortcutHook;
        Process child;
        DateTime started, nextStart;
        int quickCrashes;
        int ownedPid = -1;
        volatile int startGeneration;
        uint lastHookFailure;
        DateTime nextPersistLog;
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
        public static int Run(string specPath, bool hide, bool restart, bool invisible) {
            return RunCore(specPath, hide, restart, invisible, MutexName, EventName, false);
        }
        // Used only by the non-desktop regression harness. Its unique names
        // cannot acquire or signal the real session supervisor.
        public static int RunIsolatedTest(string specPath, string token) {
            Guid parsed;
            if (!Guid.TryParseExact(token, "N", out parsed)) throw new ArgumentException("Invalid test token.");
            string name = @"Local\CaelestiaDesktopTakeover-Test-" + parsed.ToString("N");
            return RunCore(specPath, false, true, false, name, name + "-Recovery", true);
        }
        static int RunCore(string specPath, bool hide, bool restart, bool invisible,
            string mutexName, string eventName, bool isolatedTest) {
            using (var mutex = new System.Threading.Mutex(false, mutexName)) {
                bool acquired;
                try { acquired = mutex.WaitOne(0); }
                catch (System.Threading.AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new InvalidOperationException("A desktop supervisor already owns this Windows session.");
                try {
                    var launch = new JavaScriptSerializer().Deserialize<Launch>(File.ReadAllText(specPath));
                    using (var supervisor = new Supervisor(launch, hide, restart, invisible, eventName, isolatedTest)) {
                        Application.Run();
                        return supervisor.ExitCode;
                    }
                } finally { mutex.ReleaseMutex(); }
            }
        }
        Supervisor(Launch launch, bool hide, bool restart, bool invisible, string eventName, bool isolatedTest) {
            this.launch = launch; this.hide = hide; this.restart = restart; this.invisible = invisible && hide;
            this.isolatedTest = isolatedTest;
            RestoreBanners();
            showCallback = OnTaskbarShow; // Root the delegate for the entire hook lifetime.
            showHook = new TaskbarHookBinding(
                delegate(uint owner) { return Native.HookShows(owner, showCallback); },
                Native.UnhookShows);
            showHandler = new TaskbarShowHandler(showPolicy, Native.EventTaskbar,
                delegate(Bar bar) { if (invisible) Reconcile(bar); }, Native.HideObserved, Native.Record);
            Directory.CreateDirectory(launch.StateDirectory);
            saved = isolatedTest ? new Snapshot() : Native.Capture();
            regions = new RegionSuppression(saved, Native.CaptureRegion, delegate(SavedRegion ignored) { SaveSnapshot(); },
                Native.ApplyEmptyRegion, Native.RestoreRegion);
            // Durable before the first native change, usable if this helper is
            // killed. Tick retries it until it succeeds; nothing starts before.
            startup = new StartupPersistence(delegate {
                SaveSnapshot();
                if (hide) Native.SuppressSecondaryTaskbars(saved, SaveSnapshot);
            }, LogPersistFailure);
            Native.RecordAction = delegate(TaskbarAction action) {
                SupervisorSafety.Log(delegate {
                    File.AppendAllText(Path.Combine(launch.StateDirectory, "taskbar-actions.jsonl"),
                        json.Serialize(action) + Environment.NewLine);
                });
            };
            recovery = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.ManualReset, eventName);
            recovery.Reset();
            // A hidden top-level window receives Explorer's broadcast. A
            // message-only HWND would not receive TaskbarCreated.
            CreateHandle(new CreateParams { Caption = "Caelestia desktop watchdog", Style = unchecked((int)0x80000000) });
            shortcutHook = new TaskbarShortcutHook(Native.InstallKeyboardHook, Native.RemoveKeyboardHook,
                Native.InjectMaskedRelease,
                delegate(string operation) { LogHook(operation, 0); });
            timer.Interval = 250;
            timer.Tick += Tick;
            timer.Start();
            nextStart = DateTime.UtcNow;
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
            string helper = Path.Combine(launch.WorkingDirectory, "Banner-Suppression.ps1");
            if (!File.Exists(helper)) {
                if (File.Exists(Path.Combine(state, "banner-suppression.json")))
                    throw new InvalidOperationException("Banner recovery helper is missing: " + helper);
                return;
            }
            var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                "-NoProfile -File \"" + helper + "\" -StateDirectory \"" + state + "\" -Command Restore") {
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
        protected override void WndProc(ref Message message) {
            if (message.Msg == taskbarCreated && child != null && !child.HasExited && hide) {
                // Quickshell's tray hook also sends TaskbarCreated to re-announce
                // icons. Rebind only when Explorer's process actually changed.
                try {
                    RefreshShowHook(false);
                    SuppressRegions();
                    Native.Hide(true);
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
            SupervisorSafety.Log(delegate {
                var path = Path.Combine(launch.StateDirectory, "watchdog.json");
                var text = json.Serialize(new { phase = phase, shellPid = pid, watchdogPid = Process.GetCurrentProcess().Id,
                    quickCrashes = quickCrashes, hideTaskbar = hide, restartOnCrash = restart, exitCode = ExitCode,
                    utc = DateTime.UtcNow.ToString("o") });
                File.WriteAllText(path + ".tmp", text);
                if (File.Exists(path)) File.Replace(path + ".tmp", path, null);
                else File.Move(path + ".tmp", path);
            });
        }
        void Start() {
            // Retry only before the shell starts. A later install would put
            // this hook ahead of the shell's hook and reverse the chain order.
            if (hide) shortcutHook.EnsureStarted();
            var info = new ProcessStartInfo(launch.Executable, launch.Arguments) {
                WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true
            };
            foreach (var entry in launch.Environment) info.EnvironmentVariables[entry.Key] = entry.Value;
            info.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
            info.EnvironmentVariables.Remove("ELECTRON_NO_ASAR");
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
            // Snapshot is durable and the supervisor owns restoration before
            // the child can register its AppBars. Retain the post-start pass.
            if (hide) { RefreshShowHook(false); SuppressRegions(); Native.Hide(true); }
            int generation = ++startGeneration;
            // Subscribe before start so a shell that exits immediately still
            // deactivates the shortcut hook. The generation check keeps a
            // stale Exited event from deactivating a later restart.
            process.EnableRaisingEvents = true;
            process.Exited += delegate {
                if (startGeneration == generation) shortcutHook.Deactivate();
            };
            process.Start();
            child = process;
            ownedPid = child.Id;
            if (hide) {
                shortcutHook.Activate();
                if (process.HasExited) shortcutHook.Deactivate();
            }
            if (info.RedirectStandardOutput) child.BeginOutputReadLine();
            if (info.RedirectStandardError) child.BeginErrorReadLine();
            started = DateTime.UtcNow;
            if (hide) { RefreshShowHook(false); SuppressRegions(); Native.Hide(true); }
            Status("running", child.Id);
        }
        static readonly object logLock = new object();
        static void Append(string path, string line) {
            SupervisorSafety.Log(delegate { lock (logLock) { File.AppendAllText(path, line + Environment.NewLine); } });
        }
        void Tick(object sender, EventArgs args) {
            try {
                if (recovery.WaitOne(0)) {
                    if (child != null && !child.HasExited) { child.Kill(); child.WaitForExit(1000); }
                    Finish("recovered", 0);
                    return;
                }
                if (child == null) {
                    if (DateTime.UtcNow < nextStart) return;
                    if (startup.Ready()) Start();
                    else nextStart = DateTime.UtcNow.AddSeconds(1); // locked snapshot: retry, no takeover
                    return;
                }
                if (!child.HasExited) {
                    if (hide) { RefreshShowHook(false); Native.Hide(false); SuppressRegions(); }
                    return;
                }
                showHook.Dispose();
                shortcutHook.Deactivate();
                showPolicy.Reset();
                // Do not use the parameterless WaitForExit here: it also
                // waits for redirected pipe EOF, which a surviving descendant
                // can hold indefinitely. The final log lines are best effort.
                int code = child.ExitCode, pid = child.Id;
                child.Dispose(); child = null;
                RestoreBanners();
                if (code == 0) { Finish("clean-exit", 0); return; }
                quickCrashes = (DateTime.UtcNow - started).TotalSeconds < 30 ? quickCrashes + 1 : 0;
                if (!restart || quickCrashes >= 3) { Finish("crash-give-up", code); return; }
                if (!isolatedTest) Native.RestoreOwned(saved, pid, launch.RestoreWorkAreas, hide);
                nextStart = DateTime.UtcNow.AddSeconds(Math.Min(30, Math.Pow(2, Math.Max(1, quickCrashes))));
                Status("restart-backoff", 0);
            } catch (Exception error) {
                Fail(error, "");
            }
        }
        void Finish(string phase, int code) {
            ExitCode = code;
            try { Dispose(); }
            catch (Exception error) {
                ExitCode = 1;
                SupervisorSafety.Log(delegate {
                    File.AppendAllText(Path.Combine(launch.StateDirectory, "watchdog-error.log"),
                        "Cleanup: " + error + Environment.NewLine);
                });
            }
            finally {
                try { Status(phase, 0); }
                finally { Application.ExitThread(); }
            }
        }
        public void Dispose() {
            if (done) return;
            done = true;
            timer.Stop(); timer.Dispose();
            shortcutHook.Dispose();
            showHook.Dispose();
            // On helper failure do not leave an unsupervised shell reserving
            // space. Normal clean exit reaches here after qs has exited.
            try {
                if (child != null) {
                    if (!child.HasExited) { child.Kill(); child.WaitForExit(1000); }
                    child.Dispose(); child = null;
                }
            } finally {
                try { RestoreBanners(); }
                finally {
                    try { if (!isolatedTest) Native.RestoreOwned(saved, ownedPid, launch.RestoreWorkAreas, hide); }
                    finally {
                        Native.RecordAction = null;
                        recovery.Dispose();
                        DestroyHandle();
                    }
                }
            }
        }
    }
}
