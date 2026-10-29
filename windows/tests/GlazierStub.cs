// Isolated protocol double. Never loads WGC, Media Foundation, audio or tray UI.
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;

class GlazierStub
{
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static Dictionary<string, object> State;
    static string Root;

    static void Event(string type, string path = null, string message = null)
    {
        int sequence = Convert.ToInt32(State["event_sequence"]) + 1;
        State["event_sequence"] = sequence;
        var events = new List<object>();
        foreach (object item in (IEnumerable)State["events"]) events.Add(item);
        events.Add(new Dictionary<string, object> {
            { "sequence", sequence }, { "type", type }, { "output_path", path }, { "message", message }
        });
        State["events"] = events.ToArray();
    }

    static int Main(string[] args)
    {
        Root = Environment.GetEnvironmentVariable("GLAZIER_STUB_ROOT");
        if (String.IsNullOrEmpty(Root)) return 2;
        Directory.CreateDirectory(Root);
        using (var mutex = new Mutex(false, @"Local\GlazierStub." + new DirectoryInfo(Root).Name))
        {
            if (!mutex.WaitOne(5000)) return 3;
            try
            {
                string file = Path.Combine(Root, "state.json");
                State = File.Exists(file)
                    ? Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(file))
                    : new Dictionary<string, object> {
                        { "version", 1 }, { "ok", true }, { "host_id", "stub-session" },
                        { "state", "idle" }, { "elapsed_ms", 0 }, { "system_sound", false }, { "mic", false },
                        { "output_directory", Path.Combine(Root, "output") }, { "events", new object[0] },
                        { "event_sequence", 0 }, { "last_record_args", new string[0] }
                    };
                string command = args.Length > 0 ? args[0] : "";
                switch (command)
                {
                    case "--record":
                        State["last_record_args"] = args;
                        State["elapsed_ms"] = 1250;
                        State["state"] = Array.IndexOf(args, "--fullscreen") >= 0 ? "recording" : "selecting";
                        State["region_ticks"] = 0;
                        State["system_sound"] = Array.IndexOf(args, "--system-sound") >= 0
                            && args[Array.IndexOf(args, "--system-sound") + 1] == "on";
                        State["mic"] = Array.IndexOf(args, "--mic") >= 0
                            && args[Array.IndexOf(args, "--mic") + 1] == "on";
                        if ((string)State["state"] == "recording") Event("started");
                        break;
                    case "--pause":
                        if ((string)State["state"] == "recording") { State["state"] = "paused"; Event("paused"); }
                        break;
                    case "--resume":
                        if ((string)State["state"] == "paused") { State["state"] = "recording"; Event("resumed"); }
                        break;
                    case "--stop":
                        if ((string)State["state"] == "recording" || (string)State["state"] == "paused")
                            State["state"] = "finalizing";
                        else if ((string)State["state"] == "selecting" || (string)State["state"] == "ready")
                        { State["state"] = "idle"; Event("cancelled"); }
                        break;
                    case "--fixture-finish":
                        State["state"] = "idle";
                        string path = Path.Combine((string)State["output_directory"], "recording-stub.mp4");
                        File.WriteAllText(path, "fixture only, not a real video");
                        Event("finished", path);
                        break;
                    case "--fixture-error":
                        State["state"] = "idle"; Event("error", null, "Simulated encoder error");
                        break;
                    case "--fixture-tray":
                        State["state"] = "recording"; State["elapsed_ms"] = 42000; Event("started");
                        break;
                    case "--fixture-cancel":
                        State["state"] = "idle"; Event("cancelled");
                        break;
                    case "--fixture-offline":
                        State["offline"] = true;
                        break;
                    case "--status":
                        if ((string)State["state"] == "selecting" || (string)State["state"] == "ready")
                        {
                            int ticks = Convert.ToInt32(State["region_ticks"]) + 1;
                            State["region_ticks"] = ticks;
                            State["state"] = ticks < 2 ? "ready" : "recording";
                            if (ticks == 2) Event("started");
                        }
                        break;
                    default: return 4;
                }
                Directory.CreateDirectory((string)State["output_directory"]);
                File.WriteAllText(file, Json.Serialize(State));
                if (State.ContainsKey("offline"))
                {
                    Console.WriteLine("{\"version\":1,\"ok\":false,\"error\":\"Glazier control v1 is not available\"}");
                    return 1;
                }
                Console.WriteLine(Json.Serialize(State));
                return 0;
            }
            finally { mutex.ReleaseMutex(); }
        }
    }
}
