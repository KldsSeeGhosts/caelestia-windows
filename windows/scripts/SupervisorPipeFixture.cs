using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class SupervisorPipeFixture {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, xSize, ySize, xCount, yCount, fill, flags;
        public short show, reserved2;
        public IntPtr reservedPointer, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)]
    struct Msg {
        public IntPtr Window;
        public uint Message;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int X, Y, Private;
    }
    delegate bool WindowCallback(IntPtr window, IntPtr data);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, System.Text.StringBuilder command, IntPtr pa,
        IntPtr ta, bool inherit, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInformation process);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(int exStyle, string className, string title, int style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetProp(IntPtr window, IntPtr name, IntPtr value);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr GetProp(IntPtr window, IntPtr name);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern int GetMessage(out Msg message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Msg message);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Msg message);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern ushort GlobalAddAtom(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern ushort GlobalFindAtom(string name);

    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }

    // The tiler's park tag. Parking moves a window off screen and stores the
    // rectangle to restore as x | y << 16 | width << 32 | height << 48.
    const string ParkProperty = "QuickshellTilingParked";
    const int WsPopup = unchecked((int)0x80000000), WsExToolWindow = 0x00000080;
    const uint ParkFlags = 0x0004 | 0x0010 | 0x0200 | 0x4000; // no z-order, no activate, async

    public static int Main(string[] args) {
        if (args.Length == 0) return 2;
        // Window state is global, so these modes take no directory.
        if (args[0] == "state") return State(args[1]);
        if (args[0] == "list") return List();
        string directory = args[1];
        if (args[0] == "clean") {
            File.WriteAllText(Path.Combine(directory, "clean-" + Process.GetCurrentProcess().Id), "");
            Console.Out.WriteLine("stdout-line");
            Console.Out.Write("stdout-tail");
            Console.Error.WriteLine("stderr-line");
            Console.Error.Write("stderr-tail");
            return 0;
        }
        if (args[0] == "crash") {
            File.WriteAllText(Path.Combine(directory, "crash-" + Process.GetCurrentProcess().Id), "");
            Console.Out.WriteLine("crash-line-" + Process.GetCurrentProcess().Id);
            return 1;
        }
        if (args[0] == "park") {
            var window = new IntPtr(Int64.Parse(args[2]));
            ulong packed = UInt64.Parse(args[3]);
            var atom = GlobalAddAtom(ParkProperty);
            var parked = atom != 0 && SetWindowPos(window, IntPtr.Zero, Int32.Parse(args[4]), Int32.Parse(args[5]),
                (int)((packed >> 32) & 0xFFFF), (int)((packed >> 48) & 0xFFFF), ParkFlags) &&
                SetProp(window, new IntPtr(atom), new IntPtr((long)packed)) != IntPtr.Zero;
            if (!parked) return 3;
            File.WriteAllText(Path.Combine(directory, "parked-" + Process.GetCurrentProcess().Id),
                window.ToInt64().ToString());
            // The shell died with the window parked.
            return 1;
        }
        if (args[0] == "window") {
            // Hidden: these fixtures park and rescue their own windows only.
            // Per-monitor aware, so the packed physical rectangle lands exactly.
            SetThreadDpiAwarenessContext(new IntPtr(-4));
            var target = CreateWindowEx(WsExToolWindow, "STATIC", "parked",
                WsPopup, 100, 100, 320, 200, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            // The control is off screen and never tagged: a rescue must leave it there.
            var control = CreateWindowEx(WsExToolWindow, "STATIC", "control",
                WsPopup, -32000, -31800, 320, 200, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (target == IntPtr.Zero || control == IntPtr.Zero) return 3;
            File.WriteAllText(Path.Combine(directory, "window-" + Process.GetCurrentProcess().Id),
                target.ToInt64().ToString());
            File.WriteAllText(Path.Combine(directory, "control-" + Process.GetCurrentProcess().Id),
                control.ToInt64().ToString());
            Msg message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
            return 0;
        }
        if (args[0] == "hold") {
            if (args.Length > 2 && args[2] == "require-pipes" &&
                (GetFileType(GetStdHandle(-11)) != 3 || GetFileType(GetStdHandle(-12)) != 3)) return 4;
            File.WriteAllText(Path.Combine(directory, "holder-" + Process.GetCurrentProcess().Id),
                Process.GetCurrentProcess().Id.ToString());
            Thread.Sleep(60000);
            return 0;
        }
        var startup = new StartupInfo { cb = Marshal.SizeOf(typeof(StartupInfo)), flags = 0x100,
            stdin = GetStdHandle(-10), stdout = GetStdHandle(-11), stderr = GetStdHandle(-12) };
        var command = new System.Text.StringBuilder("\"" + Process.GetCurrentProcess().MainModule.FileName
            + "\" hold \"" + directory + "\" require-pipes");
        ProcessInformation child;
        if (!CreateProcess(null, command, IntPtr.Zero, IntPtr.Zero, true, 0x08000000,
            IntPtr.Zero, null, ref startup, out child)) return 2;
        CloseHandle(child.process); CloseHandle(child.thread);
        File.WriteAllText(Path.Combine(directory, "child-" + Process.GetCurrentProcess().Id),
            child.pid.ToString());
        for (int i = 0; i < 500 && !File.Exists(Path.Combine(directory, "holder-" + child.pid)); i++)
            Thread.Sleep(10);
        return File.Exists(Path.Combine(directory, "holder-" + child.pid)) ? 1 : 3;
    }

    static int State(string text) {
        var window = new IntPtr(Int64.Parse(text));
        var atom = GlobalFindAtom(ParkProperty);
        // Read in physical pixels, the space the tiler packs and restores.
        SetThreadDpiAwarenessContext(new IntPtr(-4)); // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        Rect rect;
        GetWindowRect(window, out rect);
        Console.Out.WriteLine("onscreen=" + (MonitorFromWindow(window, 0) != IntPtr.Zero ? 1 : 0));
        Console.Out.WriteLine("prop=" + (atom != 0 && GetProp(window, new IntPtr(atom)) != IntPtr.Zero ? 1 : 0));
        Console.Out.WriteLine("rect=" + rect.Left + "," + rect.Top + "," + rect.Right + "," + rect.Bottom);
        return 0;
    }

    static int List() {
        var atom = GlobalFindAtom(ParkProperty);
        if (atom == 0) return 0;
        var name = new IntPtr(atom);
        EnumWindows(delegate(IntPtr window, IntPtr data) {
            if (GetProp(window, name) == IntPtr.Zero) return true;
            Console.Out.WriteLine("parked=" + window.ToInt64());
            return true;
        }, IntPtr.Zero);
        return 0;
    }
}
