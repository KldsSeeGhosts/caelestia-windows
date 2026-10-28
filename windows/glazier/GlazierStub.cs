using System;
using System.IO;

internal static class GlazierStub {
    [STAThread]
    private static void Main(string[] args) {
        var marker = Environment.GetEnvironmentVariable("GLAZIER_DISMISS_MARKER");
        var result = System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName + "\n" + string.Join("\n", args);
        if (!string.IsNullOrEmpty(marker))
            result += "\n" + (File.Exists(marker) ? "hidden" : "visible");
        File.WriteAllText(Environment.GetEnvironmentVariable("GLAZIER_STUB_OUTPUT"), result);
    }
}
