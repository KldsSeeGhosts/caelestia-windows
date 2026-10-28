using System;
using System.IO;

internal static class GlazierStub {
    [STAThread]
    private static void Main(string[] args) {
        File.WriteAllText(Environment.GetEnvironmentVariable("GLAZIER_STUB_OUTPUT"),
            System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName + "\n" + string.Join("\n", args));
    }
}
