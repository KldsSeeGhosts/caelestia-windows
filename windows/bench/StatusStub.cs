// Test-only status client. Cannot capture, control a host or access user data.
using System;
using System.IO;
class StatusStub {
    static int Main(string[] args) {
        if (args.Length != 1 || args[0] != "--status") return 2;
        File.AppendAllText(Environment.GetEnvironmentVariable("CAELESTIA_IDLE_LOG"),
            (DateTime.UtcNow.Ticks / 10000 - 62135596800000L) + "\n");
        Console.WriteLine("{\"version\":1,\"ok\":true,\"host_id\":\"synthetic\",\"state\":\"idle\",\"elapsed_ms\":0,\"output_directory\":\"C:/synthetic/recordings\",\"events\":[]}");
        return 0;
    }
}
