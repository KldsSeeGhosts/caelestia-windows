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
                MonotonicTicks = ticks + 3, ShowToHideMilliseconds = 3 };
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
            actions[1].ShowObservedTicks == 100 && actions[1].ShowToHideMilliseconds == 3,
            "correlated monotonic and UTC records");
        handler.Handle(42, new IntPtr(2), 0, 0, 200);
        handler.Handle(42, new IntPtr(1), 0, 0, 300);
        handler.Handle(42, new IntPtr(2), 0, 0, 400);
        handler.Handle(42, new IntPtr(1), 0, 0, 500);
        handler.Handle(42, new IntPtr(1), 0, 0, 600);
        handler.Handle(42, new IntPtr(1), 0, 0, 700);
        Check(hides == 5, "sixth show starts backoff and later shows do not hide");
        Check(actions.FindAll(a => a.Operation == "show").Count == 7 &&
            actions.FindAll(a => a.Operation == "event-backoff").Count == 1,
            "record each show and only one backoff");
        handler.Handle(42, new IntPtr(1), 0, 0, 5600);
        Check(hides == 6, "immediate suppression resumes at backoff deadline");
        visible = false;
        handler.Handle(42, new IntPtr(2), 0, 0, 5700);
        Check(hides == 6 && actions[actions.Count - 1].Operation == "show", "record delayed show without redundant hide");
        policy.Reset();
        visible = true;
        handler.Handle(42, new IntPtr(2), 0, 0, 5800);
        Check(hides == 7, "restart resets policy");
        policy.Reset();
        bool entered;
        for (int i = 0; i < 5; i++) Check(policy.AllowImmediate(i * 100, out entered), "initial burst");
        Check(policy.AllowImmediate(2400, out entered) && !entered, "rolling window expires old shows");
        return assertions;
    }
}
