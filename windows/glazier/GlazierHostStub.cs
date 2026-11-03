// Isolated tray-host double for the shell launch contract. Never captures,
// records, registers a hotkey or shows a window.
using System;
using System.IO;
using System.Linq;

internal static class GlazierHostStub {
    [STAThread]
    private static void Main(string[] args) {
        if (args.Contains("--status")) {
            var running = Environment.GetEnvironmentVariable("GLAZIER_STUB_RUNNING") == "1";
            File.AppendAllText(Environment.GetEnvironmentVariable("GLAZIER_PROBE_OUTPUT"),
                string.Join(" ", args) + "\n");
            Console.WriteLine(running
                ? "{\"version\":1,\"ok\":true,\"host_id\":\"stub\",\"state\":\"idle\",\"elapsed_ms\":0,\"output_directory\":\"\",\"events\":[]}"
                : "{\"version\":1,\"ok\":false,\"error\":\"Glazier control v1 is not available\"}");
            Environment.Exit(running ? 0 : 1);
        }
        File.AppendAllText(Environment.GetEnvironmentVariable("GLAZIER_HOST_OUTPUT"),
            System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName + "\n"
            + (args.Length == 0 ? "" : string.Join("\n", args) + "\n"));
    }
}
