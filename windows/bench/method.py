"""Bounded paired performance experiments. Standard library, no installed shell.

Raw receipts are private. Only export_public constructs publishable output.
Execution success is never an optimization verdict.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics as S
import subprocess as SP
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROTOCOL = "paired-offscreen-v1"
METRICS = {"readyMs": 50.0, "cpuMs": 25.0, "privateMiB": 4.0,
           "workMs": 10.0, "wallMs": 100.0}
SCENARIOS = ("idle", "launcher-search", "panels", "audio-media")
NO_WINDOW = 0x08000000 if os.name == "nt" else 0


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def command(args, timeout=30):
    return SP.run(list(map(str, args)), check=True, capture_output=True, text=True,
                  timeout=timeout, creationflags=NO_WINDOW).stdout.strip()


def tree(root):
    return {p.relative_to(root).as_posix(): sha(p)
            for p in sorted(Path(root).rglob("*")) if p.is_file()}


def identity(source, build, qt):
    """Record actual inputs, not a toolchain selector or mutable branch name."""
    source, build, qt = map(Path, (source, build, qt))
    git = lambda *a: command(["git", "-C", source, *a])
    receipt = read(build / "logs/build.json")
    revision = git("rev-parse", "HEAD")
    backend = git("rev-parse", "HEAD:windows/deps/quickshell")
    if receipt["backendRevision"] != backend:
        raise ValueError("Build backend differs from source pin.")
    # QML-only changes are permitted, but native input changes require a rebuild.
    changed = git("diff", "--name-only", receipt["sourceRevision"], revision).splitlines()
    dirty = git("status", "--porcelain", "--untracked-files=all")
    if any(Path(p).suffix in (".cpp", ".hpp", ".h", ".cmake") or
           Path(p).name == "CMakeLists.txt" for p in changed):
        raise ValueError("Native inputs changed since build.")
    if git("-C", source / "windows/deps/quickshell", "status", "--porcelain"):
        raise ValueError("Backend working tree is dirty.")
    binaries = {}
    for base in (build / "install/qml", build / "quickshell"):
        for p in sorted(base.rglob("*")):
            if p.is_file() and p.suffix.lower() in (".dll", ".exe"):
                binaries[p.relative_to(build).as_posix()] = sha(p)
    binaries["Qt6Core.dll"] = sha(qt / "bin/Qt6Core.dll")
    binaries["Qt6Quick.dll"] = sha(qt / "bin/Qt6Quick.dll")
    binaries["qoffscreen.dll"] = sha(qt / "plugins/platforms/qoffscreen.dll")
    for name in ("qtpaths.exe", "qmlprofiler.exe"):
        if (qt / "bin" / name).is_file():
            binaries[name] = sha(qt / "bin" / name)
    if "quickshell/qs.exe" not in binaries:
        raise ValueError("Missing built runner.")
    return {"sourceSha": revision, "backendPin": backend,
            "nativeSourceSha": receipt["sourceRevision"], "sourceDirty": bool(dirty),
            "workingDiffSha256": digest(git("diff", "HEAD")),
            "buildReceiptSha256": sha(build / "logs/build.json"),
            "binaries": binaries, "toolchain": receipt["toolchain"],
            "suiteSha256": digest(tree(HERE)),
            "os": sys.getwindowsversion().build if os.name == "nt" else 0,
            "logicalProcessors": os.cpu_count()}


def analyze(a, b, floor, minimum=12):
    """Paired mean-difference t interval, conservative df table, lower is better.

    Pairs, not frames, are the independent units. Assumes independent pairs and
    approximately normal pair means. No family-wise error guarantee.
    """
    if len(a) != len(b) or not a or floor < 0:
        raise ValueError("Need matching nonempty pairs and nonnegative floor.")
    if not all(math.isfinite(x) and x >= 0 for x in a + b):
        raise ValueError("Costs must be finite and nonnegative.")
    d = [y - x for x, y in zip(a, b)]
    delta = S.mean(d)
    # Upper critical value at the next lower tabulated degrees of freedom.
    critical = next(t for df, t in reversed([
        (1, 12.706), (2, 4.303), (3, 3.182), (4, 2.776), (5, 2.571),
        (6, 2.447), (7, 2.365), (8, 2.306), (9, 2.262), (10, 2.228),
        (12, 2.179), (15, 2.131), (20, 2.086), (30, 2.043),
        (60, 2.001), (120, 1.980)]) if len(d) - 1 >= df) if len(d) > 1 else 12.706
    half = critical * S.stdev(d) / math.sqrt(len(d)) if len(d) > 1 else math.inf
    lo, hi = delta - half, delta + half
    verdict = "inconclusive"
    if len(d) >= minimum:
        if lo > floor:
            verdict = "regressed"
        elif hi < -floor:
            verdict = "improved"
        elif lo >= -floor and hi <= floor:
            verdict = "not-detected"
    return {"verdict": verdict, "pairs": len(d), "aMean": S.mean(a), "bMean": S.mean(b),
            "delta": delta, "relativePercent": 100 * delta / S.mean(a) if S.mean(a) else None,
            "ci95": [lo, hi] if math.isfinite(half) else None,
            "floor": floor, "resolution95": half if math.isfinite(half) else None,
            "tails": {"p95": "insufficient-independent-observations",
                      "p99": "insufficient-independent-observations"}}


def summarize(record):
    if record.get("protocol") != PROTOCOL or record.get("complete") is not True:
        raise ValueError("Only complete current-protocol acquisitions can be analyzed.")
    pairs = record["pairs"]
    if not pairs or any(set(p) != {"A", "B", "order"} for p in pairs):
        raise ValueError("Incomplete pairs.")
    result = {}
    for name, floor in METRICS.items():
        result[name] = analyze([p["A"]["metrics"][name] for p in pairs],
                               [p["B"]["metrics"][name] for p in pairs], floor)
    return result


def export_public(record):
    """Build an allowlist. Never redact/copy arbitrary metadata or error text."""
    if type(record.get("spinMs")) is not int or not 0 <= record["spinMs"] <= 100:
        raise ValueError("Invalid plant size.")
    result = {"protocol": PROTOCOL, "scenario": record["scenario"],
              "cache": record["cache"], "presentation": "offscreen-software",
              "purpose": record["purpose"], "spinMsB": record["spinMs"],
              "instrumentation": record["instrumentation"],
              "identities": {}, "metrics": summarize(record)}
    if result["scenario"] not in SCENARIOS or result["cache"] not in ("cold", "warm"):
        raise ValueError("Unknown workload.")
    if result["purpose"] not in ("aa", "added", "compare", "overhead", "explore"):
        raise ValueError("Unknown purpose.")
    if result["instrumentation"] not in ("none", "qmlprofiler", "transition"):
        raise ValueError("Unknown instrumentation.")
    for side in ("A", "B"):
        item = record["identities"][side]
        hashes = [item["sourceSha"], item["backendPin"], item["nativeSourceSha"]]
        if not all(re.fullmatch("[a-f0-9]{40}", v) for v in hashes):
            raise ValueError("Invalid revision.")
        binary_hashes = sorted(item["binaries"].values())
        if not binary_hashes or not all(re.fullmatch("[a-f0-9]{64}", v) for v in binary_hashes):
            raise ValueError("Invalid binary hashes.")
        # Binary names and toolchain strings might be private. Publish hashes
        # plus approved numeric version strings, never arbitrary receipt text.
        tools = {}
        for key in ("qtVersion", "clangVersion", "vcToolsVersion", "windowsSdkVersion",
                    "rustVersion", "cmakeVersion", "ninjaVersion"):
            value = item["toolchain"].get(key, "")
            tools[key] = value if re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", value) else "see-private-receipt"
        result["identities"][side] = {
            "sourceSha": hashes[0], "backendPin": hashes[1], "nativeSourceSha": hashes[2],
            "sourceDirty": bool(item["sourceDirty"]), "binarySha256": binary_hashes,
            "toolchain": tools, "identitySha256": digest(item)}
    result["profile"] = "disposable-synthetic"
    result["stateHashes"] = {
        side: [{key: trial[key] for key in ("profileSha256", "cacheBeforeSha256",
                                           "cacheAfterSha256", "stagedSha256")
                if key in trial and re.fullmatch("[a-f0-9]{64}", trial[key])}
               for pair in record["pairs"] for trial in [pair[side]]]
        for side in ("A", "B")}
    return result


class Resources:
    """Read-only, explicit PID handles. Private committed bytes are additive.

    Descendants are discovered from Toolhelp parentage during owned acquisition,
    not guessed from names. Short-lived children between polls remain a gap.
    """
    def __init__(self):
        if os.name != "nt":
            raise OSError("Windows resource accounting required.")
        self.k = C.WinDLL("kernel32", use_last_error=True)
        self.p = C.WinDLL("psapi", use_last_error=True)
        self.u = C.WinDLL("user32", use_last_error=True)
        self.k.OpenProcess.restype = W.HANDLE
        self.k.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
        self.k.CloseHandle.argtypes = [W.HANDLE]
        self.k.GetProcessTimes.argtypes = [W.HANDLE] + [C.POINTER(W.FILETIME)] * 4
        self.k.GetProcessHandleCount.argtypes = [W.HANDLE, C.POINTER(W.DWORD)]
        self.p.GetProcessMemoryInfo.argtypes = [W.HANDLE, C.c_void_p, W.DWORD]
        self.u.GetGuiResources.argtypes = [W.HANDLE, W.DWORD]
        self.k.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]
        self.handles = {}
        self.identities = {}

    def add(self, pid):
        if pid not in self.handles:
            handle = self.k.OpenProcess(0x1000 | 0x10, False, pid)
            if not handle:
                raise C.WinError(C.get_last_error())
            self.handles[pid] = handle
            try:
                buffer = C.create_unicode_buffer(32768)
                size = W.DWORD(len(buffer))
                if not self.k.QueryFullProcessImageNameW(handle, 0, buffer, C.byref(size)):
                    raise C.WinError()
                self.identities[pid] = {"imageSha256": sha(buffer.value)}
            except BaseException:
                self.k.CloseHandle(handle)
                del self.handles[pid]
                raise

    def descendants(self):
        class Entry(C.Structure):
            _fields_ = [("size", W.DWORD), ("usage", W.DWORD), ("pid", W.DWORD),
                        ("heap", C.c_size_t), ("module", W.DWORD), ("threads", W.DWORD),
                        ("parent", W.DWORD), ("priority", W.LONG), ("flags", W.DWORD),
                        ("exe", W.WCHAR * 260)]
        self.k.CreateToolhelp32Snapshot.restype = W.HANDLE
        self.k.Process32FirstW.argtypes = [W.HANDLE, C.POINTER(Entry)]
        self.k.Process32NextW.argtypes = [W.HANDLE, C.POINTER(Entry)]
        snap = self.k.CreateToolhelp32Snapshot(2, 0)
        if snap == C.c_void_p(-1).value:
            raise C.WinError()
        rows = []
        try:
            entry = Entry()
            entry.size = C.sizeof(entry)
            ok = self.k.Process32FirstW(snap, C.byref(entry))
            while ok:
                rows.append((entry.pid, entry.parent))
                ok = self.k.Process32NextW(snap, C.byref(entry))
        finally:
            self.k.CloseHandle(snap)
        # Never follow parentage through an exited handle whose PID was reused.
        alive = {r["pid"]: r["creation100ns"] for r in self.sample() if r["alive"]}
        # Iterate to cover grandchildren in arbitrary snapshot order.
        for _ in range(len(rows)):
            added = False
            for pid, parent in rows:
                if parent in alive and pid not in self.handles:
                    try:
                        self.add(pid)
                        row = next(r for r in self.sample() if r["pid"] == pid)
                        if row["creation100ns"] >= alive[parent] and row["alive"]:
                            alive[pid] = row["creation100ns"]
                        elif row["creation100ns"] < alive[parent]:
                            self.k.CloseHandle(self.handles.pop(pid))
                            self.identities.pop(pid)
                        added = True
                    except OSError:
                        pass  # A child can exit between snapshot and open.
            if not added:
                break

    def sample(self):
        class Memory(C.Structure):
            _fields_ = [("cb", W.DWORD), ("faults", W.DWORD)] + [
                (name, C.c_size_t) for name in (
                    "peakWorking", "working", "peakPaged", "paged", "peakNonpaged",
                    "nonpaged", "pagefile", "peakPagefile", "private")]
        rows = []
        for pid, handle in self.handles.items():
            times = [W.FILETIME() for _ in range(4)]
            if not self.k.GetProcessTimes(handle, *[C.byref(t) for t in times]):
                raise C.WinError()
            ticks = lambda t: (t.dwHighDateTime << 32) | t.dwLowDateTime
            memory = Memory()
            memory.cb = C.sizeof(memory)
            handles = W.DWORD()
            alive = ticks(times[1]) == 0
            if alive:
                if not self.p.GetProcessMemoryInfo(handle, C.byref(memory), memory.cb):
                    raise C.WinError()
                if not self.k.GetProcessHandleCount(handle, C.byref(handles)):
                    raise C.WinError()
            rows.append({"pid": pid, "creation100ns": ticks(times[0]), "alive": alive,
                         "cpuMs": (ticks(times[2]) + ticks(times[3])) / 10000,
                         "privateBytes": memory.private, "handles": handles.value,
                         "gdi": self.u.GetGuiResources(handle, 0) if alive else 0,
                         "user": self.u.GetGuiResources(handle, 1) if alive else 0})
        return rows

    def close(self):
        for handle in self.handles.values():
            self.k.CloseHandle(handle)


def totals(rows):
    return {key: sum(row[key] for row in rows)
            for key in ("cpuMs", "privateBytes", "handles", "gdi", "user")}


def environment(qt, build, stage, scenario, spin):
    profile = stage / "profile"
    imports = stage / "imports"
    native = build / "install/qml"
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("CAELESTIA_", "QS_", "QT_", "QML", "QSG_", "XDG_"))}
    env.update({"QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software",
                "QSG_RENDER_LOOP": "basic", "QS_DISABLE_CRASH_HANDLER": "1",
                "QT_PLUGIN_PATH": str(qt / "plugins"),
                "QT_QPA_PLATFORM_PLUGIN_PATH": str(qt / "plugins/platforms"),
                "QT_FORCE_STDERR_LOGGING": "1", "QS_WINDOWS_TRAY_HOOK": "0",
                "QS_WINDOWS_BLUR": "0", "CAELESTIA_WINDOWS_TILING": "off",
                "CAELESTIA_BENCH_SCENARIO": scenario, "CAELESTIA_BENCH_SPIN_MS": str(spin),
                "QML_IMPORT_PATH": ";".join(map(str, (imports, imports / "qs/imports", native, qt / "qml"))),
                "QML_DISK_CACHE_PATH": str(profile / "cache"),
                "PATH": ";".join(map(str, (qt / "bin", native / "Caelestia/lib",
                                           native / "M3Shapes"))) + ";" + os.environ["PATH"]})
    env["QML2_IMPORT_PATH"] = env["QML_IMPORT_PATH"]
    for name in ("config", "state", "runtime", "cache", "data"):
        env[f"CAELESTIA_{name.upper()}_DIR"] = str(profile / name)
        env[f"XDG_{name.upper()}_HOME"] = str(profile / name)
    env["CAELESTIA_PROFILE_ROOT"] = str(profile)
    env["QS_RUNTIME_DIR"] = str(profile / "runtime")
    return env


def trial(build, qt, stage, scenario, spin=0, instrumentation="none"):
    env = environment(qt, build, stage, scenario, spin)
    args = [str(build / "quickshell/qs.exe"), "--no-color", "--log-times", "--path",
            str(stage / "imports/qs/Bench.qml")]
    trace = stage / "transition.jsonl"
    if instrumentation == "transition":
        env["QS_TRANSITION_TRACE"] = str(trace)
    if instrumentation == "qmlprofiler":
        # --debug's listener is verified below before any attach.
        import socket
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        args += ["--debug", str(port), "--waitfordebug"]
    before_cache = digest(tree(stage / "profile/cache"))
    started = time.perf_counter()
    resource = Resources()
    profiler = None
    try:
        with (stage / "stdout.log").open("wb") as out, (stage / "stderr.log").open("wb") as err:
            child = SP.Popen(args, env=env, stdout=out, stderr=err, creationflags=NO_WINDOW)
            try:
                resource.add(child.pid)
                if instrumentation == "qmlprofiler":
                    # Backend's startTcpDebugServer explicitly binds localhost.
                    profiler = SP.Popen([str(qt / "bin/qmlprofiler.exe"), "--attach", "127.0.0.1",
                                         "--port", str(port), "--output", str(stage / "qml.qtd")],
                                        env=env, stdout=out, stderr=err, creationflags=NO_WINDOW)
                samples = []
                ready = None
                while child.poll() is None:
                    if time.perf_counter() - started > 20:
                        raise TimeoutError("One trial exceeded 20 seconds. No retry.")
                    resource.descendants()
                    rows = resource.sample()
                    samples.append({"seconds": time.perf_counter() - started, "processes": rows})
                    if ready is None and any(b"CAELESTIA_BENCH_READY" in (stage / name).read_bytes()
                                             for name in ("stdout.log", "stderr.log")):
                        ready = (time.perf_counter() - started) * 1000
                    time.sleep(0.05)
                final = resource.sample()
                if child.returncode:
                    raise RuntimeError("Offscreen launch failed. Inspect private stderr.log; no retry.")
            finally:
                if child.poll() is None:
                    # Only the process tree started above. No name-based kill.
                    SP.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                           capture_output=True, creationflags=NO_WINDOW, timeout=5)
                    child.wait(timeout=5)
                if profiler is not None:
                    try:
                        profiler.wait(timeout=8)
                    except SP.TimeoutExpired:
                        profiler.kill()
                        profiler.wait(timeout=3)
    finally:
        resource.close()
    log = (stage / "stderr.log").read_text(errors="replace") + (stage / "stdout.log").read_text(errors="replace")
    match = re.search(r"CAELESTIA_BENCH_RESULT (\{[^\r\n]+\})", log)
    if not match or ready is None or re.search(r"CAELESTIA_BENCH_FAIL|ReferenceError|TypeError|is not a type|binding loop", log):
        raise RuntimeError("Missing completion/readiness or QML error. Inspect private logs; no retry.")
    payload = json.loads(match[1])
    if payload["completed"] != 8 or payload["frames"] < 2 or len(payload["events"]) != 8:
        raise ValueError("Incomplete workload.")
    if instrumentation == "qmlprofiler" and not (stage / "qml.qtd").is_file():
        raise ValueError("Profiler produced no trace.")
    trace_identity = {}
    for name in ("qml.qtd", "transition.jsonl"):
        path = stage / name
        if path.is_file():
            trace_identity[name] = sha(path)
    return {"metrics": {"readyMs": ready, "cpuMs": totals(final)["cpuMs"],
                        "privateMiB": max(totals(s["processes"])["privateBytes"] for s in samples) / 2**20,
                        "workMs": S.mean(e["ms"] for e in payload["events"]),
                        "wallMs": (time.perf_counter() - started) * 1000},
            "samples": samples, "payload": payload, "pid": child.pid,
            "processIdentities": resource.identities, "traceSha256": trace_identity,
            "cacheBeforeSha256": before_cache, "cacheAfterSha256": digest(tree(stage / "profile/cache")),
            "profileSha256": digest(tree(stage / "profile/config")),
            "coverage": "observed descendants only; sub-50ms helpers may be missed"}


def acquire(args):
    build, qt = Path(args.build).resolve(), Path(args.qt).resolve()
    build_b = Path(args.build_b).resolve() if args.build_b else build
    source_b = Path(args.source_b).resolve() if args.source_b else ROOT
    identities = {"A": identity(ROOT, build, qt), "B": identity(source_b, build_b, qt)}
    if args.purpose in ("aa", "added", "overhead") and identities["A"] != identities["B"]:
        raise ValueError("Controls require identical artifacts.")
    if args.purpose == "added" and args.spin_ms <= 0:
        raise ValueError("Added-cost control needs a positive spin.")
    if args.purpose != "added" and args.spin_ms:
        raise ValueError("Plants are only permitted in added-cost controls.")
    if args.purpose == "overhead" and args.instrumentation == "none":
        raise ValueError("Overhead control needs instrumentation on B.")
    if args.purpose not in ("overhead", "explore") and args.instrumentation != "none":
        raise ValueError("Instrumented runs must be separate overhead/exploration controls.")
    if args.purpose != "explore" and args.pairs < 12:
        raise ValueError("At least 12 pairs required outside exploration.")
    output = Path(args.output).resolve()
    if output.exists() or not output.is_relative_to(Path(tempfile.gettempdir()).resolve()):
        raise ValueError("New output root under Temp required.")
    output.mkdir()
    record = {"protocol": PROTOCOL, "complete": False, "acquisitionId": str(uuid.uuid4()),
              "scenario": args.scenario, "cache": args.cache, "purpose": args.purpose,
              "spinMs": args.spin_ms, "instrumentation": args.instrumentation,
              "identities": identities, "pairs": [], "instrumentationOverhead": "not-measured",
              "profile": "disposable synthetic, controls/providers disabled",
              "presentation": "offscreen-software", "pollIntervalMs": 50}
    started = time.perf_counter()
    try:
        for i in range(args.pairs):
            pair = {"order": ["A", "B"] if i % 2 == 0 else ["B", "A"]}
            for side in pair["order"]:
                if time.perf_counter() - started > 540:
                    raise TimeoutError("Bounded acquisition exhausted. Do not shorten silently.")
                stage = output / f"{i:03}-{side}"
                source = ROOT if side == "A" else source_b
                command(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                         source / "windows/bench/Stage-Bench.ps1", "-Destination", stage], timeout=45)
                staged_hash = digest(tree(stage / "imports"))
                selected_build = build if side == "A" else build_b
                if args.cache == "warm":
                    trial(selected_build, qt, stage, args.scenario)  # unscored seed, same absolute paths
                pair[side] = trial(selected_build, qt, stage, args.scenario,
                                   args.spin_ms if side == "B" else 0,
                                   args.instrumentation if side == "B" else "none")
                pair[side]["stagedSha256"] = staged_hash
                pair[side]["rawSha256"] = digest(pair[side])
            record["pairs"].append(pair)
            write(output / "raw.json", record)
        if identities != {"A": identity(ROOT, build, qt), "B": identity(source_b, build_b, qt)}:
            raise ValueError("Candidate inputs changed during acquisition.")
        record["complete"] = True
        record["analysis"] = summarize(record)
        if args.purpose in ("overhead", "explore"):
            record["instrumentationOverhead"] = {
                "scope": "shell and observed descendants; excludes external profiler CPU",
                "pairedDifferences": record["analysis"],
                "baseMarkersAndPolling": "not-measured"}
        write(output / "public.json", export_public(record))
    finally:
        record["wallSeconds"] = time.perf_counter() - started
        write(output / "raw.json", record)
    return record["analysis"]


def qualify(aa, added):
    """Metric-specific controls. A CPU spin does not qualify memory or ready time."""
    if aa["purpose"] != "aa" or added["purpose"] != "added" or added["spinMs"] <= 0:
        raise ValueError("Need A/A and an added-cost control.")
    if aa["acquisitionId"] == added["acquisitionId"]:
        raise ValueError("Independent acquisitions required.")
    for key in ("identities", "scenario", "cache", "instrumentation", "protocol"):
        if aa[key] != added[key]:
            raise ValueError("Qualification conditions differ.")
    if aa["identities"]["A"] != aa["identities"]["B"] or added["instrumentation"] != "none":
        raise ValueError("Controls need identical uninstrumented artifacts.")
    a, b = summarize(aa), summarize(added)
    return {name: {"qualified": name in ("workMs", "cpuMs") and
                   a[name]["verdict"] == "not-detected" and b[name]["verdict"] == "regressed",
                   "aa": a[name], "added": b[name],
                   "testedSpinMsPerStep": added["spinMs"] if name in ("workMs", "cpuMs") else None,
                   "limit": "one control session; repeat independently before campaign acceptance"}
            for name in METRICS}


def gate(record, controls, metrics):
    """Fail closed. Three independent control sessions, no receipt booleans."""
    if not metrics or any(name not in METRICS for name in metrics):
        raise ValueError("Select known required metrics.")
    reasons = []
    result = summarize(record)
    if record["purpose"] != "compare" or record["spinMs"] or record["instrumentation"] != "none":
        reasons.append("not-unplanted-confirmation")
    if len(controls) < 3:
        reasons.append("need-three-independent-control-sessions")
    seen = {record["acquisitionId"]}
    for aa, added in controls:
        q = qualify(aa, added)
        for item in (aa, added):
            if item["acquisitionId"] in seen:
                reasons.append("reused-acquisition")
            seen.add(item["acquisitionId"])
        for key in ("scenario", "cache", "protocol"):
            if aa[key] != record[key]:
                reasons.append("different-workload")
        if aa["identities"]["A"] != record["identities"]["A"]:
            reasons.append("different-reference-identity")
        if any(not q[name]["qualified"] for name in metrics):
            reasons.append("unqualified-required-metric")
    a, b = record["identities"]["A"], record["identities"]["B"]
    if any(a.get(key) != b.get(key) for key in
           ("toolchain", "os", "logicalProcessors", "suiteSha256", "backendPin")):
        reasons.append("different-environment-or-method")
    if a["sourceDirty"] or b["sourceDirty"]:
        reasons.append("dirty-source")
    if any(result[name]["verdict"] != "improved" for name in metrics):
        reasons.append("required-metric-not-improved")
    if any(row["verdict"] == "regressed" for row in result.values()):
        reasons.append("regression")
    return {"accepted": not reasons, "reasons": sorted(set(reasons)), "metrics": result,
            "scope": "statistical gate only; behavior/live/growth acceptance still required"}


def profile_events(path):
    """Rank QML range duration by event definition. Inclusive, not CPU samples."""
    raw = Path(path).read_bytes()
    if b"<!DOCTYPE" in raw or b"<!ENTITY" in raw:
        raise ValueError("External entities are forbidden.")
    doc = ET.fromstring(raw)
    definitions = {e.attrib["index"]: {c.tag: c.text for c in e}
                   for e in doc.findall(".//event") if "index" in e.attrib}
    costs = {}
    for event in doc.findall(".//range"):
        index = event.get("eventIndex")
        duration = int(event.get("duration", "0"))
        if duration > 0 and event.get("startTime") is not None and index in definitions:
            item = costs.setdefault(index, {"count": 0, "durationNs": 0, "definition": definitions[index]})
            item["count"] += 1
            item["durationNs"] += duration
    if not costs:
        raise ValueError("No timestamped duration ranges.")
    return sorted(costs.values(), key=lambda r: r["durationNs"], reverse=True)


def monitor(args):
    manifest = read(args.manifest)
    resource = Resources()
    output = Path(args.output)
    if output.exists():
        raise ValueError("Monitor output must be new.")
    output.mkdir()
    try:
        for item in manifest["processes"]:
            resource.add(item["pid"])
        rows = resource.sample()
        if {r["pid"]: r["creation100ns"] for r in rows} != {
                r["pid"]: r["creation100ns"] for r in manifest["processes"]}:
            raise ValueError("Process creation identity mismatch.")
        for item in manifest["processes"]:
            if resource.identities[item["pid"]]["imageSha256"] != item["imageSha256"]:
                raise ValueError("Process image identity mismatch.")
        started = time.perf_counter()
        with (output / "growth.jsonl").open("w", encoding="utf-8") as stream:
            while time.perf_counter() - started <= args.seconds:
                rows = resource.sample()
                if not all(r["alive"] for r in rows):
                    raise ValueError("An identified process exited. No leak verdict.")
                stream.write(json.dumps({"seconds": time.perf_counter() - started,
                                         "processes": rows, "totals": totals(rows)}) + "\n")
                stream.flush()
                time.sleep(args.interval)
        write(output / "identity.json", {"manifestSha256": sha(args.manifest),
                                        "coverage": "explicit process list only", "leakVerdict": None})
    finally:
        resource.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    for name in ("build", "qt", "output"):
        run.add_argument("--" + name, required=True)
    run.add_argument("--build-b")
    run.add_argument("--source-b")
    run.add_argument("--scenario", choices=SCENARIOS, default="idle")
    run.add_argument("--cache", choices=("cold", "warm"), default="cold")
    run.add_argument("--purpose", choices=("aa", "added", "compare", "overhead", "explore"), default="aa")
    run.add_argument("--instrumentation", choices=("none", "transition", "qmlprofiler"), default="none")
    run.add_argument("--spin-ms", type=int, choices=range(0, 101), default=0)
    run.add_argument("--pairs", type=int, choices=range(1, 49), default=24)
    replay = sub.add_parser("analyze")
    replay.add_argument("raw")
    qualification = sub.add_parser("qualify")
    qualification.add_argument("aa")
    qualification.add_argument("added")
    gating = sub.add_parser("gate")
    gating.add_argument("comparison")
    gating.add_argument("--aa", nargs="+", required=True)
    gating.add_argument("--added", nargs="+", required=True)
    gating.add_argument("--metric", action="append", choices=tuple(METRICS), required=True)
    profile = sub.add_parser("profile")
    profile.add_argument("trace")
    mon = sub.add_parser("monitor")
    mon.add_argument("--manifest", required=True)
    mon.add_argument("--output", required=True)
    mon.add_argument("--seconds", type=int, choices=range(60, 86401), default=3600)
    mon.add_argument("--interval", type=float, default=5)
    args = parser.parse_args()
    if args.command == "run":
        result = acquire(args)
    elif args.command == "analyze":
        result = export_public(read(args.raw))
    elif args.command == "qualify":
        result = qualify(read(args.aa), read(args.added))
    elif args.command == "profile":
        result = profile_events(args.trace)  # PRIVATE. Definitions may contain local paths.
    elif args.command == "gate":
        if len(args.aa) != len(args.added):
            parser.error("Each A/A session needs its matched added-cost control.")
        result = gate(read(args.comparison),
                      [(read(a), read(b)) for a, b in zip(args.aa, args.added)], args.metric)
    else:
        if not 1 <= args.interval <= 60:
            parser.error("Monitor interval must be 1..60 seconds.")
        result = monitor(args)
    print(json.dumps(result, indent=2, allow_nan=False))
    if args.command == "gate" and not result["accepted"]:
        sys.exit(2)


if __name__ == "__main__":
    main()
