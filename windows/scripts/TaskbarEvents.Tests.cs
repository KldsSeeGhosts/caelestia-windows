// Fake-only tests. No hook or taskbar native function is called.
using System;
using System.Collections.Generic;
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
                MonotonicTicks = ticks + 3, Asynchronous = true, RequestAccepted = true,
                VisibleAfter = null, ShowToRequestMilliseconds = 3 };
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
            actions[1].ShowObservedTicks == 100 && actions[1].ShowToRequestMilliseconds == 3 &&
            actions[1].Asynchronous && actions[1].VisibleAfter == null &&
            actions[1].ShowToHideMilliseconds == null,
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
        // A sustained same-window fight is bounded, even when asynchronous
        // requests have not completed and duplicate shows remain visible.
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
            policy.RememberRequest(first, tick + 1);
        }
        policy.Reset();
        for (int i = 0; i < 11; i++) {
            policy.RememberRequest(first, i * 10);
            Check(policy.AllowImmediate(first, i * 10 + 1, out entered) && !entered, "bounded rapid recurrence");
        }
        policy.RememberRequest(other, 111);
        Check(policy.AllowImmediate(other, 112, out entered) && !entered, "other HWND has its own counter");
        Check(policy.AllowImmediate(newOwner, 112, out entered) && !entered, "owner change has its own counter");
        policy.RememberRequest(first, 120);
        Check(!policy.AllowImmediate(first, 121, out entered) && entered, "twelfth recurrence enters backoff");
        Check(!policy.AllowImmediate(other, 122, out entered) && !entered, "global backoff is quiet");
        Check(policy.AllowImmediate(other, 5121, out entered) && !entered, "backoff ends at deadline");
        policy.Reset();
        policy.RememberRequest(first, 0);
        Check(policy.AllowImmediate(first, 76, out entered) && !entered, "75 ms boundary excludes slower events");
        policy.RememberRequest(first, 200);
        Check(policy.AllowImmediate(first, 275, out entered) && !entered, "75 ms boundary includes rapid event");
        policy.Reset();
        for (int i = 0; i < 11; i++) {
            policy.RememberRequest(first, i * 10);
            Check(policy.AllowImmediate(first, i * 10 + 1, out entered), "rolling window setup");
        }
        policy.RememberRequest(first, 2200);
        Check(policy.AllowImmediate(first, 2201, out entered) && !entered, "old recurrences expire");

        var asyncAction = Native.AsyncHide(first, 100,
            delegate(Bar bar) { return true; }, delegate { return 110; });
        Check(asyncAction.Asynchronous && asyncAction.RequestAccepted == true &&
            asyncAction.VisibleAfter == null && asyncAction.ShowToHideMilliseconds == null &&
            asyncAction.ShowObservedTicks == 100 && asyncAction.MonotonicTicks == 110 &&
            asyncAction.ShowToRequestMilliseconds == 10 * 1000.0 / System.Diagnostics.Stopwatch.Frequency,
            "async request records acceptance and request timing, not completion");
        var rejected = Native.AsyncHide(first, 100, delegate(Bar bar) { return false; }, delegate { return 110; });
        Check(rejected.RequestAccepted == false && rejected.VisibleAfter == null, "failed post remains unconfirmed");
        Check(Native.AsyncHide(first, 100, delegate(Bar bar) { return null; }, delegate { return 110; }) == null,
            "owner recheck failure issues no action");
        int rejectedRequests = 0, backoffs = 0;
        var failedHandler = new TaskbarShowHandler(new TaskbarShowPolicy(1000),
            delegate(IntPtr hwnd, uint owner) { return first; },
            delegate(Bar bar, long ticks) {
                rejectedRequests++;
                return new TaskbarAction { Operation = "hide", Asynchronous = true,
                    RequestAccepted = false, MonotonicTicks = ticks };
            },
            delegate(TaskbarAction action) { if (action.Operation == "event-backoff") backoffs++; });
        for (int i = 0; i < 20; i++) failedHandler.Handle(42, new IntPtr(1), 0, 0, i * 10);
        Check(rejectedRequests == 12 && backoffs == 1, "failed async requests are bounded too");
        return assertions;
    }
}
