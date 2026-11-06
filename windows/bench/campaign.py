"""Campaign controls for ShellBench, not a second measurement framework."""
import ctypes as C
from ctypes import wintypes as W
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time
import uuid

HERE = Path(__file__).resolve().parent


def replay(path, bench):
    data = bench.read(path)
    if data.get("error") or data.get("evidenceClass") == "fixture":
        raise ValueError("Failed acquisitions and fixtures cannot qualify a campaign.")
    if not data.get("protocol", {}).get("rawRequired"):
        raise ValueError("Campaign evidence requires replayable raw observations.")
    result = bench.summarize(data)
    if result != data.get("summary"):
        raise ValueError("Stored summary does not reproduce from raw work.")
    if not 0 < data.get("wallSeconds", 0) <= 580:
        raise ValueError("Missing or out-of-budget acquisition time.")
    if data.get("plantB", "None") != "None":
        percent = data.get("plantPercent", 0)
        if not math.isfinite(percent) or not 0 < percent <= 100:
            raise ValueError("Added-cost qualification requires a positive finite plant size.")
        area = data["plantB"].lower()
        if area in ("tiling", "tracker", "audio", "media", "tray", "notifications", "quota"):
            for trial in data["trials"]:
                entries = ([trial["raw"][area]] if area in ("tiling", "tracker")
                           else [r for r in trial["raw"].get("services", []) if r["area"] == area])
                if not entries:
                    raise ValueError("Added-cost work has no raw operation evidence.")
                for raw in entries:
                    expected = raw["operations"] * (1 + percent / 100 if trial["side"] == "B" else 1)
                    if abs(raw["actualOperations"] - expected) > 1:
                        raise ValueError("Added-cost operation count does not match the declared plant.")
    return data, result


def environment(data):
    """Qualification is local to this configuration, not a universal floor."""
    p = data["protocol"]
    return {key: p.get(key) for key in
            ("version", "order", "mode", "runs", "cachePolicy", "floorsPercent",
             "settingsSha256", "filesSha256", "warmupSeconds", "idleSeconds",
             "panelWarmupSeconds", "panelCycles", "selectedAreas", "instrumentation")} | {
        "machine": {key: data["machine"].get(key) for key in ("id", "qtVersion", "qtCoreSha256", "qtRuntimeFiles")}}


def payload(side):
    return {k: side[k] for k in ("revision", "backendRevision", "executableSha256", "nativeModules",
                                 "buildRecordSha256", "runtimeFiles")}


def qualify(args, bench):
    output = bench.external_output(args.output)
    output.mkdir(parents=True)
    receipts, observations, seen = [], [], set()
    context = None
    for group, paths in (("aa", args.aa), ("added", args.added)):
        for path in paths:
            digest = bench.sha(path)
            if digest in seen:
                raise ValueError("A repeated acquisition is not independent qualification.")
            seen.add(digest)
            data, summary = replay(path, bench)
            if payload(data["sides"]["A"]) != payload(data["sides"]["B"]):
                raise ValueError("Controls require identical unmodified A/A source and native payloads.")
            current = environment(data)
            if context is not None and context != current:
                raise ValueError("Qualification configuration, ordering or tooling changed.")
            context = current
            if (group == "aa") != (data["plantB"] == "None"):
                raise ValueError("A/A must be unplanted; added-cost controls must name their plant.")
            receipts.append({"path": str(Path(path).resolve()), "sha256": digest, "group": group})
            observations.append((group, data, summary))
    names = set().union(*(r["metrics"] for _, _, r in observations))
    metrics = {}
    for name in sorted(names):
        aa = [r["metrics"].get(name) for g, _, r in observations if g == "aa"]
        planted = [(d["plantB"], d.get("plantPercent"), r["metrics"][name])
                   for g, d, r in observations if g == "added" and name in r["metrics"]
                   and affected(d["plantB"], name)]
        # Report every unresolved outcome and miss. Never silently drop it.
        groups = {}
        for plant, nominal, metric in planted:
            groups.setdefault((plant, nominal), []).append(metric)
        detected = [{"plant": plant, "nominalPercent": nominal,
                     "repeats": len(values), "outcomes": [m["verdict"] for m in values],
                     "observedPercent": [m["deltaPercent"] for m in values],
                     "resolutionPercent": [m["resolutionPercent"] for m in values]}
                    for (plant, nominal), values in sorted(groups.items())]
        passed = [g for g in detected if g["repeats"] >= 3
                  and all(v == "regressed" for v in g["outcomes"])]
        metrics[name] = {
            "qualified": len(aa) >= 3 and all(m and m["verdict"] == "same" for m in aa) and bool(passed),
            "aaOutcomes": [m["verdict"] if m else "missing" for m in aa],
            "addedCost": detected,
            "smallestTestedDetectedNominalPercent": min(g["nominalPercent"] for g in passed) if passed else None,
            "limits": "Only tested plants on this configuration. No extrapolation to smaller effects or whole-shell savings."}
    result = {"schemaVersion": 1, "protocol": bench.PROTOCOL, "environment": context,
              "inputs": receipts, "metrics": metrics,
              "status": "qualified" if metrics and all(m["qualified"] for m in metrics.values()) else "partial"}
    bench.write(output / "qualification.json", result)
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "qualified" else 3


def affected(plant, name):
    return ((plant in ("Resources", "Sensitivity") and name in ("privateMiB", "workingSetMiB"))
            or (plant in ("Panel", "Sensitivity") and name.startswith("panel."))
            or (plant in ("Reload", "Sensitivity") and name == "qmlReloadToReadyMs")
            or (plant == "Startup" and name == "coldStartToReadyMs")
            or (plant == "Update" and name == "isolatedActivationMs")
            or (plant in ("Tiling", "Sensitivity") and name.startswith("tiling."))
            or (plant == "Tracker" and name.startswith("tracker."))
            or (plant == "Scheme" and name.startswith("scheme."))
            or (plant in ("audio", "media", "tray", "notifications", "quota") and name.startswith(plant + ".")))


def gate(args, bench):
    data, summary = replay(args.results, bench)
    if data["plantB"] != "None":
        raise ValueError("A planted acquisition cannot demonstrate a production improvement.")
    qualification = bench.read(args.qualification)
    if qualification["environment"] != environment(data):
        raise ValueError("Qualification does not apply to this environment/protocol/configuration.")
    # Re-read qualification inputs. A stale or hand-edited verdict is not evidence.
    for record in qualification["inputs"]:
        if bench.sha(record["path"]) != record["sha256"]:
            raise ValueError("Qualification input changed.")
        replay(record["path"], bench)
    metrics = summary["metrics"]
    if any(not qualification["metrics"].get(n, {}).get("qualified") for n in metrics):
        raise ValueError("A selected metric lacks independent A/A and added-cost qualification.")
    controls, digests = [], set()
    for record in qualification["inputs"]:
        if record["sha256"] in digests:
            raise ValueError("Repeated qualification acquisition.")
        digests.add(record["sha256"])
        control, verdict = replay(record["path"], bench)
        if environment(control) != environment(data) or payload(control["sides"]["A"]) != payload(control["sides"]["B"]):
            raise ValueError("A qualification control has different configuration or nonidentical payloads.")
        if record["group"] not in ("aa", "added") or (record["group"] == "aa") != (control["plantB"] == "None"):
            raise ValueError("Qualification control group does not match its recorded plant.")
        controls.append((record["group"], control, verdict))
    for name in metrics:
        aa = [v["metrics"].get(name) for g, _, v in controls if g == "aa"]
        plants = {}
        for group, control, verdict in controls:
            if group == "added" and affected(control["plantB"], name) and name in verdict["metrics"]:
                plants.setdefault((control["plantB"], control["plantPercent"]), []).append(verdict["metrics"][name])
        if (len(aa) < 3 or not all(m and m["verdict"] == "same" for m in aa)
                or not any(len(ms) >= 3 and all(m["verdict"] == "regressed" for m in ms) for ms in plants.values())):
            raise ValueError("Qualification verdict is not supported by independent raw controls.")
    accepted = summary["overall"] == args.expect and all(
        m["verdict"] in ("same", "improved") for m in metrics.values())
    print(json.dumps({"accepted": accepted, "overall": summary["overall"],
                      "metricVerdicts": {n: m["verdict"] for n, m in metrics.items()},
                      "scope": "Statistical confirmation only; absolute user benefit, correctness, full suite and desktop gates remain."}))
    return 0 if accepted else 3


def aggregate(rows, seconds):
    """Private commit is additive. Shared working sets deliberately are not."""
    if not rows or seconds <= 0:
        raise ValueError("zeroSamples or invalid observation duration")
    ids = [r["pid"] for r in rows]
    if len(ids) != len(set(ids)):
        raise ValueError("A helper appears twice.")
    if any(r["cpuSecondsDelta"] < 0 or r["privateBytes"] < 0 or r["handles"] < 0 for r in rows):
        raise ValueError("Counters regressed or process identity changed.")
    return {"privateCommitBytes": sum(r["privateBytes"] for r in rows),
            "handles": sum(r["handles"] for r in rows),
            "cpuCorePercent": 100 * sum(r["cpuSecondsDelta"] for r in rows) / seconds,
            "workingSetBytesByProcess": {str(r["pid"]): r["workingSet"] for r in rows},
            "workingSetTotal": None, "wakeups": None, "contextSwitches": None,
            "limits": "Private commit, not unique resident RAM. CPU is a diagnostic, not battery energy. Scheduling requires ETW."}


class ProcessReader:
    """Pinned handles prevent PID reuse from attributing a different process."""
    class Memory(C.Structure):
        _fields_ = [("cb", W.DWORD), ("faults", W.DWORD)] + [
            (n, C.c_size_t) for n in ("peakWorkingSet", "workingSet", "peakPaged", "paged",
                                      "peakNonpaged", "nonpaged", "pagefile", "peakPagefile", "private")]

    def __init__(self, manifest, bench):
        if os.name != "nt":
            raise ValueError("Windows process observation is unavailable on this host.")
        self.handles = []
        self.k = C.WinDLL("kernel32", use_last_error=True)
        self.p = C.WinDLL("psapi", use_last_error=True)
        self.k.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
        self.k.OpenProcess.restype = W.HANDLE
        self.k.CloseHandle.argtypes = [W.HANDLE]
        self.k.GetProcessTimes.argtypes = [W.HANDLE] + [C.POINTER(C.c_ulonglong)] * 4
        self.k.GetProcessHandleCount.argtypes = [W.HANDLE, C.POINTER(W.DWORD)]
        self.k.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]
        self.k.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
        self.p.GetProcessMemoryInfo.argtypes = [W.HANDLE, C.POINTER(self.Memory), W.DWORD]
        entries = manifest["processes"]
        if not entries or len({r["pid"] for r in entries}) != len(entries):
            raise ValueError("Explicit unique shell and owned-helper identities are required.")
        roots = [r for r in entries if r["role"] == "shell"]
        if len(roots) != 1 or any(r["role"] not in ("shell", "owned-helper") for r in entries):
            raise ValueError("Exactly one shell and explicitly owned helpers are required.")
        # Parentage is asserted by the external lifecycle owner, not inferred
        # from executable names. This monitor does not discover or kill helpers.
        self.coverage = manifest["ownershipEvidence"]
        if not self.coverage or not manifest["candidateIdentity"]:
            raise ValueError("Candidate identity and ownership evidence must be supplied.")
        try:
            for entry in entries:
                handle = self.k.OpenProcess(0x1000 | 0x400 | 0x100000, False, entry["pid"])
                if not handle:
                    raise C.WinError(C.get_last_error())
                self.handles.append((entry, handle))
                size, image = W.DWORD(32768), C.create_unicode_buffer(32768)
                if not self.k.QueryFullProcessImageNameW(handle, 0, image, C.byref(size)):
                    raise C.WinError(C.get_last_error())
                if bench.sha(image.value) != entry["imageSha256"]:
                    raise ValueError("Process image does not match the explicit manifest.")
                if self.times(handle)[0] != entry["creationTime100ns"]:
                    raise ValueError("Process PID was reused or the manifest is stale.")
        except Exception:
            self.close()
            raise

    def times(self, handle):
        values = [C.c_ulonglong() for _ in range(4)]
        if not self.k.GetProcessTimes(handle, *(C.byref(v) for v in values)):
            raise C.WinError(C.get_last_error())
        return [v.value for v in values]

    def sample(self):
        rows = []
        for entry, handle in self.handles:
            if self.k.WaitForSingleObject(handle, 0) != 258:
                raise ValueError("An observed process exited; ownership manifest requires refresh.")
            memory, handles = self.Memory(), W.DWORD()
            memory.cb = C.sizeof(memory)
            if not self.p.GetProcessMemoryInfo(handle, C.byref(memory), memory.cb):
                raise C.WinError(C.get_last_error())
            if not self.k.GetProcessHandleCount(handle, C.byref(handles)):
                raise C.WinError(C.get_last_error())
            created, _, kernel, user = self.times(handle)
            rows.append({"pid": entry["pid"], "creationTime100ns": created,
                         "cpuSeconds": (kernel + user) / 1e7, "privateBytes": memory.private,
                         "workingSet": memory.workingSet, "handles": handles.value})
        return rows

    def close(self):
        for _, handle in self.handles:
            self.k.CloseHandle(handle)
        self.handles.clear()


def monitor(args, bench):
    if not args.allow_process_observation:
        raise ValueError("Process observation requires explicit --allow-process-observation.")
    if not 600 < args.seconds <= 86400 or not math.isfinite(args.interval) or not 1 <= args.interval <= 60:
        raise ValueError("Longer-session workflow requires 601..86400 seconds and 1..60 second intervals.")
    output = bench.external_output(args.output)
    output.mkdir(parents=True)
    manifest = bench.read(args.manifest)
    result = {"schemaVersion": 1, "evidenceClass": "process-observation", "scoredBenchmark": False,
              "manifestSha256": bench.sha(args.manifest), "manifest": manifest, "samples": [],
              "complete": False, "growthVerdict": "unresolved",
              "limits": "Only explicitly listed persistent processes. Transient/unlisted helpers are not covered; no automatic leak or energy verdict."}
    reader = None
    started = time.monotonic()
    try:
        reader = ProcessReader(manifest, bench)
        initial = reader.sample()
        previous = {r["pid"]: r for r in initial}
        previous_time = time.monotonic()
        result["initial"] = initial
        while time.monotonic() - started < args.seconds:
            time.sleep(max(0, min(args.interval, args.seconds - (time.monotonic() - started))))
            sampling_started = time.monotonic()
            rows = reader.sample()
            sample_time = time.monotonic()
            elapsed = sample_time - previous_time
            for row in rows:
                row["cpuSecondsDelta"] = row["cpuSeconds"] - previous[row["pid"]]["cpuSeconds"]
            result["samples"].append({"elapsedSeconds": time.monotonic() - started, "processes": rows,
                                      "totals": aggregate(rows, elapsed),
                                      "collectionSeconds": time.monotonic() - sampling_started})
            previous, previous_time = {r["pid"]: r for r in rows}, sample_time
            bench.write(output / "monitor.json", result)
        if len(result["samples"]) < 2:
            raise ValueError("zeroSamples or incomplete longer-session observation")
        result["complete"] = True
    except Exception as error:
        result["error"] = str(error)
    finally:
        if reader:
            reader.close()
        result["wallSeconds"] = time.monotonic() - started
        bench.write(output / "monitor.json", result)
    return 0 if result["complete"] else 1


def profile(args, bench):
    """Prepare private, bounded trace acquisition. Never starts capture."""
    output = bench.external_output(args.output, [args.build, args.source, args.qt])
    output.mkdir(parents=True)
    wpr = shutil.which("wpr.exe")
    qt = Path(args.qt).resolve()
    candidates = [qt / "bin/qmlprofiler.exe", qt.parent.parent / "Tools/QtCreator/bin/qmlprofiler.exe"]
    on_path = shutil.which("qmlprofiler.exe")
    if on_path:
        candidates.append(Path(on_path))
    profiler = next((p for p in candidates if p.is_file()), None)
    result = {"schemaVersion": 1, "workflow": "explore/profile", "scoredBenchmark": False,
              "inspectionSha256": bench.sha(__file__),
              "seconds": args.seconds, "captureExecuted": False, "instrumentationOverhead": None,
              "overheadStatus": "not-measured", "qmlProfiler": str(profiler) if profiler else None,
              "wpr": wpr, "scenarioManifestSha256": bench.sha(HERE / "scenarios.json"),
              "refusals": [], "hotspots": [], "hotspotStatus": "requires-real-traces"}
    if not wpr:
        result["refusals"].append("WPR unavailable. Install Windows Performance Toolkit through its owner, not this tool.")
    else:
        result["wprSha256"] = bench.sha(wpr)
        result["wprStartHelp"] = bench.command([wpr, "-help", "start"], timeout=10)
        result["refusals"].append("Capture not authorized by inspection. Kernel stacks may require an already elevated operator; never auto-elevate.")
    if profiler:
        result["qmlProfilerSha256"] = bench.sha(profiler)
        result["qmlProfilerHelp"] = bench.command([profiler, "--help"], timeout=10)
    else:
        result["refusals"].append("QML profiler CLI not found. A Qt runtime alone does not establish profiler/debug support.")
    try:
        result["candidate"] = bench.identity(args.build, args.source)
    except Exception as error:
        result["refusals"].append("Immutable candidate unavailable: " + str(error))
    result["captureContract"] = {
        "owner": "One authorized Windows QA owner; explicit private output and no competing capture",
        "wpr": ["Use a unique -instancename for start and stop; never cancel an unowned session.",
                "GeneralProfile CPU stacks/CSwitch for attribution; GPU/DWM need suitable providers and symbols.",
                f"Record only {args.seconds} seconds, then stop the same instance. Retain failed/interrupted traces.",
                "Use the bounded Capture-WindowsTrace.ps1 adapter; the ten-minute scored harness never captures."],
        "qml": ["Check the recorded CLI help before choosing attach/record arguments.",
                "Require a loopback-only debug-enabled disposable process, no live installation or open remote debugger.",
                "Use Capture-QmlProfile.ps1 only after its interactive attach/flush contract is advertised in tool help.",
                "Export binding, signal, creation and rendering event costs with matched symbols/source.",
                "Missing debug support or events is blocked, not an empty successful profile."],
        "overhead": "Pair independent uninstrumented/instrumented runs with identical artifacts and scenarios. Report actual absolute/relative overhead and uncertainty, not guessed subtraction.",
        "ranking": "For each real stack/event: trace hash, symbol quality, total/self cost, whole-app fraction, scenario frequency, user benefit, risk/cost and correctness checks. Empty until acquired."}
    bench.write(output / "profile.json", result)
    print(json.dumps(result, indent=2))
    return 3 if result["refusals"] else 0


def main(args, bench):
    try:
        if args.action == "scenarios":
            print(json.dumps(bench.read(HERE / "scenarios.json"), indent=2))
            return 0
        return {"qualify": qualify, "gate": gate, "profile": profile, "monitor": monitor}[args.action](args, bench)
    except (ValueError, KeyError, OSError) as error:
        print(json.dumps({"status": "refused", "reason": str(error)}))
        return 1
