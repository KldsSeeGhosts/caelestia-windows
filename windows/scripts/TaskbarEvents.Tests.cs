// Fake-only desktop tests. Snapshot persistence uses a temporary file.
using System;
using System.Collections.Generic;
using System.IO;
using Caelestia.Takeover;

public static class TaskbarEventsTests {
    static int assertions;
    static void Check(bool value, string message) {
        assertions++;
        if (!value) throw new Exception(message);
    }
    public static int Run() {
        var installed = new List<uint>();
        var removed = new List<IntPtr>();
        bool fail = false;
        var binding = new TaskbarHookBinding(delegate(uint pid) {
            installed.Add(pid);
            return fail ? IntPtr.Zero : new IntPtr((int)pid);
        }, delegate(IntPtr hook) { removed.Add(hook); });
        binding.Refresh(10, false);
        binding.Refresh(10, false);
        Check(installed.Count == 1 && binding.Owner == 10 && binding.Matches(new IntPtr(10)), "reuse hook");
        binding.Refresh(20, false);
        Check(removed.Count == 1 && removed[0] == new IntPtr(10) && binding.Owner == 20 &&
            !binding.Matches(new IntPtr(10)), "replace owner and reject stale callbacks");
        binding.Refresh(20, true);
        Check(removed.Count == 2 && installed.Count == 3, "broadcast forces replacement");
        fail = true;
        binding.Refresh(30, false);
        Check(binding.Owner == 0 && removed.Count == 3, "failed installation is unbound");
        fail = false;
        binding.Refresh(30, false);
        Check(binding.Owner == 30 && installed.Count == 5, "failed installation retries");
        binding.Refresh(0, false);
        Check(binding.Owner == 0 && removed.Count == 4, "missing Explorer unhooks");
        binding.Refresh(30, false);
        binding.Dispose();
        binding.Dispose();
        Check(removed.Count == 5 && binding.Owner == 0, "dispose is idempotent");
        Check(Native.IsExplorerTaskbar("Shell_TrayWnd", 42, 42) &&
            Native.IsExplorerTaskbar("Shell_SecondaryTrayWnd", 42, 42) &&
            !Native.IsExplorerTaskbar("Other", 42, 42) &&
            !Native.IsExplorerTaskbar("Shell_TrayWnd", 43, 42) &&
            !Native.IsExplorerTaskbar("Shell_TrayWnd", 0, 0), "taskbar class and owner filter");

        var actions = new List<TaskbarAction>();
        var order = new List<string>();
        int resolves = 0, hides = 0;
        bool visible = true;
        var policy = new TaskbarShowPolicy(1000);
        var handler = new TaskbarShowHandler(policy, delegate(IntPtr hwnd, uint owner) {
            resolves++;
            if (owner != 42 || (hwnd != new IntPtr(1) && hwnd != new IntPtr(2))) return null;
            return new Bar { Handle = hwnd.ToInt64(), Owner = owner, Visible = visible };
        }, delegate(Bar bar, long ticks) {
            hides++;
            order.Add("hide");
            return new TaskbarAction { Operation = "hide", ShowObservedTicks = ticks,
                MonotonicTicks = ticks + 3, VisibleAfter = false, ShowToHideMilliseconds = 3 };
        }, delegate(TaskbarAction action) { order.Add(action.Operation); actions.Add(action); });
        handler.Handle(0, new IntPtr(1), 0, 0, 0);
        handler.Handle(42, new IntPtr(1), -4, 0, 0);
        handler.Handle(42, new IntPtr(1), 0, 1, 0);
        Check(resolves == 0 && actions.Count == 0, "ignore unbound, object and child events");
        handler.Handle(43, new IntPtr(1), 0, 0, 1);
        handler.Handle(42, new IntPtr(3), 0, 0, 2);
        Check(actions.Count == 0, "ignore wrong owner or class/window");
        handler.Handle(42, new IntPtr(1), 0, 0, 100);
        Check(hides == 1 && order[0] == "hide" && order[1] == "show" && order[2] == "hide",
            "hide before log I/O, record show then hide");
        Check(actions[0].MonotonicTicks == 100 && actions[0].ShowObservedTicks == 100 &&
            actions[0].TickFrequency == System.Diagnostics.Stopwatch.Frequency && actions[0].Utc != null &&
            actions[0].Source == "event" && actions[1].Source == "event" &&
            actions[1].ShowObservedTicks == 100 && actions[1].ShowToHideMilliseconds == 3 &&
            !actions[1].VisibleAfter,
            "correlated monotonic and UTC records");
        // Many separate relayouts and both taskbars must not trip the guard.
        for (int i = 1; i <= 30; i++)
            handler.Handle(42, new IntPtr(i % 2 + 1), 0, 0, 100 + i * 100);
        Check(hides == 31 && actions.FindAll(a => a.Operation == "event-backoff").Count == 0,
            "spaced startup relayouts on both monitors do not back off");
        policy.Reset();
        int beforeBurst = hides;
        for (int i = 0; i < 9; i++)
            handler.Handle(42, new IntPtr(2), 0, 0, 3101 + i * 10);
        Check(hides == beforeBurst + 9 && actions.FindAll(a => a.Operation == "event-backoff").Count == 0,
            "brief same-window startup burst remains event-driven");
        // A sustained same-window fight is bounded.
        policy.Reset();
        int beforeFight = hides;
        for (int i = 1; i <= 14; i++)
            handler.Handle(42, new IntPtr(1), 0, 0, 4100 + i * 10);
        Check(hides == beforeFight + 12, "twelfth rapid recurrence enters backoff");
        Check(actions.FindAll(a => a.Operation == "event-backoff").Count == 1,
            "backoff is logged once despite further shows");
        handler.Handle(42, new IntPtr(1), 0, 0, 9230);
        Check(hides == beforeFight + 13, "immediate suppression resumes at backoff deadline");
        visible = false;
        handler.Handle(42, new IntPtr(2), 0, 0, 9240);
        Check(hides == beforeFight + 13 && actions[actions.Count - 1].Operation == "show", "record delayed show without redundant hide");
        policy.Reset();
        visible = true;
        handler.Handle(42, new IntPtr(2), 0, 0, 9250);
        Check(hides == beforeFight + 14, "restart resets policy");

        var first = new Bar { Handle = 1, Owner = 42, Visible = true };
        var other = new Bar { Handle = 2, Owner = 42, Visible = true };
        var newOwner = new Bar { Handle = 1, Owner = 43, Visible = true };
        policy.Reset();
        bool entered;
        for (int i = 0; i < 20; i++) {
            long tick = i * 90;
            Check(policy.AllowImmediate(first, tick, out entered) && !entered, "non-rapid repeated relayout");
            policy.RememberHide(first, tick + 1);
        }
        policy.Reset();
        for (int i = 0; i < 11; i++) {
            policy.RememberHide(first, i * 10);
            Check(policy.AllowImmediate(first, i * 10 + 1, out entered) && !entered, "bounded rapid recurrence");
        }
        policy.RememberHide(other, 111);
        Check(policy.AllowImmediate(other, 112, out entered) && !entered, "other HWND has its own counter");
        Check(policy.AllowImmediate(newOwner, 112, out entered) && !entered, "owner change has its own counter");
        policy.RememberHide(first, 120);
        Check(!policy.AllowImmediate(first, 121, out entered) && entered, "twelfth recurrence enters backoff");
        Check(!policy.AllowImmediate(other, 122, out entered) && !entered, "global backoff is quiet");
        Check(policy.AllowImmediate(other, 5121, out entered) && !entered, "backoff ends at deadline");
        policy.Reset();
        policy.RememberHide(first, 0);
        Check(policy.AllowImmediate(first, 76, out entered) && !entered, "75 ms boundary excludes slower events");
        policy.RememberHide(first, 200);
        Check(policy.AllowImmediate(first, 275, out entered) && !entered, "75 ms boundary includes rapid event");
        policy.Reset();
        policy.RememberHide(first, 300);
        Check(policy.AllowImmediate(first, 299, out entered) && !entered,
            "an event observed before hide return is not a recurrence");
        policy.Reset();
        for (int i = 0; i < 11; i++) {
            policy.RememberHide(first, i * 10);
            Check(policy.AllowImmediate(first, i * 10 + 1, out entered), "rolling window setup");
        }
        policy.RememberHide(first, 2200);
        Check(policy.AllowImmediate(first, 2201, out entered) && !entered, "old recurrences expire");

        int failedHides = 0, backoffs = 0;
        var failedHandler = new TaskbarShowHandler(new TaskbarShowPolicy(1000),
            delegate(IntPtr hwnd, uint owner) { return first; },
            delegate(Bar bar, long ticks) {
                failedHides++;
                return new TaskbarAction { Operation = "hide", VisibleAfter = true, MonotonicTicks = ticks };
            },
            delegate(TaskbarAction action) { if (action.Operation == "event-backoff") backoffs++; });
        for (int i = 0; i < 20; i++) failedHandler.Handle(42, new IntPtr(1), 0, 0, i * 10);
        Check(failedHides == 12 && backoffs == 1, "ineffective synchronous hides are bounded too");
        int refusedHides = 0;
        var refusedHandler = new TaskbarShowHandler(new TaskbarShowPolicy(1000),
            delegate(IntPtr hwnd, uint owner) { return first; },
            delegate(Bar bar, long ticks) { refusedHides++; return null; },
            delegate(TaskbarAction action) { if (action.Operation == "event-backoff") backoffs++; });
        for (int i = 0; i < 20; i++) refusedHandler.Handle(42, new IntPtr(1), 0, 0, i * 10);
        Check(refusedHides == 20 && backoffs == 1, "owner recheck failures are not counted as hides");
        var snapshot = new Snapshot();
        var sequence = new List<string>();
        bool persistFails = false;
        var manager = new RegionSuppression(snapshot,
            delegate(Bar bar) { sequence.Add("capture"); return new SavedRegion {
                Handle = bar.Handle, Owner = bar.Owner, ProcessStartTicks = bar.Owner,
                RegionData = "original-" + bar.Owner }; },
            delegate(SavedRegion r) { sequence.Add("persist"); if (persistFails) throw new Exception("disk"); },
            delegate(SavedRegion r) { sequence.Add("apply"); },
            delegate(SavedRegion r) { sequence.Add("restore-" + r.RegionData); });
        manager.Reconcile(first);
        Check(String.Join(",", sequence.ToArray()) == "capture,persist,apply" &&
            snapshot.Regions.Count == 1, "durable snapshot precedes mutation");
        sequence.Clear();
        manager.Reconcile(first);
        Check(String.Join(",", sequence.ToArray()) == "capture,apply" &&
            snapshot.Regions[0].RegionData == "original-42", "reapply retains original snapshot");
        manager.Reconcile(newOwner);
        Check(snapshot.Regions.Count == 2 && snapshot.Regions[1].Owner == 43, "new Explorer gets its own snapshot");
        var json = new System.Web.Script.Serialization.JavaScriptSerializer();
        var roundTrip = json.Deserialize<Snapshot>(json.Serialize(snapshot));
        Check(roundTrip.Regions.Count == 2 && roundTrip.Regions[0].RegionData == "original-42" &&
            roundTrip.Regions[1].ProcessStartTicks == 43, "durable recovery snapshot round-trips identity and region");
        persistFails = true;
        int before = sequence.Count;
        try { manager.Reconcile(other); throw new Exception("expected failure"); }
        catch (Exception e) { if (e.Message != "disk") throw; }
        Check(snapshot.Regions.Count == 2 && sequence.Count == before + 2 &&
            sequence[sequence.Count - 1] == "persist", "failed persistence prevents apply");
        manager.Restore();
        Check(sequence.Contains("restore-original-42") && sequence.Contains("restore-original-43"),
            "restore each saved identity");

        int regionApplies = 0, guardedHides = 0, guardedBackoffs = 0;
        var guarded = new TaskbarShowHandler(new TaskbarShowPolicy(1000),
            delegate(IntPtr hwnd, uint owner) { return first; },
            delegate(Bar bar) { regionApplies++; },
            delegate(Bar bar, long ticks) {
                guardedHides++;
                return new TaskbarAction { Operation = "hide", MonotonicTicks = ticks };
            },
            delegate(TaskbarAction action) { if (action.Operation == "event-backoff") guardedBackoffs++; });
        for (int i = 0; i < 30; i++) guarded.Handle(42, new IntPtr(1), 0, 0, i * 10);
        Check(regionApplies == 12 && guardedHides == 12 && guardedBackoffs == 1,
            "region and hide share the event backoff during repeated Explorer resets");
        // Timer reconciliation is independent of event backoff.
        persistFails = false;
        sequence.Clear();
        manager.Reconcile(first);
        Check(sequence.Contains("apply"), "poll reconciliation still applies during event backoff");
        guarded.Handle(42, new IntPtr(1), 0, 0, 5120);
        Check(regionApplies == 13 && guardedHides == 13, "region and hide resume after backoff");

        int cleaned = 0;
        foreach (var error in new Exception[] { new IOException("full"), new UnauthorizedAccessException("denied") }) {
            SupervisorSafety.Fail(delegate { throw error; }, delegate { cleaned++; });
        }
        Check(cleaned == 2, "cleanup runs when both error-log writes fail");
        var failedSnapshot = new Snapshot();
        int applied = 0, restored = 0;
        var failedManager = new RegionSuppression(failedSnapshot,
            delegate(Bar bar) { return new SavedRegion { Handle = bar.Handle, Owner = bar.Owner }; },
            delegate(SavedRegion r) { if (r.Handle == 2) throw new IOException("snapshot full"); },
            delegate(SavedRegion r) { applied++; },
            delegate(SavedRegion r) { restored++; });
        failedManager.Reconcile(first);
        try { failedManager.Reconcile(other); throw new Exception("expected snapshot failure"); }
        catch (IOException) {
            SupervisorSafety.Fail(delegate { throw new IOException("log full"); },
                delegate { failedManager.Restore(); });
        }
        Check(applied == 1 && restored == 1 && failedSnapshot.Regions.Count == 1,
            "failed snapshot and failed logging still restore previously owned region");

        bool vanished = true;
        int attempts = 0, raceApplies = 0;
        var raceSnapshot = new Snapshot();
        var raceManager = new RegionSuppression(raceSnapshot,
            delegate(Bar bar) {
                return RegionCapture.TryCapture(delegate {
                    attempts++;
                    if (vanished) throw new InvalidOperationException("Explorer exited");
                    return new SavedRegion { Handle = bar.Handle, Owner = bar.Owner };
                }, delegate { return vanished; });
            }, delegate(SavedRegion r) {}, delegate(SavedRegion r) { raceApplies++; },
            delegate(SavedRegion r) {});
        raceManager.Reconcile(first);
        Check(attempts == 1 && raceApplies == 0 && raceSnapshot.Regions.Count == 0,
            "vanished taskbar is skipped without persistence or mutation");
        vanished = false;
        raceManager.Reconcile(first);
        Check(attempts == 2 && raceApplies == 1 && raceSnapshot.Regions.Count == 1,
            "later discovery retries after Explorer returns");
        var replaced = new RegionSuppression(new Snapshot(),
            delegate(Bar bar) {
                return RegionCapture.TryCapture(delegate {
                    return new SavedRegion { Handle = bar.Handle, Owner = bar.Owner };
                }, delegate { return true; });
            }, delegate(SavedRegion r) { throw new Exception("persisted replacement"); },
            delegate(SavedRegion r) { throw new Exception("applied replacement"); }, delegate(SavedRegion r) {});
        replaced.Reconcile(first);
        Check(true, "replaced taskbar identity is skipped");
        try {
            RegionCapture.TryCapture(delegate { throw new IOException("native failure"); }, delegate { return false; });
            throw new Exception("expected native failure");
        } catch (IOException) { Check(true, "failure for a surviving taskbar remains fatal"); }

        var dpiCalls = new List<long>();
        var fakeDpi = new Func<IntPtr, IntPtr>(delegate(IntPtr value) {
            dpiCalls.Add(value.ToInt64());
            return value.ToInt64() == -4 ? new IntPtr(42) : new IntPtr(-4);
        });
        try {
            DpiScope.Run<int>(fakeDpi, delegate { throw new IOException("region operation"); });
            throw new Exception("expected DPI test failure");
        } catch (IOException) {}
        Check(dpiCalls.Count == 2 && dpiCalls[0] == -4 && dpiCalls[1] == 42,
            "per-monitor v2 scope restores caller DPI context on failure");
        bool called = false;
        try {
            DpiScope.Run<int>(delegate(IntPtr value) { return IntPtr.Zero; },
                delegate { called = true; return 0; });
            throw new Exception("expected DPI setup failure");
        } catch (InvalidOperationException) {}
        Check(!called, "failed DPI context switch refuses region operations");

        var batchSnapshot = new Snapshot();
        var batchSequence = new List<string>();
        var batchBars = new List<Bar> { first, other };
        RegionBatch.Prepare(batchSnapshot, batchBars, delegate(Bar bar) {
            batchSequence.Add("capture" + bar.Handle);
            return new SavedRegion { Handle = bar.Handle };
        }, delegate(Snapshot value) {
            Check(value.Regions.Count == 2, "batch persistence receives every region");
            batchSequence.Add("persist");
        });
        foreach (var region in batchSnapshot.Regions) batchSequence.Add("apply" + region.Handle);
        Check(String.Join(",", batchSequence.ToArray()) == "capture1,capture2,persist,apply1,apply2",
            "all regions are captured and persisted before any mutation");
        bool persisted = false;
        try {
            RegionBatch.Prepare(new Snapshot(), batchBars, delegate(Bar bar) {
                return bar.Handle == 2 ? null : new SavedRegion { Handle = bar.Handle };
            }, delegate(Snapshot value) { persisted = true; });
            throw new Exception("expected missing taskbar");
        } catch (InvalidOperationException) {}
        Check(!persisted, "failed batch capture cannot commit an incomplete snapshot");
        try {
            RegionBatch.Prepare(new Snapshot(), batchBars,
                delegate(Bar bar) { return new SavedRegion { Handle = bar.Handle }; },
                delegate(Snapshot value) { throw new IOException("disk"); });
            throw new Exception("expected batch persistence failure");
        } catch (IOException) { Check(true, "batch persistence failure propagates before mutation"); }

        var snapshotPath = Path.Combine(Path.GetTempPath(), "caelestia-snapshot-test-" + Guid.NewGuid().ToString("N") + ".json");
        try {
            Native.SaveSnapshot(snapshotPath, batchSnapshot);
            batchSnapshot.TaskbarFlags = 1;
            Native.SaveSnapshot(snapshotPath, batchSnapshot);
            var stored = json.Deserialize<Snapshot>(File.ReadAllText(snapshotPath));
            Check(stored.TaskbarFlags == 1 && stored.Regions.Count == 2,
                "C# snapshot helper creates and atomically replaces an existing record");
        } finally {
            if (File.Exists(snapshotPath)) File.Delete(snapshotPath);
            if (File.Exists(snapshotPath + ".tmp")) File.Delete(snapshotPath + ".tmp");
        }

        // Explorer taskbar shortcut matcher. Exact matching keeps unrelated
        // Win chords and a lone Win tap out of the suppression path.
        Check(TaskbarShortcutPolicy.Matches(0x54, false, false, false, true), "Win+T");
        Check(TaskbarShortcutPolicy.Matches(0x54, true, false, false, true), "Win+Shift+T");
        Check(!TaskbarShortcutPolicy.Matches(0x54, false, true, false, true), "Win+Ctrl+T is not a taskbar chord");
        Check(!TaskbarShortcutPolicy.Matches(0x54, false, false, true, true), "Win+Alt+T is not a taskbar chord");
        Check(TaskbarShortcutPolicy.Matches(0x42, false, false, false, true), "Win+B");
        Check(!TaskbarShortcutPolicy.Matches(0x42, true, false, false, true), "Win+Shift+B is left alone");
        for (int i = 0; i <= 9; i++) {
            int digit = 0x30 + i;
            Check(TaskbarShortcutPolicy.Matches(digit, false, false, false, true), "Win+digit");
            Check(TaskbarShortcutPolicy.Matches(digit, true, false, false, true), "Win+Shift+digit");
            Check(TaskbarShortcutPolicy.Matches(digit, false, true, false, true), "Win+Ctrl+digit");
            Check(TaskbarShortcutPolicy.Matches(digit, false, false, true, true), "Win+Alt+digit");
            Check(!TaskbarShortcutPolicy.Matches(digit, true, true, false, true),
                "Win+Ctrl+Shift+digit is not a listed taskbar chord");
            Check(!TaskbarShortcutPolicy.Matches(digit, true, false, true, true),
                "Win+Shift+Alt+digit is not a listed taskbar chord");
            Check(!TaskbarShortcutPolicy.Matches(digit, false, true, true, true),
                "Win+Ctrl+Alt+digit is not a listed taskbar chord");
            Check(!TaskbarShortcutPolicy.Matches(digit, true, true, true, true),
                "three modifiers are not a listed taskbar chord");
            Check(!TaskbarShortcutPolicy.Matches(digit, false, false, false, false), "digit without Win");
        }
        Check(TaskbarShortcutPolicy.Matches(0x0D, false, false, true, true), "Win+Alt+Enter");
        Check(!TaskbarShortcutPolicy.Matches(0x0D, false, false, false, true), "Win+Enter is left alone");
        Check(!TaskbarShortcutPolicy.Matches(0x0D, true, false, true, true), "Win+Shift+Alt+Enter is left alone");
        Check(!TaskbarShortcutPolicy.Matches(0x41, false, false, false, true), "Win+A is left alone");
        Check(!TaskbarShortcutPolicy.Matches(0x4E, false, false, false, true), "Win+N is left alone");
        Check(!TaskbarShortcutPolicy.Matches(0x4C, false, false, false, true), "Win+L is left alone");
        Check(!TaskbarShortcutPolicy.Matches(0x5B, false, false, false, true), "lone Win is left alone");

        var filter = new TaskbarShortcutFilter();
        Check(filter.Handle(0x54, false, false, false, false, false, true), "filter swallows a Win+T key-down");
        Check(filter.Handle(0x54, false, false, false, false, false, true), "filter swallows a Win+T auto-repeat");
        Check(filter.Handle(0x54, true, false, false, false, false, false),
            "filter swallows the key-up after Win was released first");
        Check(!filter.Handle(0x54, true, false, false, false, false, true), "unstored key-up passes");
        Check(!filter.Handle(0x54, false, true, false, false, false, true), "injected chord passes");
        Check(!filter.Handle(0x41, false, false, false, false, false, true), "unrelated chord passes");
        Check(filter.Handle(0x31, false, false, false, false, false, true), "filter swallows Win+1 down");
        Check(filter.Handle(0x31, true, false, false, false, false, false), "filter swallows Win+1 up");
        filter.Reset();
        Check(!filter.Handle(0x31, true, false, false, false, false, false), "reset forgets swallowed keys");

        int installs = 0, removes = 0;
        var shortcutHook = new TaskbarShortcutHook(
            delegate(Native.LowLevelKeyboardProc callback) { installs++; return new IntPtr(7); },
            delegate(IntPtr hook) { removes++; Check(hook == new IntPtr(7), "unhook identity"); });
        Check(!shortcutHook.Active && !shortcutHook.Installed, "shortcut hook starts uninstalled");
        Check(!shortcutHook.Handle(0x54, false, false, false, false, false, true),
            "inactive shortcut hook passes");
        Check(shortcutHook.Install() && shortcutHook.Installed && installs == 1, "shortcut hook install");
        Check(!shortcutHook.Active, "installed but inactive shortcut hook passes");
        shortcutHook.Activate();
        Check(shortcutHook.Active && shortcutHook.Handle(0x54, false, false, false, false, false, true),
            "active shortcut hook swallows");
        shortcutHook.Deactivate();
        Check(!shortcutHook.Active && !shortcutHook.Handle(0x54, false, false, false, false, false, true),
            "deactivation stops swallowing");
        shortcutHook.Activate();
        shortcutHook.Dispose();
        Check(!shortcutHook.Active && !shortcutHook.Installed && removes == 1, "dispose removes shortcut hook");
        shortcutHook.Dispose();
        Check(removes == 1, "shortcut hook dispose is idempotent");
        var failedHook = new TaskbarShortcutHook(
            delegate(Native.LowLevelKeyboardProc callback) { return IntPtr.Zero; },
            delegate(IntPtr hook) { throw new Exception("failed hook must not be removed"); });
        Check(!failedHook.Install() && !failedHook.Installed, "failed shortcut hook install stays unbound");
        failedHook.Activate();
        Check(!failedHook.Active, "failed shortcut hook cannot activate");
        failedHook.Dispose();
        return assertions;
    }
}
