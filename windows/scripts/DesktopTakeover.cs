// Windows-only supervisor. Compiled in the watchdog process, never in qs.exe.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Caelestia.Takeover {
    public sealed class Launch {
        public string Executable, Arguments, WorkingDirectory, ConfigPath, StateDirectory;
        public string StdoutPath, StderrPath, InstallLockKey, PowerShellPath;
        public bool RestartFrozenShell = true;
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
        // One persistent worker owns every serialized call; a timed-out call
        // still occupies the gate until it finishes, exactly like the old
        // per-call thread whose Join returned early.
        readonly object gate = new object();
        readonly AutoResetEvent workReady = new AutoResetEvent(false);
        readonly ManualResetEvent workDone = new ManualResetEvent(false);
        Thread worker;
        Func<object> pending;
        object value;
        Exception failure;
        bool executing;
        public bool Try<T>(Func<T> action, out T result) {
            result = default(T);
            lock (gate) {
                if (pending != null || executing) return false;
                pending = delegate { return action(); };
                failure = null;
                value = null;
                workDone.Reset();
                if (worker == null) {
                    worker = new Thread(Work);
                    worker.IsBackground = true;
                    worker.Start();
                }
            }
            workReady.Set();
            if (!workDone.WaitOne(100)) return false;
            Exception error;
            object outcome;
            lock (gate) {
                error = failure;
                outcome = value;
            }
            if (error != null) throw error;
            result = (T)outcome;
            return true;
        }
        void Work() {
            while (true) {
                workReady.WaitOne();
                Func<object> action;
                lock (gate) {
                    action = pending;
                    pending = null;
                    executing = action != null;
                }
                if (action == null) continue;
                try {
                    object produced = action();
                    lock (gate) { value = produced; }
                } catch (Exception error) {
                    lock (gate) { failure = error; }
                } finally {
                    // Signal inside the gate: a caller that observes
                    // executing == false must never still see this call's
                    // completion event.
                    lock (gate) { executing = false; workDone.Set(); }
                }
            }
        }
    }
    // Same 100 ms caller budget as AppBar/region work, with one owned worker.
    // Coalesce requests, but replay after an in-flight send so restore cannot
    // lose its notification. The worker never writes registry or snapshot data.
    public sealed class BoundedNotification {
        readonly object gate = new object();
        Thread worker;
        Action pending;
        public void Request(Action notify) {
            Thread current;
            lock (gate) {
                pending = notify;
                if (worker == null) {
                    worker = new Thread(delegate() {
                        while (true) {
                            Action action;
                            lock (gate) {
                                action = pending;
                                pending = null;
                                if (action == null) { worker = null; return; }
                            }
                            // Notification is advisory. The synchronous registry
                            // write remains authoritative even if Explorer exits.
                            try { action(); } catch (Exception) {}
                        }
                    });
                    worker.IsBackground = true;
                    worker.Start();
                }
                current = worker;
            }
            current.Join(100);
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
    // Minimal JSON serializer/deserializer replacing JavaScriptSerializer.
    // Pure BCL (no System.Web.Extensions, no System.Text.Json) so it works
    // identically on .NET Framework 4.8 / PS 5.1 and .NET 8+ / PS 7.x.
    // It reads and writes the exact schema previously produced by
    // JavaScriptSerializer: same property names, same primitive shapes, and a
    // byte[] as a JSON integer array (e.g. [32,0,0,0]).
    public static class TakeoverJson {
        // JavaScriptSerializer defaults: a 2 MiB input bound and a recursion
        // limit so hostile or corrupt JSON cannot exhaust the stack or memory.
        const int MaxJsonLength = 2097152;
        const int MaxDepth = 100;
        public static string Serialize(object value) {
            var builder = new StringBuilder(256);
            WriteValue(builder, value);
            return builder.ToString();
        }
        static void WriteValue(StringBuilder output, object value) {
            if (value == null) { output.Append("null"); return; }
            var type = value.GetType();
            if (type == typeof(string)) { WriteString(output, (string)value); return; }
            if (type == typeof(bool)) { output.Append((bool)value ? "true" : "false"); return; }
            if (type == typeof(byte[])) {
                var bytes = (byte[])value;
                output.Append('[');
                for (int i = 0; i < bytes.Length; i++) {
                    if (i != 0) output.Append(',');
                    output.Append(bytes[i].ToString(CultureInfo.InvariantCulture));
                }
                output.Append(']');
                return;
            }
            if (type.IsPrimitive || type == typeof(decimal)) {
                output.Append(Convert.ToString(value, CultureInfo.InvariantCulture));
                return;
            }
            if (value is System.Collections.IDictionary) {
                output.Append('{');
                bool first = true;
                foreach (System.Collections.DictionaryEntry entry in (System.Collections.IDictionary)value) {
                    if (!first) output.Append(',');
                    first = false;
                    WriteString(output, entry.Key.ToString());
                    output.Append(':');
                    WriteValue(output, entry.Value);
                }
                output.Append('}');
                return;
            }
            if (value is System.Collections.IEnumerable && !(value is string)) {
                output.Append('[');
                bool first = true;
                foreach (var item in (System.Collections.IEnumerable)value) {
                    if (!first) output.Append(',');
                    first = false;
                    WriteValue(output, item);
                }
                output.Append(']');
                return;
            }
            // POCO: serialize public instance fields, then readable public
            // instance properties (covers anonymous status types too), matching
            // JavaScriptSerializer's contract for these data types.
            output.Append('{');
            var fields = type.GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance);
            bool firstField = true;
            foreach (var field in fields) {
                if (!firstField) output.Append(',');
                firstField = false;
                WriteString(output, field.Name);
                output.Append(':');
                WriteValue(output, field.GetValue(value));
            }
            if (fields.Length == 0) {
                foreach (var property in type.GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance)) {
                    if (!property.CanRead || property.GetIndexParameters().Length != 0) continue;
                    if (!firstField) output.Append(',');
                    firstField = false;
                    WriteString(output, property.Name);
                    output.Append(':');
                    WriteValue(output, property.GetValue(value, null));
                }
            }
            output.Append('}');
        }
        static void WriteString(StringBuilder output, string value) {
            output.Append('"');
            foreach (char c in value) {
                switch (c) {
                    case '"': output.Append("\\\""); break;
                    case '\\': output.Append("\\\\"); break;
                    case '\b': output.Append("\\b"); break;
                    case '\f': output.Append("\\f"); break;
                    case '\n': output.Append("\\n"); break;
                    case '\r': output.Append("\\r"); break;
                    case '\t': output.Append("\\t"); break;
                    default:
                        if (c < ' ') output.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else output.Append(c);
                        break;
                }
            }
            output.Append('"');
        }

        // Deserialization ----------------------------------------------------
        public static T Deserialize<T>(string json) where T : new() {
            var value = Parse(json);
            if (value == null)
                throw new InvalidOperationException("Expected a JSON object for " + typeof(T).Name + ", got null.");
            return (T)ConvertTo(value, typeof(T));
        }
        public static object DeserializeObject(string json) { return Parse(json); }
        static object Parse(string json) {
            if (json == null) throw new InvalidOperationException("JSON input is null.");
            if (json.Length > MaxJsonLength) throw new InvalidOperationException("JSON input exceeds the 2 MiB limit.");
            var reader = new Reader(json);
            reader.SkipWhitespace();
            var value = reader.ReadValue();
            reader.SkipWhitespace();
            if (!reader.End) throw new FormatException("Trailing characters after JSON value.");
            return value;
        }
        sealed class Reader {
            readonly string text;
            int position;
            int depth;
            public Reader(string text) { this.text = text ?? ""; }
            public bool End { get { return position >= text.Length; } }
            public void SkipWhitespace() {
                while (position < text.Length && (text[position] == ' ' || text[position] == '\t'
                    || text[position] == '\r' || text[position] == '\n')) position++;
            }
            public object ReadValue() {
                if (position >= text.Length) throw new FormatException("Unexpected end of JSON.");
                char c = text[position];
                if (c == '{') return ReadObject();
                if (c == '[') return ReadArray();
                if (c == '"') return ReadString();
                if (c == 't' || c == 'f') return ReadBool();
                if (c == 'n') { ReadLiteral("null"); return null; }
                if (c == '-' || (c >= '0' && c <= '9')) return ReadNumber();
                throw new FormatException("Unexpected JSON character '" + c + "'.");
            }
            Dictionary<string, object> ReadObject() {
                if (++depth > MaxDepth) throw new InvalidOperationException("JSON recursion limit exceeded.");
                var result = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                position++; // consume {
                SkipWhitespace();
                if (position < text.Length && text[position] == '}') { position++; depth--; return result; }
                while (true) {
                    SkipWhitespace();
                    string key = ReadString();
                    SkipWhitespace();
                    Expect(':');
                    SkipWhitespace();
                    result[key] = ReadValue();
                    SkipWhitespace();
                    if (position < text.Length && text[position] == ',') { position++; continue; }
                    Expect('}');
                    depth--;
                    return result;
                }
            }
            List<object> ReadArray() {
                if (++depth > MaxDepth) throw new InvalidOperationException("JSON recursion limit exceeded.");
                var result = new List<object>();
                position++; // consume [
                SkipWhitespace();
                if (position < text.Length && text[position] == ']') { position++; depth--; return result; }
                while (true) {
                    SkipWhitespace();
                    result.Add(ReadValue());
                    SkipWhitespace();
                    if (position < text.Length && text[position] == ',') { position++; continue; }
                    Expect(']');
                    depth--;
                    return result;
                }
            }
            string ReadString() {
                Expect('"');
                var builder = new StringBuilder();
                while (position < text.Length) {
                    char c = text[position++];
                    if (c == '"') return builder.ToString();
                    if (c != '\\') { builder.Append(c); continue; }
                    if (position >= text.Length) break;
                    char esc = text[position++];
                    switch (esc) {
                        case '"': builder.Append('"'); break;
                        case '\\': builder.Append('\\'); break;
                        case '/': builder.Append('/'); break;
                        case 'b': builder.Append('\b'); break;
                        case 'f': builder.Append('\f'); break;
                        case 'n': builder.Append('\n'); break;
                        case 'r': builder.Append('\r'); break;
                        case 't': builder.Append('\t'); break;
                        case 'u': builder.Append(ReadUnicodeEscape()); break;
                        default: throw new FormatException("Invalid JSON escape \\" + esc + ".");
                    }
                }
                throw new FormatException("Unterminated JSON string.");
            }
            // Returns one UTF-16 code unit, or a surrogate pair combined into
            // a two-character string when the escape names a high surrogate
            // followed by a \uXXXX low surrogate.
            string ReadUnicodeEscape() {
                int code = ReadHex4();
                if (code >= 0xD800 && code <= 0xDBFF && position + 1 < text.Length
                    && text[position] == '\\' && text[position + 1] == 'u') {
                    int low;
                    int save = position;
                    position += 2;
                    try { low = ReadHex4(); }
                    catch (FormatException) { position = save; return new string((char)code, 1); }
                    if (low >= 0xDC00 && low <= 0xDFFF) {
                        var pair = new char[2];
                        pair[0] = (char)code;
                        pair[1] = (char)low;
                        return new string(pair);
                    }
                    position = save;
                }
                return new string((char)code, 1);
            }
            int ReadHex4() {
                if (position + 4 > text.Length) throw new FormatException("Truncated \\u escape.");
                int value = 0;
                for (int i = 0; i < 4; i++) {
                    char c = text[position++];
                    int digit;
                    if (c >= '0' && c <= '9') digit = c - '0';
                    else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
                    else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
                    else throw new FormatException("Invalid \\u escape hex digit.");
                    value = value * 16 + digit;
                }
                return value;
            }
            object ReadBool() {
                if (text[position] == 't') { ReadLiteral("true"); return true; }
                ReadLiteral("false"); return false;
            }
            void ReadLiteral(string literal) {
                if (string.Compare(text, position, literal, 0, literal.Length, StringComparison.Ordinal) != 0)
                    throw new FormatException("Invalid JSON literal.");
                position += literal.Length;
            }
            object ReadNumber() {
                int start = position;
                if (position < text.Length && text[position] == '-') position++;
                while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++;
                bool isDouble = false;
                if (position < text.Length && text[position] == '.') {
                    isDouble = true;
                    position++;
                    while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++;
                }
                if (position < text.Length && (text[position] == 'e' || text[position] == 'E')) {
                    isDouble = true;
                    position++;
                    if (position < text.Length && (text[position] == '+' || text[position] == '-')) position++;
                    while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++;
                }
                var token = text.Substring(start, position - start);
                if (isDouble) return double.Parse(token, CultureInfo.InvariantCulture);
                long integral;
                if (long.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out integral)) {
                    if (integral >= int.MinValue && integral <= int.MaxValue) return (int)integral;
                    return integral;
                }
                // A value that overflows Int64 but fits UInt64 must stay exact.
                // Routing UInt64.MaxValue through double.Parse would round it
                // to a representable neighbor and silently corrupt the restore.
                ulong unsigned;
                if (token[0] != '-' && ulong.TryParse(token, NumberStyles.Integer,
                        CultureInfo.InvariantCulture, out unsigned))
                    return unsigned;
                return double.Parse(token, CultureInfo.InvariantCulture);
            }
            void Expect(char expected) {
                if (position >= text.Length || text[position] != expected)
                    throw new FormatException("Expected '" + expected + "' in JSON.");
                position++;
            }
        }
        static object ConvertTo(object value, Type target) {
            return ConvertTo(value, target, null);
        }
        static object ConvertTo(object value, Type target, System.Reflection.FieldInfo field) {
            if (value == null) {
                if (target.IsValueType && Nullable.GetUnderlyingType(target) == null) {
                    string name = field != null ? field.DeclaringType.Name + "." + field.Name : target.Name;
                    throw new InvalidOperationException("JSON null is not valid for " + name + ".");
                }
                return null;
            }
            if (target == typeof(object)) return value;
            if (target == typeof(string)) {
                var text = value as string;
                if (text != null) return text;
                // SavedRegion.RegionData historically serialized RGNDATA as a
                // base64 string, but tolerate a legacy JSON byte array too.
                // That compatibility is limited to this one field; arbitrary
                // strings never coerce a byte array.
                var items = value as List<object>;
                if (items != null) {
                    if (field != null && field.DeclaringType == typeof(SavedRegion)
                        && field.Name == "RegionData")
                        return Convert.ToBase64String(ReadByteArray(items));
                }
                throw new InvalidOperationException("Expected JSON string for System.String.");
            }
            if (target == typeof(byte[])) {
                if (value is string) return Convert.FromBase64String((string)value);
                var items = value as List<object>;
                if (items == null) throw new InvalidOperationException("Expected JSON string or array for System.Byte[].");
                return ReadByteArray(items);
            }
            var underlying = Nullable.GetUnderlyingType(target);
            if (underlying != null) return ConvertTo(value, underlying, field);
            if (target == typeof(bool)) {
                if (value is bool) return value;
                throw new InvalidOperationException("Expected JSON boolean for System.Boolean.");
            }
            if (target == typeof(int)) return CheckedInt32(Integral(value, target.Name), target.Name);
            if (target == typeof(long)) return Integral(value, target.Name);
            if (target == typeof(uint)) {
                ulong number = UnsignedIntegral(value, target.Name);
                if (number > uint.MaxValue)
                    throw new InvalidOperationException("JSON value out of range for System.UInt32.");
                return (uint)number;
            }
            if (target == typeof(ulong)) {
                return UnsignedIntegral(value, target.Name);
            }
            if (target == typeof(double)) {
                if (value is bool || value is string)
                    throw new InvalidOperationException("Expected a JSON number for System.Double.");
                if (value is int || value is long || value is ulong || value is double)
                    return Convert.ToDouble(value, CultureInfo.InvariantCulture);
                throw new InvalidOperationException("Expected a JSON number for System.Double.");
            }
            if (target.IsGenericType && target.GetGenericTypeDefinition() == typeof(Dictionary<,>)) {
                var source = value as Dictionary<string, object>;
                if (source == null) throw new InvalidOperationException("Expected JSON object for " + target.Name + ".");
                var argument = target.GetGenericArguments()[1];
                var dictionary = (System.Collections.IDictionary)Activator.CreateInstance(target);
                foreach (var pair in source) dictionary[pair.Key] = ConvertTo(pair.Value, argument);
                return dictionary;
            }
            if (target.IsGenericType && target.GetGenericTypeDefinition() == typeof(List<>)) {
                var items = value as List<object>;
                if (items == null) throw new InvalidOperationException("Expected JSON array for " + target.Name + ".");
                var argument = target.GetGenericArguments()[0];
                var list = (System.Collections.IList)Activator.CreateInstance(target);
                foreach (var item in items) list.Add(ConvertTo(item, argument));
                return list;
            }
            if (target.IsArray) {
                var items = value as List<object>;
                if (items == null) throw new InvalidOperationException("Expected JSON array for " + target.Name + ".");
                var element = target.GetElementType();
                var array = Array.CreateInstance(element, items.Count);
                for (int i = 0; i < items.Count; i++) array.SetValue(ConvertTo(items[i], element), i);
                return array;
            }
            // POCO: populate public instance fields case-insensitively,
            // ignoring unknown members.
            var members = value as Dictionary<string, object>;
            if (members == null) throw new InvalidOperationException("Expected JSON object for " + target.Name + ".");
            var result = Activator.CreateInstance(target);
            var fields = target.GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance);
            var lookup = new Dictionary<string, System.Reflection.FieldInfo>(StringComparer.OrdinalIgnoreCase);
            foreach (var declared in fields) lookup[declared.Name] = declared;
            foreach (var pair in members) {
                System.Reflection.FieldInfo member;
                if (!lookup.TryGetValue(pair.Key, out member)) continue;
                member.SetValue(result, ConvertTo(pair.Value, member.FieldType, member));
            }
            return result;
        }
        static long Integral(object value, string targetName) {
            if (value is bool || value is string || value is double)
                throw new InvalidOperationException("Expected an integral JSON number for " + targetName + ".");
            if (value is int) return (int)value;
            if (value is long) return (long)value;
            if (value is ulong) {
                ulong unsigned = (ulong)value;
                if (unsigned > long.MaxValue)
                    throw new InvalidOperationException("JSON value out of range for " + targetName + ".");
                return (long)unsigned;
            }
            throw new InvalidOperationException("Expected an integral JSON number for " + targetName + ".");
        }
        // Non-negative int, long or ulong widened to ulong. Negative values
        // (which would silently wrap) are rejected.
        static ulong UnsignedIntegral(object value, string targetName) {
            if (value is int) {
                int number = (int)value;
                if (number < 0) throw new InvalidOperationException("JSON value out of range for " + targetName + ".");
                return (ulong)number;
            }
            if (value is long) {
                long number = (long)value;
                if (number < 0) throw new InvalidOperationException("JSON value out of range for " + targetName + ".");
                return (ulong)number;
            }
            if (value is ulong) return (ulong)value;
            throw new InvalidOperationException("Expected an integral JSON number for " + targetName + ".");
        }
        static int CheckedInt32(long value, string targetName) {
            if (value < int.MinValue || value > int.MaxValue)
                throw new InvalidOperationException("JSON value out of range for " + targetName + ".");
            return (int)value;
        }
        // A legacy JSON byte array is a list of integral values in [0, 255].
        // Booleans, strings, fractional or out-of-range numbers are rejected.
        static byte[] ReadByteArray(List<object> items) {
            var bytes = new byte[items.Count];
            for (int i = 0; i < items.Count; i++) {
                object item = items[i];
                long number;
                if (item is int) number = (int)item;
                else if (item is long) number = (long)item;
                else throw new InvalidOperationException("JSON byte array elements must be integers in [0, 255].");
                if (number < 0 || number > 255)
                    throw new InvalidOperationException("JSON byte array element out of range: " + number + ".");
                bytes[i] = (byte)number;
            }
            return bytes;
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
        static readonly BoundedNotification settingsNotification = new BoundedNotification();
        public static void NotifyTraySettings() {
            settingsNotification.Request(delegate {
                // Keep the marshaled string alive until the native send returns,
                // even after the supervisor stops waiting. Do not use PostMessage
                // or SendNotifyMessage with a pointer-valued asynchronous payload.
                UIntPtr ignored;
                SendMessageTimeout(new IntPtr(0xFFFF), 0x001A, UIntPtr.Zero, "TraySettings", 0x0002, 3000, out ignored);
            });
        }
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
            // Preserve Settings' notification semantics, outside the message pump.
            NotifyTraySettings();
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
            var text = TakeoverJson.Serialize(snapshot);
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
        // JSON entry points shared by the restore script and the regression
        // fixture so both use the same schema on any PowerShell edition.
        public static string SerializeSnapshot(Snapshot snapshot) { return TakeoverJson.Serialize(snapshot); }
        public static Snapshot DeserializeSnapshot(string json) {
            var snapshot = TakeoverJson.Deserialize<Snapshot>(json);
            ValidateSnapshot(snapshot);
            return snapshot;
        }
        public static Snapshot LoadSnapshot(string path) { return DeserializeSnapshot(File.ReadAllText(path)); }
        public static Launch DeserializeLaunch(string json) {
            var launch = TakeoverJson.Deserialize<Launch>(json);
            ValidateLaunch(launch);
            return launch;
        }
        // Required collections and their elements must never be null. A field
        // initializer supplies an empty list only when the key is absent; an
        // explicit JSON null overwrites it, and a null element dereferences
        // during restore. Deliberately nullable fields keep their defaults.
        static void ValidateSnapshot(Snapshot snapshot) {
            if (snapshot.Displays == null) throw new InvalidOperationException("Snapshot.Displays must not be null.");
            if (snapshot.Bars == null) throw new InvalidOperationException("Snapshot.Bars must not be null.");
            if (snapshot.Regions == null) throw new InvalidOperationException("Snapshot.Regions must not be null.");
            foreach (var display in snapshot.Displays)
                if (display == null) throw new InvalidOperationException("Snapshot.Displays contains a null element.");
            foreach (var bar in snapshot.Bars)
                if (bar == null) throw new InvalidOperationException("Snapshot.Bars contains a null element.");
            foreach (var region in snapshot.Regions)
                if (region == null) throw new InvalidOperationException("Snapshot.Regions contains a null element.");
        }
        static void ValidateLaunch(Launch launch) {
            if (launch.Environment == null) throw new InvalidOperationException("Launch.Environment must not be null.");
            if (launch.TestWindowOwners == null) launch.TestWindowOwners = new List<int>();
        }
        public static string SerializeTaskbarAction(TaskbarAction action) { return TakeoverJson.Serialize(action); }
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
        // when this supervisor is configured to hide the taskbar. This backend
        // switch is read once per process, including its readiness wait. The
        // supervisor owns the restart, so a crash keeps its minidump and desktop cleanup and skips
        // only the shell's own relaunch.
        public static void Apply(System.Collections.Specialized.StringDictionary variables, bool hide) {
            variables.Remove(DisableCrashHandler);
            variables[DisableCrashRelaunch] = "1";
            variables.Remove(TaskbarShortcutFilter);
            if (hide) variables[TaskbarShortcutFilter] = "1";
        }
    }

    // Each redirected child owns a separate latch. A late EOF/log callback from
    // an exited child cannot make its replacement ready. Only a complete,
    // content-free QML info record is accepted, never a substring of user text.
    public sealed class ShellReadiness {
        public const string Marker = "CAELESTIA_SHELL_READY";
        static readonly System.Text.RegularExpressions.Regex record = new System.Text.RegularExpressions.Regex(
            @"^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})?\s*INFO qml: " + Marker + "$");
        int ready;
        int paused;
        int pauseGeneration;
        public bool Ready { get { return Interlocked.CompareExchange(ref ready, 0, 0) != 0; } }
        public bool Paused { get { return Interlocked.CompareExchange(ref paused, 0, 0) != 0; } }
        public int PauseGeneration { get { return Interlocked.CompareExchange(ref pauseGeneration, 0, 0); } }
        public void Observe(string line) {
            if (line != null && record.IsMatch(line)) Interlocked.Exchange(ref ready, 1);
            if (line != null && pauseRecord.IsMatch(line)) {
                // Publish the reset before making a resume eligible again.
                Interlocked.Increment(ref pauseGeneration);
                Interlocked.Exchange(ref paused, line.EndsWith("_PAUSED", StringComparison.Ordinal) ? 1 : 0);
            }
        }
        static readonly System.Text.RegularExpressions.Regex pauseRecord = new System.Text.RegularExpressions.Regex(
            @"^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})?\s*INFO qml: CAELESTIA_SHELL_(?:PAUSED|ACTIVE)$");
    }

    // Milliseconds come from QPC, never wall time. Only an exact, current nonce
    // can arm/reset detection. Unsupported older shells remain unarmed forever.
    public sealed class ShellLiveness {
        // A healthy shell is probed once a minute, because each probe starts
        // an IPC client process. Probes tighten only after a miss.
        public const int ProbeIntervalMs = 60000;
        public const int RetryIntervalMs = 15000;
        public const int ProbeTimeoutMs = 5000;
        public const int FreezeWindowMs = 120000;
        public const int RequiredMisses = 6;
        public const int MaxTickGapMs = 5000;
        long lastTick, nextProbe, deadline, firstMiss;
        public string Nonce { get; private set; }
        public bool Armed { get; private set; }
        public bool Frozen { get; private set; }
        public int Misses { get; private set; }
        public void Reset(long now) {
            Nonce = null; Misses = 0; Frozen = false;
            firstMiss = 0; nextProbe = now + ProbeIntervalMs; lastTick = now;
        }
        public bool Advance(long now, bool eligible) {
            if (!eligible || lastTick == 0 || now < lastTick || now - lastTick > MaxTickGapMs) {
                Reset(now);
                return false;
            }
            lastTick = now;
            return true;
        }
        public bool Due(long now) { return Nonce == null && now >= nextProbe; }
        public string Issue(long now) {
            Nonce = Guid.NewGuid().ToString("N");
            deadline = now + ProbeTimeoutMs; nextProbe = now + ProbeIntervalMs;
            return Nonce;
        }
        public bool Accept(string reply) {
            if (Nonce == null || reply != Nonce) return false;
            Armed = true; Frozen = false; Misses = 0; firstMiss = 0; Nonce = null;
            return true;
        }
        public void Expire(long now) {
            if (Nonce == null || now < deadline) return;
            Nonce = null;
            if (!Armed) return;
            if (Misses++ == 0) firstMiss = now;
            nextProbe = Math.Min(nextProbe, deadline - ProbeTimeoutMs + RetryIntervalMs);
            Frozen = Misses >= RequiredMisses && now - firstMiss >= FreezeWindowMs;
        }
    }

    static class SupervisorSession {
        [DllImport("wtsapi32.dll")] public static extern bool WTSRegisterSessionNotification(IntPtr window, uint flags);
        [DllImport("wtsapi32.dll")] public static extern bool WTSUnRegisterSessionNotification(IntPtr window);
        [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(
            IntPtr server, int session, int infoClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
        public static bool Unlocked() {
            IntPtr buffer; int bytes;
            // WTSINFOEX level 1 has an aligned union at offset 8. Its first
            // fields are SessionId, SessionState, SessionFlags. Win11 uses
            // flags 0 for locked and 1 for unlocked. Unknown state fails safe.
            if (!WTSQuerySessionInformation(IntPtr.Zero, Process.GetCurrentProcess().SessionId, 25, out buffer, out bytes))
                return false;
            try { return bytes >= 20 && Marshal.ReadInt32(buffer) == 1
                    && Marshal.ReadInt32(buffer, 12) == 0 && Marshal.ReadInt32(buffer, 16) == 1; }
            finally { WTSFreeMemory(buffer); }
        }
        public static bool Updating(string key) {
            if (String.IsNullOrEmpty(key)) return false;
            foreach (var scope in new[] { @"Global\", @"Local\" }) {
                try {
                    using (var mutex = Mutex.OpenExisting(scope + "CaelestiaInstall-" + key)) {
                        bool acquired;
                        try { acquired = mutex.WaitOne(0); }
                        catch (AbandonedMutexException) { acquired = true; }
                        if (!acquired) return true;
                        mutex.ReleaseMutex();
                    }
                } catch (WaitHandleCannotBeOpenedException) {}
                  catch (UnauthorizedAccessException) { return true; }
            }
            return false;
        }
    }

    // Probe clients must die even when forced recovery kills the supervisor
    // before Dispose can run. Only probes are assigned to the job, and its
    // handle is never inherited by those clients.
    sealed class ProbeJob : IDisposable {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
            public uint ActiveProcesses;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimits {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits limits, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        IntPtr handle;
        public ProbeJob() {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } };
            if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) {
                int error = Marshal.GetLastWin32Error();
                Dispose();
                throw new System.ComponentModel.Win32Exception(error);
            }
        }
        public void Own(Process process) {
            if (!AssignProcessToJobObject(handle, process.Handle)) throw new System.ComponentModel.Win32Exception();
        }
        public void Dispose() {
            if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; }
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
        ShellReadiness childReadiness;
        ShellLiveness liveness = new ShellLiveness();
        Process probe;
        ProbeJob probeJob;
        System.Threading.Tasks.Task<string> probeOutput;
        bool probeExpired, frozenTermination, sessionPaused, powerPaused, endingSession;
        int lastPauseGeneration;
        string lastUnhealthyReason;
        bool childBecameReady, waitingReady, takeover, tookOver, taskbarRestorePending;
        long readyDeadline, takeoverGraceDeadline;
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
        // This is a reporting deadline, never a child lifetime bound.
        // Match Wait-CaelestiaReady's budget; a live child can draw much later
        // after unlock, display wake or hotplug placement.
        public const int ReadyTimeoutMs = 20000;
        public const int RestartTakeoverGraceMs = 2000;
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
            return Run(specPath, hide, restart, invisible, true);
        }
        public static int Run(string specPath, bool hide, bool restart, bool invisible, bool restartFrozenShell) {
            return RunCore(specPath, hide, restart, invisible, MutexName, EventName, false, 0, restartFrozenShell);
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
            string mutexName, string eventName, bool isolatedTest, int testLogDelayMs, bool? restartFrozenShell = null) {
            using (var mutex = new System.Threading.Mutex(false, mutexName)) {
                bool acquired;
                try { acquired = mutex.WaitOne(0); }
                catch (System.Threading.AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new InvalidOperationException("A desktop supervisor already owns this Windows session.");
                try {
                    var launch = TakeoverJson.Deserialize<Launch>(File.ReadAllText(specPath));
                    if (restartFrozenShell.HasValue) launch.RestartFrozenShell = restartFrozenShell.Value;
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
            }, LogPersistFailure, 60);
            Native.RecordAction = delegate(TaskbarAction action) {
                SupervisorSafety.Log(delegate {
                    File.AppendAllText(Path.Combine(launch.StateDirectory, "taskbar-actions.jsonl"),
                        TakeoverJson.Serialize(action) + Environment.NewLine);
                });
            };
            // A hidden top-level window receives Explorer's broadcast. A
            // message-only HWND would not receive TaskbarCreated.
            CreateHandle(new CreateParams { Caption = "Caelestia desktop watchdog", Style = unchecked((int)0x80000000) });
            if (!isolatedTest) SupervisorSession.WTSRegisterSessionNotification(Handle, 0);
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
                var prior = TakeoverJson.Deserialize<Snapshot>(File.ReadAllText(best));
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
                var status = (Dictionary<string, object>)TakeoverJson.DeserializeObject(File.ReadAllText(statusPath));
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
            var info = new ProcessStartInfo(RecoveryPowerShellPath(launch),
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
        // The launcher records the verified PowerShell 7 path; an older journal
        // or a direct supervisor start may lack it, so fall back to the current
        // pwsh.exe host before touching Windows PowerShell 5.1.
        static string RecoveryPowerShellPath(Launch launch) {
            if (launch.PowerShellPath != null && launch.PowerShellPath.Length != 0
                && File.Exists(launch.PowerShellPath)) return launch.PowerShellPath;
            try {
                var module = Process.GetCurrentProcess().MainModule.FileName;
                if (module.EndsWith("pwsh.exe", StringComparison.OrdinalIgnoreCase) && File.Exists(module))
                    return module;
            } catch (System.ComponentModel.Win32Exception) { }
              catch (InvalidOperationException) { }
            return Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
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
            if (!takeover) return;
            RefreshShowHook(false);
            Native.Hide(recordUnchanged);
            SuppressRegions();
            nextTaskbarAudit = DateTime.UtcNow.AddSeconds(5);
        }
        protected override void WndProc(ref Message message) {
            if (message.Msg == 0x02B1) { // WM_WTSSESSION_CHANGE
                int reason = message.WParam.ToInt32();
                sessionPaused = reason == 7 || reason == 6 || reason == 4; // lock, logoff, disconnect
                liveness.Reset(MonotonicMilliseconds());
                CancelProbe();
            }
            if (message.Msg == 0x0218) { // WM_POWERBROADCAST
                int reason = message.WParam.ToInt32();
                if (reason == 4) powerPaused = true; // suspend
                if (reason == 7 || reason == 18) powerPaused = false; // resume
                liveness.Reset(MonotonicMilliseconds());
                CancelProbe();
            }
            if (message.Msg == 0x0011 || message.Msg == 0x0016) { // session shutdown
                endingSession = message.Msg == 0x0011 || message.WParam != IntPtr.Zero;
                liveness.Reset(MonotonicMilliseconds());
                CancelProbe();
            }
            // WM_SETTINGCHANGE and WM_DISPLAYCHANGE also cover work-area,
            // taskbar preference and monitor topology changes. The broadcast
            // reaches every section though, so only the sections that can
            // expose a taskbar justify a full suppression pass.
            bool maintain = message.Msg == 0x007E; // WM_DISPLAYCHANGE
            if (message.Msg == 0x001A) { // WM_SETTINGCHANGE
                maintain = message.WParam.ToInt32() == 0x002F; // SPI_SETWORKAREA
                if (!maintain && message.LParam != IntPtr.Zero)
                    maintain = Marshal.PtrToStringUni(message.LParam) == "TraySettings";
            }
            if (message.Msg == taskbarCreated) {
                // Quickshell's tray hook also sends TaskbarCreated to re-announce
                // icons under the same owner. Only a new Explorer taskbar owner
                // or an escaped taskbar needs another suppression pass.
                uint owner = Native.ExplorerTaskbarOwner();
                maintain = owner != showHook.Owner;
                if (!maintain) {
                    foreach (var bar in Native.Taskbars())
                        if (bar.Visible) { maintain = true; break; }
                }
            }
            if (maintain && child != null && !child.HasExited && takeover) {
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
                if (done || !takeover || child == null || child.HasExited || !showHook.Matches(hook)) return;
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
                var text = TakeoverJson.Serialize(new { phase = phase, shellPid = pid, watchdogPid = Process.GetCurrentProcess().Id,
                    quickCrashes = quickCrashes, hideTaskbar = hide, restartOnCrash = restart, exitCode = ExitCode,
                    forcedChildTermination = forcedChildTermination,
                    shellReady = childBecameReady, taskbarTakenOver = takeover,
                    livenessSupported = liveness.Armed, shellFrozen = liveness.Frozen,
                    livenessMisses = liveness.Misses, restartFrozenShell = launch.RestartFrozenShell,
                    lastUnhealthyReason = lastUnhealthyReason,
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
            CancelProbe();
            liveness = new ShellLiveness();
            liveness.Reset(MonotonicMilliseconds());
            frozenTermination = false;
            lastPauseGeneration = 0;
            var info = new ProcessStartInfo(launch.Executable, launch.Arguments) {
                WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true
            };
            foreach (var entry in launch.Environment) info.EnvironmentVariables[entry.Key] = entry.Value;
            info.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
            info.EnvironmentVariables.Remove("ELECTRON_NO_ASAR");
            // Only this supervisor decides these child switches, and only one
            // keyboard hook filters taskbar shortcuts: the shell's own.
            LaunchEnvironment.Apply(info.EnvironmentVariables, hide);
            // Readiness uses the existing async log pipe even without a log
            // destination. No IPC client or wait runs on the message pump.
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = !String.IsNullOrEmpty(launch.StderrPath);
            var process = new Process { StartInfo = info };
            var drain = new LogDrain(info.RedirectStandardOutput, info.RedirectStandardError);
            var readiness = new ShellReadiness();
            if (info.RedirectStandardOutput)
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                    if (e.Data == null) drain.EndStream();
                    else {
                        readiness.Observe(e.Data); // Before best-effort log I/O or drain delay.
                        if (testLogDelayMs > 0) Thread.Sleep(testLogDelayMs);
                        Append(launch.StdoutPath, e.Data, drain);
                    }
                };
            if (info.RedirectStandardError)
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                    if (e.Data == null) drain.EndStream();
                    else { if (testLogDelayMs > 0) Thread.Sleep(testLogDelayMs); Append(launch.StderrPath, e.Data, drain); }
                };
            // Snapshot is durable before the child can register AppBars, but
            // Explorer remains untouched until every monitor has drawn.
            process.Start();
            child = process;
            childReadiness = readiness;
            childBecameReady = waitingReady = false;
            forcedChildTermination = false;
            childDrain = drain;
            drainDeadline = 0;
            ownedPid = child.Id;
            if (rescueOwners != null) rescueOwners.Add(child.Id);
            if (info.RedirectStandardOutput) child.BeginOutputReadLine();
            if (info.RedirectStandardError) child.BeginErrorReadLine();
            started = DateTime.UtcNow;
            readyDeadline = Stopwatch.GetTimestamp() + ReadyTimeoutMs * Stopwatch.Frequency / 1000;
            Status("starting", child.Id);
        }
        void TakeOver() {
            takeoverGraceDeadline = 0;
            taskbarRestorePending = false;
            if (!hide) return;
            // Includes secondary suppression, regions, show hook and audit.
            if (!takeover) {
                tookOver = takeover = true;
                Native.SuppressSecondaryTaskbars(saved, SaveSnapshot);
            }
            MaintainTaskbars(true);
        }
        void ReleaseTakeover() {
            if (!takeover && !taskbarRestorePending) return;
            takeover = false;
            showHook.Dispose();
            showPolicy.Reset();
            // The replacement may already have live AppBars. Never remove
            // those, restore its work areas or rescue its parked windows here.
            if (!isolatedTest) Native.RestoreOwned(saved, -1, false, true);
            taskbarRestorePending = Native.ExplorerWorkDeferred;
        }
        static readonly object logLock = new object();
        static void Append(string path, string line, LogDrain drain) {
            if (String.IsNullOrEmpty(path)) return;
            SupervisorSafety.Log(delegate { lock (logLock) { if (!drain.Retired) File.AppendAllText(path, line + Environment.NewLine); } });
        }
        static void Retire(LogDrain drain) { lock (logLock) drain.Retired = true; }
        static long MonotonicMilliseconds() {
            return (long)(Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency);
        }
        void CancelProbe() {
            if (probe == null) return;
            try {
                if (!probe.HasExited && !probeExpired) probe.Kill();
                probeExpired = true;
                if (probe.HasExited) {
                    probe.Dispose(); probe = null; probeOutput = null;
                }
            } catch (InvalidOperationException) {}
              catch (System.ComponentModel.Win32Exception) {}
        }
        void MaintainLiveness() {
            long now = MonotonicMilliseconds();
            int generation = childReadiness.PauseGeneration;
            if (generation != lastPauseGeneration) {
                lastPauseGeneration = generation;
                liveness.Reset(now);
                CancelProbe();
            }
            bool eligible = childBecameReady && !childReadiness.Paused && !sessionPaused && !powerPaused
                && !endingSession;
            if (!liveness.Advance(now, eligible)) {
                CancelProbe();
                if (statusPhase == "frozen") Status("running", child.Id);
                return;
            }
            if (probe != null && !probeExpired && probe.HasExited && probeOutput.IsCompleted) {
                if (probe.ExitCode == 0 && !probeOutput.IsFaulted && !probeOutput.IsCanceled)
                    liveness.Accept(probeOutput.Result.Trim());
            }
            liveness.Expire(now);
            if (liveness.Nonce == null) CancelProbe();
            // Testing the install lock acquires it for an instant, which could
            // make a starting installer see it as held. Test it only here, at
            // the single moment a freeze would otherwise be declared.
            if (liveness.Frozen && SupervisorSession.Updating(launch.InstallLockKey)) {
                liveness.Reset(now);
                CancelProbe();
                return;
            }
            if (liveness.Frozen) {
                lastUnhealthyReason = "gui-unresponsive";
                Status("frozen", child.Id);
                if (launch.RestartFrozenShell) {
                    // Reuse the dead-child drain, restoration, limits and backoff.
                    frozenTermination = true;
                    child.Kill();
                    BeginDrain();
                    return;
                }
            } else if (statusPhase == "frozen") Status("running", child.Id);
            if (probe != null || !liveness.Due(now)) return;
            // Session notifications cover lock and unlock. This query covers a
            // supervisor that started in a locked or disconnected session.
            if (!isolatedTest && !SupervisorSession.Unlocked()) { liveness.Reset(now); return; }
            string nonce = liveness.Issue(now);
            var info = new ProcessStartInfo(launch.Executable,
                "ipc --pid " + child.Id + " call shell supervisorProbe " + nonce) {
                WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false,
                CreateNoWindow = true, RedirectStandardOutput = true
            };
            foreach (var entry in launch.Environment) info.EnvironmentVariables[entry.Key] = entry.Value;
            // An IPC launch failure is not evidence about the GUI event loop.
            var candidate = new Process { StartInfo = info };
            try {
                if (probeJob == null) probeJob = new ProbeJob();
                candidate.Start();
                probeJob.Own(candidate);
                probe = candidate; probeExpired = false;
                probeOutput = candidate.StandardOutput.ReadToEndAsync();
            } catch (Exception error) {
                try { if (candidate.Id != 0 && !candidate.HasExited) candidate.Kill(); }
                catch (InvalidOperationException) {}
                candidate.Dispose();
                if (!(error is System.ComponentModel.Win32Exception || error is InvalidOperationException)) throw;
                liveness.Reset(now);
            }
        }
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
                    liveness.Reset(MonotonicMilliseconds());
                    CancelProbe();
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
                    // Missing baseline flags and dead-child AppBar cleanup
                    // must keep retrying while the replacement is starting.
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
                        if (taskbarRestorePending) ReleaseTakeover();
                    }
                    if (!childBecameReady) {
                        long now = Stopwatch.GetTimestamp();
                        if (childReadiness.Ready) {
                            childBecameReady = true;
                            TakeOver();
                            Status("running", child.Id);
                        } else {
                            if (takeover && takeoverGraceDeadline != 0 && now >= takeoverGraceDeadline) {
                                ReleaseTakeover();
                                Status("starting", child.Id);
                            }
                            if (!waitingReady && now >= readyDeadline) {
                                waitingReady = true;
                                ReleaseTakeover();
                                // Missing frames are not a crash. Keep pumping,
                                // heartbeating and accepting a marker indefinitely.
                                Status("waiting-ready", child.Id);
                            }
                            return;
                        }
                    }
                    MaintainLiveness();
                    if (frozenTermination) return;
                    // The show hook handles re-shows immediately. Audit only
                    // every five seconds unless its existing fight-loop policy
                    // explicitly falls back to polling for five seconds.
                    if (takeover && (DateTime.UtcNow >= nextTaskbarAudit
                        || showPolicy.PollingRequired(Stopwatch.GetTimestamp())))
                        MaintainTaskbars(false);
                    return;
                }
                showHook.Dispose();
                CancelProbe();
                showPolicy.Reset();
                if (takeover && takeoverGraceDeadline == 0)
                    takeoverGraceDeadline = Stopwatch.GetTimestamp() + RestartTakeoverGraceMs * Stopwatch.Frequency / 1000;
                if (takeover && Stopwatch.GetTimestamp() >= takeoverGraceDeadline) ReleaseTakeover();
                BeginDrain();
                // Keep pumping the UI and recovery event while waiting for
                // both EOF callbacks, but never wait beyond the shared deadline.
                if (!childDrain.Complete && Stopwatch.GetTimestamp() < drainDeadline) return;
                if (recovering) { Finish("recovered", 0); return; }
                // A very short-lived child can draw and exit between ticks.
                // Drain first so a final readiness record is not lost.
                childBecameReady |= childReadiness.Ready;
                int code = frozenTermination ? 1 : child.ExitCode;
                // A zero exit before the first frame is a failed start, for
                // example a duplicate instance that bows out. A shell that
                // outlived the readiness deadline was alive and usable without
                // reporting frames, so its zero exit is the user quitting.
                bool failedStart = !childBecameReady && !waitingReady;
                if (failedStart && code == 0) code = 1;
                // Past EOF or the deadline: drop any stalled tail so it cannot
                // interleave with a restarted child's log.
                Retire(childDrain);
                child.Dispose(); child = null;
                childDrain = null;
                childBecameReady = false;
                Status("restoring", 0);
                // Decide the outcome first, so the desktop work matches it and
                // always precedes a potentially slow banner replay.
                // A freeze takes minutes to detect, so it gets a longer window
                // than a crash. Freezes spread over days must not add up to a
                // permanent stop.
                double lifetime = (DateTime.UtcNow - started).TotalSeconds;
                if (code != 0) quickCrashes = failedStart || lifetime < (frozenTermination ? 600 : 30) ? quickCrashes + 1 : 0;
                bool terminal = code == 0 || !restart || quickCrashes >= 3;
                int delay = terminal ? 0 : RestartPolicy.DelaySeconds(quickCrashes);
                try {
                    // The shell is not coming back: return the whole desktop.
                    if (terminal) RestoreDesktop();
                    // A restart follows. Release the dead shell's AppBars, and
                    // show the taskbar only while backing off. An immediate
                    // restart keeps it hidden and leaves parked windows to the
                    // new shell, so one crash does not flash the taskbar.
                    else if (!isolatedTest) Native.RestoreOwned(saved, ownedPid, launch.RestoreWorkAreas, false);
                    if (!terminal && delay != 0) ReleaseTakeover();
                    // Banner replay can block for 45 s. Such a restart cannot
                    // be immediate, so return Explorer before entering it.
                    string bannerState;
                    if (!terminal && launch.Environment.TryGetValue("CAELESTIA_STATE_DIR", out bannerState)
                        && File.Exists(Path.Combine(bannerState, "banner-suppression.json"))) ReleaseTakeover();
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
            takeover = false;
            childBecameReady = false;
            try { if (!isolatedTest) Native.RestoreOwned(saved, ownedPid, launch.RestoreWorkAreas, tookOver || adoptedUncleanBaseline); }
            // No shell is left to run TilingManager::rescueParked, so the
            // windows it parked must come back before banner recovery.
            finally { Native.RescueParkedWindows(tilerMutex, rescueFilter); }
        }
        public void Dispose() {
            if (done) return;
            done = true;
            timer.Stop(); timer.Dispose();
            CancelProbe();
            if (probeJob != null) probeJob.Dispose();
            if (!isolatedTest) SupervisorSession.WTSUnRegisterSessionNotification(Handle);
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
