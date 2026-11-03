// Isolated Glazier tray-host double. It creates the real top-level window
// class the shell identifies and exits through WM_CLOSE; it never captures,
// records, registers a hotkey or shows a visible window.
using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

internal static class GlazierWindowStub {
    private const uint WM_CLOSE = 0x0010;
    private const uint WM_DESTROY = 0x0002;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    private delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassEx(ref WNDCLASSEX windowClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(uint exStyle, string className, string windowName,
        uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG msg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG msg);

    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int code);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string name);

    private static readonly WndProc Proc = WindowProc;

    private static void Marker(string variable, string text) {
        var path = Environment.GetEnvironmentVariable(variable);
        if (!String.IsNullOrEmpty(path))
            File.WriteAllText(path, text);
    }

    private static IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == WM_CLOSE) {
            Marker("GLAZIER_WINDOW_CLOSED", "closed");
            DestroyWindow(hwnd);
            return IntPtr.Zero;
        }
        if (msg == WM_DESTROY) {
            PostQuitMessage(0);
            return IntPtr.Zero;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private static void Main(string[] args) {
        if (args.Contains("--status")) {
            var running = FindWindow("GlazierHost", null) != IntPtr.Zero;
            Console.WriteLine(running
                ? "{\"version\":1,\"ok\":true,\"host_id\":\"stub\",\"state\":\"idle\",\"elapsed_ms\":0,\"output_directory\":\"\",\"events\":[]}"
                : "{\"version\":1,\"ok\":false,\"error\":\"Glazier control v1 is not available\"}");
            Environment.Exit(running ? 0 : 1);
        }

        var output = Environment.GetEnvironmentVariable("GLAZIER_HOST_OUTPUT");
        if (!String.IsNullOrEmpty(output)) {
            File.WriteAllText(output, System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName
                + "\n" + (args.Length == 0 ? "" : String.Join("\n", args) + "\n"));
        }

        var windowClass = new WNDCLASSEX {
            cbSize = (uint)Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(Proc),
            hInstance = GetModuleHandle(null),
            lpszClassName = "GlazierHost"
        };
        RegisterClassEx(ref windowClass);
        CreateWindowEx(0, "GlazierHost", "Glazier", 0, 0, 0, 0, 0,
            IntPtr.Zero, IntPtr.Zero, windowClass.hInstance, IntPtr.Zero);
        Marker("GLAZIER_WINDOW_PID", System.Diagnostics.Process.GetCurrentProcess().Id.ToString());

        MSG message;
        while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }
    }
}
