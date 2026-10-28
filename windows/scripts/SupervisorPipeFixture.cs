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
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, System.Text.StringBuilder command, IntPtr pa,
        IntPtr ta, bool inherit, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInformation process);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    public static int Main(string[] args) {
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
}
