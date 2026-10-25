// Test-only Win32 input. Never loaded by the shell or its plugins.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

namespace Caelestia.InputTest {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        public struct Point { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)]
        private struct MouseInput {
            public int X, Y;
            public uint Data, Flags, Time;
            public UIntPtr ExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardInput {
            public ushort Key, Scan;
            public uint Flags, Time;
            public UIntPtr ExtraInfo;
        }
        [StructLayout(LayoutKind.Explicit)]
        private struct Input {
            [FieldOffset(0)] public uint Type;
            [FieldOffset(8)] public MouseInput Mouse;
            [FieldOffset(8)] public KeyboardInput Keyboard;
        }
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        private delegate bool EnumWindowCallback(IntPtr window, IntPtr param);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowCallback callback, IntPtr param);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

        private static void Send(Input input) {
            if (IntPtr.Size != 8) throw new InvalidOperationException("Use native x64 PowerShell.");
            if (SendInput(1, new Input[] { input }, Marshal.SizeOf(typeof(Input))) != 1)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SendInput failed");
        }
        public static void Move(int x, int y) {
            int left = GetSystemMetrics(76), top = GetSystemMetrics(77);
            int width = GetSystemMetrics(78), height = GetSystemMetrics(79);
            if (x < left || x >= left + width || y < top || y >= top + height)
                throw new ArgumentOutOfRangeException("Pointer outside virtual desktop");
            Send(new Input { Mouse = new MouseInput {
                X = (int)Math.Round((x - left) * 65535.0 / (width - 1)),
                Y = (int)Math.Round((y - top) * 65535.0 / (height - 1)),
                Flags = 0x0001 | 0x8000 | 0x4000 // MOVE, ABSOLUTE, VIRTUALDESK
            }});
        }
        public static void Button(bool down) {
            Send(new Input { Mouse = new MouseInput { Flags = down ? 0x0002u : 0x0004u } });
        }
        public static void Click(int x, int y) {
            Move(x, y);
            // Allow the backend's asynchronously evaluated mask to settle.
            // Stationary hover is tested separately, without this delay/move.
            Thread.Sleep(100);
            Button(true);
            Button(false);
        }
        public static void Key(ushort key) {
            Send(new Input { Type = 1, Keyboard = new KeyboardInput { Key = key } });
            Send(new Input { Type = 1, Keyboard = new KeyboardInput { Key = key, Flags = 2 } });
        }
        public static void Drag(int x1, int y1, int x2, int y2) {
            Move(x1, y1);
            Thread.Sleep(100);
            Button(true);
            try {
                for (int i = 1; i <= 24; i++) {
                    Move(x1 + (x2 - x1) * i / 24, y1 + (y2 - y1) * i / 24);
                    Thread.Sleep(12);
                }
            } finally { Button(false); }
        }
        public static uint ForegroundProcess() {
            uint process;
            GetWindowThreadProcessId(GetForegroundWindow(), out process);
            return process;
        }
        public static IntPtr WindowForProcess(uint process) {
            IntPtr result = IntPtr.Zero;
            EnumWindows(delegate(IntPtr window, IntPtr param) {
                uint candidate;
                GetWindowThreadProcessId(window, out candidate);
                if (candidate != process || !IsWindowVisible(window)) return true;
                result = window;
                return false;
            }, IntPtr.Zero);
            return result;
        }
    }
}
