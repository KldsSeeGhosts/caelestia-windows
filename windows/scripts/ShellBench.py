"""Same-session shell cost experiments. Python standard library only.

results.json is both the raw data and the input to `summarize`. No baseline
store, external dependencies, or hidden decision state.
"""
import argparse
import csv
import ctypes as C
from ctypes import wintypes as W
import hashlib
import html
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics as S
import subprocess as SP
import sys
import time
import uuid
sys.dont_write_bytecode = True
if os.name == "nt":
    import winreg

HERE = Path(__file__).resolve().parent
PROTOCOL = "public-paired-cost-v5"
DEADLINE = None
PRIVATE = "PRIVATE-local-evidence; never upload raw receipts automatically"
POLICY = {"version": "paired-log-wilcoxon-v3", "excludedMetrics": {
    "payloadAssemblyMs": "Removed after a full-suite A/A false positive: identical B payload assembly was 7.3% slower on experiment three. Raw packaging phases remain diagnostic, not a performance verdict.",
    "quota.nanosecondsPerOperation": "The calibration used priorityRows, which does not exist on main. Replaced with quota.windowProjectionNs, exercising the same production window ordering/projection functions on both revisions.",
    "idleCpuCyclesPerSecond": "Dropped: frequency and background callbacks dominate short idle observations. Cycles/s is not utilization and failed useful small-effect resolution.",
    "scheme.warmApplyMs": "Dropped: a warm cache hit is too short and variable to resolve useful changes in this bounded protocol."
}}
LIMIT_SECONDS = 570  # 30 s reserved for termination/reporting, below 10 minutes
NO_WINDOW = 0x08000000
PS = str(Path(os.environ.get("SystemRoot", "")) / "System32/WindowsPowerShell/v1.0/powershell.exe")
PROVIDERS = ("audio", "media", "tray", "notifications", "quota")
AREAS = ("idle", "panels", "lifecycle", "update", "tiling", "tracker", "scheme") + PROVIDERS
PLANTS = ("None", "CPU", "Resources", "Panel", "Reload", "Startup", "Update",
          "Tiling", "Tracker", "audio", "media", "tray", "notifications", "quota", "Qml", "Scheme", "Sensitivity")


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def external_output(path, sources=()):
    """No output in a source tree, payload, or an existing evidence directory."""
    target = Path(path).resolve()
    for root in (HERE.parent.parent, *sources):
        root = Path(root).resolve()
        if target == root or target.is_relative_to(root):
            raise ValueError("Evidence output must be outside source and measured payload roots.")
    if target.exists():
        raise ValueError("Evidence output must be new; existing evidence is never overwritten.")
    return target


def pair_order(index, order):
    if order not in ("AB", "counterbalanced"):
        raise ValueError("Unknown pair ordering.")
    return ("B", "A") if order == "counterbalanced" and index % 2 == 0 else ("A", "B")


def remaining_budget(timeout):
    value = timeout if DEADLINE is None else min(timeout, DEADLINE - time.monotonic())
    if value <= 0:
        raise TimeoutError("Session deadline exhausted before subprocess or integrity work.")
    return value


def kill_owned(child):
    if child.poll() is None:
        if os.name == "nt":
            try:
                SP.run(["taskkill", "/PID", str(child.pid), "/T", "/F"], capture_output=True,
                       creationflags=NO_WINDOW, timeout=2)
            except SP.TimeoutExpired:
                pass
        if child.poll() is None:
            child.kill()
        child.wait(timeout=2)


def command(args, timeout=30, cwd=None):
    timeout = remaining_budget(timeout)
    child = SP.Popen(list(map(str, args)), stdout=SP.PIPE, stderr=SP.PIPE, text=True,
                     encoding="utf-8", errors="replace", cwd=cwd,
                     creationflags=NO_WINDOW if os.name == "nt" else 0)
    try:
        stdout, stderr = child.communicate(timeout=remaining_budget(timeout))
    except (SP.TimeoutExpired, TimeoutError) as error:
        kill_owned(child)
        raise TimeoutError("Subprocess exceeded remaining session budget; owned process terminated.") from error
    if child.returncode:
        raise RuntimeError(f"Command failed ({child.returncode}): {args[0]}\n{stderr[-1500:]}")
    return stdout.strip()


def git(source, *args):
    return command(["git", "-C", source, *args])


def sha(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while True:
            remaining_budget(30)
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            value.update(chunk)
    return value.hexdigest()


def campaign_module():
    sys.path.insert(0, str(HERE.parent / "bench"))
    import campaign
    return campaign


def probe_identity(root):
    root = Path(root)
    record = read(root / "probe-build.json")
    required = ("compiler", "linker", "cmake", "ninja")
    if record.get("schemaVersion") != 2 or any(not record.get("toolchain", {}).get(k) for k in required):
        raise ValueError("Native probe lacks actual compiler/toolchain provenance; rebuild in a new root.")
    for name in required:
        tool = record["toolchain"][name]
        if not tool.get("sha256") or not tool.get("version"):
            raise ValueError("Native probe toolchain identity is incomplete.")
    if sha(root / "native-bench.exe") != record["executableSha256"]:
        raise ValueError("Native probe executable changed.")
    return {"executableSha256": record["executableSha256"],
            "receiptSha256": sha(root / "probe-build.json"),
            "cacheSha256": sha(root / "CMakeCache.txt"),
            "probeSourceSha256": record["probeSourceSha256"], "cmakeSha256": record["cmakeSha256"],
            "backendRevision": record["backendRevision"],
            "toolchain": {k: {"sha256": record["toolchain"][k]["sha256"],
                               "version": record["toolchain"][k]["version"]} for k in required}}


def verify_probe(root, expected):
    if probe_identity(root) != expected:
        raise ValueError("External native probe or toolchain receipt mutated during acquisition.")


def tree_hashes(root):
    root = Path(root)
    return {p.relative_to(root).as_posix(): sha(p) for p in sorted(root.rglob("*")) if p.is_file()}


def native_inputs(paths):
    return [p for p in paths if not p.startswith("windows/bench/") and
            (p.startswith(("plugin/", "cmake/")) or
             Path(p).suffix.lower() in (".cpp", ".hpp", ".h", ".c", ".cc", ".cmake", ".qrc") or
             Path(p).name in ("CMakeLists.txt", "Cargo.toml", "Cargo.lock"))]


def identity(build, source):
    build = Path(build).resolve()
    record = read(build / "logs/build.json")
    if not source:
        source = next(line.split("=", 1)[1] for line in
                      (build / "caelestia/CMakeCache.txt").read_text().splitlines()
                      if line.startswith("CMAKE_HOME_DIRECTORY:INTERNAL="))
    source = Path(source).resolve()
    revision = git(source, "rev-parse", "HEAD")
    if record.get("sourceDirty") is not False:
        raise ValueError("Build must have clean native sources.")
    changed = git(source, "diff", "--name-only", record["sourceRevision"], revision).splitlines()
    native = native_inputs(changed)
    if native:
        raise ValueError(f"Build has different native inputs: {native}")
    if git(source, "status", "--porcelain"):
        raise ValueError("Payload checkout must be clean. Use a detached checkout of the built revision.")
    backend = git(source, "rev-parse", "HEAD:windows/deps/quickshell")
    if backend != record["backendRevision"]:
        raise ValueError("Built backend and source pin differ.")
    for dependency in ("m3shapes", "glazier"):
        if git(source, "rev-parse", "HEAD:windows/deps/" + dependency) != record[dependency + "Revision"]:
            raise ValueError(f"Built {dependency} and source pin differ.")
    modules = {str(p.relative_to(build)).replace("\\", "/"): sha(p)
               for p in sorted((build / "install/qml").rglob("*.dll"))}
    runtime_files = {str(p.relative_to(build)).replace("\\", "/"): sha(p)
                     for folder in ("install", "quickshell")
                     for p in sorted((build / folder).rglob("*"))
                     if p.is_file() and (folder == "install" or p.suffix.lower() in (".dll", ".exe"))}
    if not modules or not runtime_files:
        raise ValueError("The measured runtime has no native QML modules.")
    return {"revision": revision, "nativeSourceRevision": record["sourceRevision"],
            "qmlOnlySourceOverride": revision != record["sourceRevision"],
            "backendRevision": backend, "source": str(source),
            "build": str(build), "executableSha256": sha(build / "quickshell/qs.exe"),
            "buildRecordSha256": sha(build / "logs/build.json"), "buildRecord": record,
            "nativeModules": modules, "runtimeFiles": runtime_files}


class Power(C.Structure):
    _fields_ = [("ACLineStatus", C.c_ubyte), ("BatteryFlag", C.c_ubyte),
                ("BatteryLifePercent", C.c_ubyte), ("SystemStatusFlag", C.c_ubyte),
                ("BatteryLifeTime", W.DWORD), ("BatteryFullLifeTime", W.DWORD)]


def machine():
    power = Power()
    if not C.windll.kernel32.GetSystemPowerStatus(C.byref(power)):
        raise C.WinError()
    displays = []
    callback_type = C.WINFUNCTYPE(W.BOOL, W.HANDLE, W.HDC, C.POINTER(W.RECT), W.LPARAM)

    def monitor(handle, dc, rect, data):
        r = rect.contents
        displays.append([r.left, r.top, r.right - r.left, r.bottom - r.top])
        return True
    if not C.windll.user32.EnumDisplayMonitors(None, None, callback_type(monitor), 0):
        raise C.WinError()
    idle, kernel, user = W.FILETIME(), W.FILETIME(), W.FILETIME()
    if not C.windll.kernel32.GetSystemTimes(C.byref(idle), C.byref(kernel), C.byref(user)):
        raise C.WinError()

    def ticks(v):
        return (v.dwHighDateTime << 32) + v.dwLowDateTime
    return {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "displays": sorted(displays), "power": {n: getattr(power, n) for n, _ in power._fields_},
            "systemTimes100ns": {"idle": ticks(idle), "total": ticks(kernel) + ticks(user)},
            "powerScheme": command(["powercfg", "/getactivescheme"])}


def check_machine(before, after):
    if before["displays"] != after["displays"]:
        raise ValueError("Display topology changed. Measurement aborted immediately.")
    if (before["powerScheme"] != after["powerScheme"]
            or before["power"]["ACLineStatus"] != after["power"]["ACLineStatus"]):
        raise ValueError("Power state changed. Measurement aborted immediately.")
    for image in ("ninja.exe", "clang-cl.exe", "cargo.exe", "rustc.exe"):
        if image in command(["tasklist", "/NH", "/FI", f"IMAGENAME eq {image}"]).lower():
            raise ValueError(f"Build active ({image}); stop it or measure later.")


def quantile(values, q):
    values = sorted(values)
    p = (len(values) - 1) * q
    lo = int(p)
    return values[lo] + (values[math.ceil(p)] - values[lo]) * (p - lo)


def wilcoxon_interval(log_ratios):
    """Exact signed-rank inversion using ordered Walsh means.

    Coverage is >=95% for independent, continuous, symmetric paired log errors.
    Discreteness is conservative; tied Walsh bounds are retained, not jittered.
    """
    counts = [1]
    for rank in range(1, len(log_ratios) + 1):
        previous = counts
        counts = previous + [0] * rank
        for total, count in enumerate(previous):
            counts[total + rank] += count
    cumulative, critical = 0, -1
    for rank_sum, count in enumerate(counts):
        cumulative += count
        if cumulative / 2**len(log_ratios) <= .025:
            critical = rank_sum
        else:
            break
    walsh = sorted((x + y) / 2 for i, x in enumerate(log_ratios) for y in log_ratios[i:])
    return S.median(walsh), [walsh[critical], walsh[-critical - 1]], 1 - 2 * sum(counts[:critical + 1]) / 2**len(log_ratios)


def compare(a, b, name, floors=None):
    if len(a) != len(b) or not 7 <= len(a) <= 9:
        raise ValueError("Expected 7 to 9 complete A/B pairs.")
    if any(not math.isfinite(x) or x <= 0 for x in a + b):
        raise ValueError(f"Invalid cost values: {name}")
    ratios = [math.log(y / x) for x, y in zip(a, b)]
    estimate, interval, coverage = wilcoxon_interval(ratios)
    baseline = S.median(a)
    if floors is None:
        floors = read(HERE.parent / "bench/map.json")["floorsPercent"]
    if name not in floors:
        raise ValueError(f"No declared diagnostic floor for {name}")
    floor = floors[name]
    if not math.isfinite(floor) or floor <= 0:
        raise ValueError("Metric floor must be positive and finite.")
    percent = 100 * math.expm1(estimate)
    bounds = [100 * math.expm1(x) for x in interval]
    verdict = ("regressed" if bounds[0] > floor else
               "improved" if bounds[1] < -floor else
               "same" if bounds[0] >= -floor and bounds[1] <= floor else "unresolved")
    return {"A": {"trials": a, "median": baseline},
            "B": {"trials": b, "median": S.median(b)},
            "pairedLogRatios": ratios, "pairedDeltas": [y - x for x, y in zip(a, b)],
            "delta": baseline * math.expm1(estimate),
            "deltaInterval95": [baseline * math.expm1(x) for x in interval],
            "deltaPercent": percent, "deltaPercentInterval95": bounds,
            "floorPercent": floor, "noiseFloor": baseline * floor / 100,
            "resolutionPercent": floor + max(percent - bounds[0], bounds[1] - percent),
            "intervalMethod": "exact Wilcoxon signed-rank / Walsh averages",
            "intervalCoverage": coverage, "verdict": verdict}


def summarize(data):
    if data["schemaVersion"] != 1 or data["protocol"]["version"] != PROTOCOL:
        raise ValueError("Unsupported benchmark schema/protocol.")
    trials = data["trials"]
    if not trials:
        raise ValueError("zeroSamples: no completed paired observations.")
    expected = [(i, side) for i in range(1, data["protocol"]["runs"] + 1)
                for side in pair_order(i, data["protocol"].get("order", "AB"))]
    if [(t["index"], t["side"]) for t in trials] != expected:
        raise ValueError("Pairs missing or inconsistent with the declared A/B ordering.")
    if data["protocol"].get("rawRequired"):
        trials = [dict(t, values=derive_values(t)) for t in trials]
    names = set(trials[0]["values"])
    if not names or any(set(t["values"]) != names for t in trials):
        raise ValueError("Missing metric. Failed measurement is not a verdict.")
    if names != set(data["protocol"].get("requiredMetrics", names)):
        raise ValueError("A required metric is missing from every trial.")
    floors = data["protocol"].get("floorsPercent")
    excluded = data.get("analysisPolicy", {}).get("excludedMetrics", {})
    metrics = {name: compare([t["values"][name] for t in trials if t["side"] == "A"],
                            [t["values"][name] for t in trials if t["side"] == "B"], name,
                            floors)
               for name in sorted(names) if name not in excluded}
    if not metrics:
        raise ValueError("No supported metric was measured.")
    for name, metric in metrics.items():
        if name.startswith("panel.") and name.endswith(".p95Ms"):
            metric["claimability"] = campaign_module().claimability(data, name)
    verdicts = [m["verdict"] for m in metrics.values()]
    return {"metrics": metrics, "overall": "regressed" if "regressed" in verdicts else
            "unresolved" if "unresolved" in verdicts else
            "improved" if "improved" in verdicts else "same"}


STYLE = """body{font:15px "Segoe UI",sans-serif;font-variant-numeric:tabular-nums;margin:32px auto;max-width:1200px;padding:0 24px;color:#172b38;background:#f6f8f7}
section{background:white;border-bottom:1px solid #cad5d5;padding:16px;margin:16px 0}p{max-width:80ch;line-height:1.5}
svg{width:100%;height:auto}h1,h2{font-weight:600}h2{font-size:18px}.same{color:#425c70}
.regressed{color:#ad302c}.improved{color:#187045}.slower{color:#976300}.unresolved{color:#6b7c88}code{overflow-wrap:anywhere}small{color:#566873}"""
# kind -> colour. "slower" = unresolved but possibly slower; "unresolved" = unresolved, not slower.
COLORS = {"same": "#425c70", "regressed": "#ad302c", "improved": "#187045", "slower": "#976300", "unresolved": "#6b7c88"}
ORDER = {"regressed": 0, "slower": 1, "improved": 2, "unresolved": 3, "same": 4}
LABELS = {
    "coldStartToReadyMs": "Cold start to ready", "qmlReloadToReadyMs": "QML reload to ready",
    "isolatedActivationMs": "Update activation", "privateMiB": "Private memory", "workingSetMiB": "Working set",
    "tiling.cyclesPerOperation": "Tiling layout (cycles/op)", "tracker.cyclesPerOperation": "Window tracker (cycles/op)",
    "quota.windowProjectionNs": "Quota projection (ns)", "scheme.wallpaperApplyMs": "Wallpaper scheme apply",
}


def label(name):
    if name in LABELS:
        return LABELS[name]
    parts = name.split(".")
    if parts[0] == "panel":
        return f"{parts[1].capitalize()} open {parts[2][:3]}"
    if parts[0] == "module":
        return f"{parts[1].capitalize()} module load"
    if parts[-1] == "nanosecondsPerOperation":
        return f"{parts[0].capitalize()} service (ns/op)"
    return name


def kind(m):
    if m["verdict"] != "unresolved":
        return m["verdict"]
    return "slower" if m["deltaPercentInterval95"][1] > m["floorPercent"] else "unresolved"


def reading(m):
    """One plain-language line per metric. Never stronger than the interval."""
    lo, hi = m["deltaPercentInterval95"]
    k, est = kind(m), abs(m["deltaPercent"])
    if k == "regressed":
        return f"slower, about {est:.1f}% (at least {lo:.1f}%)"
    if k == "improved":
        return f"faster, about {est:.1f}% (at least {-hi:.1f}%)"
    if k == "same":
        return f"within +/-{m['floorPercent']:.1f}% diagnostic floor"
    # Direction is shown only when the interval excludes zero.
    if k == "slower":
        return f"likely {est:.1f}% slower, up to +{hi:.1f}%" if lo > 0 else f"possibly slower, up to +{hi:.1f}%"
    return f"not slower, likely {est:.1f}% faster" if hi < 0 else "not slower"


def headline(result):
    kinds = [kind(m) for m in result["metrics"].values()]
    names = lambda k: ", ".join(label(n) for n, m in result["metrics"].items() if kind(m) == k)
    if "regressed" in kinds:
        text = f"Regressed: {names('regressed')}."
    elif any(m["verdict"] == "unresolved" for m in result["metrics"].values()):
        text = "Unresolved comparison. No promotion verdict."
    elif "improved" in kinds:
        text = f"Resolved diagnostic improvement: {names('improved')}. Qualification still required."
    else:
        text = "Within diagnostic floors. Qualification still required."
    if "slower" in kinds:
        text += f" Possibly slower, not resolved: {names('slower')}."
    return text


def summary_chart(metrics):
    extent = 10  # Axis clipped so 2-5% changes stay readable; arrows mark anything beyond.

    def x(percent):
        return 650 + 230 * max(-extent, min(extent, percent)) / extent
    height = 100 + len(metrics) * 36
    parts = [f'<section><h2>Change in cost, B versus A</h2><p>Lower is better. Dot: paired Hodges-Lehmann estimate. '
             'Line: exact Wilcoxon interval (at least 95% coverage). Shaded band: declared diagnostic floor. '
             'Red slower; amber possibly slower; green faster; blue same; grey unresolved. Arrows: beyond +/-10%.</p>'
             f'<svg id="summary-chart" viewBox="0 0 1200 {height}" role="img" aria-label="Cost change summary in percent">']
    for tick in (-10, -5, 0, 5, 10):
        parts.append(f'<path d="M{x(tick):.2f} 25V{height-40}" stroke="#dde3e5"/>'
                     f'<text x="{x(tick):.2f}" y="{height-15}" text-anchor="middle">{tick:+d}%</text>')
    for index, (name, m) in enumerate(metrics.items()):
        y = 45 + index * 36
        lo, hi = m["deltaPercentInterval95"]
        color, floor = COLORS[kind(m)], m["floorPercent"]
        arrows = "".join(f'<path d="M{x(v):.2f} {y}l{6 if v > 0 else -6} -5v10z" fill="{color}"/>'
                         for v in (lo, hi) if abs(v) > extent)
        parts.append(f'<text x="0" y="{y+5}" font-size="13">{html.escape(label(name))}</text>'
                     f'<rect x="{x(-floor):.2f}" y="{y-13}" width="{x(floor)-x(-floor):.2f}" height="26" fill="#e5ebf0"/>'
                     f'<path d="M{x(lo):.2f} {y}H{x(hi):.2f}" stroke="{color}" stroke-width="2"/>{arrows}'
                     f'<circle cx="{x(m["deltaPercent"]):.2f}" cy="{y}" r="5" fill="{color}"/>'
                     f'<text x="900" y="{y+5}" font-size="12" fill="{color}">{html.escape(reading(m))}</text>')
    parts.append('</svg></section>')
    return "".join(parts)


def report(data, target):
    result = data["summary"]
    metrics = dict(sorted(result["metrics"].items(), key=lambda i: (ORDER[kind(i[1])], label(i[0]))))
    plant = data.get("plantB", "None")
    if plant in ("Sensitivity", "Resources", "Panel", "Reload", "Tiling", "Tracker") + PROVIDERS:
        plant += f' (setting {data.get("plantPercent", 25):g}; see metric-specific plant units)'
    parts = [f'<!doctype html><html lang="en"><meta charset="utf-8"><title>Shell benchmark</title>'
             f'<style>{STYLE}</style><h1>{html.escape(headline(result))}</h1>',
             f'<p>A {html.escape(data["sides"]["A"]["revision"][:12])} / '
             f'B {html.escape(data["sides"]["B"]["revision"][:12])} | '
             f'{data["wallSeconds"]:.0f} s | {html.escape(data["protocol"]["version"])} / '
             f'{html.escape(data.get("analysisPolicy", {}).get("version", "original analysis"))} | Offscreen, software rendering | '
             f'B plant: {html.escape(plant)}</p>',
             '<p>Same: the whole interval is inside the noise floor. Faster/slower: the whole interval is beyond it. '
             'Otherwise the change is too small to resolve; the row says whether it could be a slowdown and by how much. '
             'Only a resolved slowdown fails acquisition. Exit zero is not qualification or improvement; automation must inspect the raw-replayed gate.</p>',
             summary_chart(metrics), '<h2>Individual fresh-process trials</h2>'
             '<p>Dots are fresh processes. Vertical ticks mark A/B medians. The axis is zoomed to the data.</p>']
    for name, m in metrics.items():
        k = kind(m)
        parts.append(f'<section><h2>{html.escape(label(name))}: <span class="{k}">{html.escape(reading(m))}</span></h2>')
        values = m["A"]["trials"] + m["B"]["trials"]
        low, high = min(values), max(values)
        pad = (high - low) * 0.08 or abs(high) * 0.01 or 1
        low, span = low - pad, (high - low) + 2 * pad
        parts.append('<svg viewBox="0 0 1000 135" role="img" aria-label="' + html.escape(name) + ' trials">')
        for y, side, color in ((35, "A", "#687e8e"), (90, "B", COLORS[k])):
            parts.append(f'<text x="0" y="{y + 5}">{side}</text>')
            x = 65 + 820 * (m[side]["median"] - low) / span
            parts.append(f'<path d="M{x:.2f} {y-18}v36" stroke="{color}" stroke-width="4"/>')
            for i, v in enumerate(m[side]["trials"]):
                x = 65 + 820 * (v - low) / span
                parts.append(f'<circle cx="{x:.2f}" cy="{y+(i-2)*5}" r="4" fill="{color}"><title>Trial {i+1}: {v:.6g}</title></circle>')
            parts.append(f'<text x="900" y="{y+5}">{m[side]["median"]:.4g}</text>')
        parts.append(f'<text x="65" y="130" font-size="11" fill="#566873">{low:.4g}</text>'
                     f'<text x="885" y="130" font-size="11" fill="#566873" text-anchor="end">{low + span:.4g}</text></svg>')
        lo, hi = m["deltaPercentInterval95"]
        parts.append(f'<p><code>{html.escape(name)}</code> | delta {m["deltaPercent"]:+.2f}%; exact interval [{lo:+.2f}%, {hi:+.2f}%]; '
                     f'floor +/-{m["floorPercent"]:.2f}%; resolution {m["resolutionPercent"]:.2f}%</p></section>')
    parts.append('<h2>Removed / unsupported probes</h2><ul>')
    parts.extend(f'<li>Not covered (native provider, disabled in probes): {html.escape(p)}</li>'
                 for p in data.get("notCovered", []))
    parts.extend(f'<li>{html.escape(k)}: {html.escape(v)}</li>' for k, v in data["removed"].items())
    parts.append('</ul><p>Raw values, exact commands, revisions and machine state: <a href="results.json">results.json</a>.</p></html>')
    Path(target).write_text("".join(parts), encoding="utf-8")


def runtime_values(path):
    completion, metadata = read(path / "completion.json"), read(path / "metadata.json")
    if not completion["completed"] or completion["errors"]:
        raise ValueError(f"Runtime measurement failed: {completion['errors']}")
    with (path / "samples.csv").open(encoding="utf-8-sig", newline="") as stream:
        rows = [{k: v if k == "phase" else float(v) for k, v in r.items()} for r in csv.DictReader(stream)]
    raw = {"counters": rows, "actions": [], "work": completion["work"],
           "idleSeconds": metadata["workload"]["idleSeconds"],
           "cycles": metadata["workload"]["cycles"],
           "category": metadata["metric"],
           "plant": metadata["plant"],
           "plantPercent": metadata.get("plantPercent"),
           "plantResourceBytes": metadata.get("plantResourceBytes"),
           "plantPanelDelaysMs": metadata.get("plantPanelDelaysMs"),
           "plantReferenceValues": metadata.get("plantReferenceValues"),
           "warmupSeconds": metadata["workload"]["warmupSeconds"],
           "busyTicksBefore": metadata.get("idleStateBefore", {}).get("busyTicks", 0),
           "busyTicksFinal": metadata.get("finalState", {}).get("busyTicks", 0),
           "busyWorkBefore": metadata.get("idleStateBefore", {}).get("busyWork", 0),
           "busyWorkFinal": metadata.get("finalState", {}).get("busyWork", 0),
           "startupPhases": [s for log in ("stdout.log", "stderr.log")
                             for s in (path / log).read_text(encoding="utf-8-sig").splitlines()
                             if "quickshell.startup" in s],
           "payloadSha256": metadata["payloadSha256"]}
    raw.update({key: metadata.get(key) for key in ("screen", "controlGates", "configSha256", "workloadDimensions",
                                                 "setupSeconds", "stageFilesSha256", "cacheFilesSha256")})
    raw["actions"] = [json.loads(s) for s in (path / "actions.jsonl").read_text(encoding="utf-8-sig").splitlines() if s.strip()]
    return derive_runtime(raw), raw


def derive_runtime(raw):
    rows, actions, values = raw["counters"], raw["actions"], {}
    idle = [r for r in rows if r["phase"] == "idle"]
    if raw["category"] in ("Quick", "Idle"):
        if raw.get("plant") in ("Resources", "Sensitivity"):
            requested = raw.get("plantResourceBytes", 0)
            if requested <= 0 or raw.get("screen", {}).get("retainedBytes") != requested:
                raise ValueError("Resource plant did not retain the requested bytes.")
        if raw.get("plant") == "CPU" and (raw["busyTicksFinal"] <= raw["busyTicksBefore"]
                                        or ("busyWorkFinal" in raw and raw["busyWorkFinal"] <= raw["busyWorkBefore"])):
            raise ValueError("CPU plant did not perform its busy timer work.")
        if len(idle) < 2 or raw["work"]["idleIntervals"] != len(idle) - 1:
            raise ValueError("Idle intervals missing.")
        seconds = idle[-1]["elapsedSeconds"] - idle[0]["elapsedSeconds"]
        if seconds < raw["idleSeconds"]:
            raise ValueError("Idle observation incomplete.")
        values["privateMiB"] = S.median(r["privateBytes"] for r in idle) / 1024**2
        values["workingSetMiB"] = S.median(r["workingSet"] for r in idle) / 1024**2
    shown = [a for a in actions if a["panel"] != "idle"]
    if len(actions) != raw["work"]["actionsConfirmed"]:
        raise ValueError("Frame action count disagrees with confirmed work.")
    if raw["category"] in ("Quick", "Panel") and len(shown) != raw["cycles"]:
        raise ValueError("Not every requested panel frame was confirmed.")
    for panel in ("dashboard", "launcher", "utilities", "sidebar") if shown else ():
        costs = [a["shellRequestToFrameMs"] for a in shown if a["panel"] == panel]
        if len(costs) != raw["cycles"] // 4:
            raise ValueError("Per-panel work count is incomplete.")
        values[f"panel.{panel}.p50Ms"] = S.median(costs)
        values[f"panel.{panel}.p95Ms"] = quantile(costs, .95)
    return values


def derive_values(trial):
    raw, values = trial["raw"], {}
    if "runtime" in raw:
        values.update(derive_runtime(raw["runtime"]))
    for name in ("tiling", "tracker"):
        if name in raw:
            r = raw[name]
            if r["operations"] <= 0 or r["checksum"] <= 0 or r["actualOperations"] < r["operations"]:
                raise ValueError("Native work was not confirmed.")
            if "cpuCycles" in r:
                values[name + ".cyclesPerOperation"] = r["cpuCycles"] / r["operations"]
            else:
                values[name + ".nanosecondsPerOperation"] = r["elapsedNs"] / r["operations"]
    for r in raw.get("services", []):
        name = r["area"]
        if r["operations"] <= 0 or r["checksum"] <= 0 or r["actualOperations"] < r["operations"]:
            raise ValueError("Service work was not confirmed.")
        values[r.get("metric", name + ".nanosecondsPerOperation")] = r["elapsedMs"] * 1e6 / r["operations"]
        if name != "quota":
            values["module." + name + ".loadMs"] = r["compileMs"]
    if "lifecycle" in raw:
        r = raw["lifecycle"]
        if not r["lifecycleReady"] or r["initialGeneration"] == r["finalGeneration"]:
            raise ValueError("No confirmed new lifecycle generation.")
        if r.get("exitCode", 0) != 0:
            raise ValueError("Lifecycle trial crashed on shutdown.")
        values.update(r["values"])
        values["payloadAssemblyMs"] = 1000 * r["installPhases"]["payloadAssemblySeconds"]
        values["isolatedActivationMs"] = (1000 * r["installPhases"]["versionSelectionSeconds"]
                                          + values["coldStartToReadyMs"] + r.get("activationExtraValidationMs", 0))
    if "scheme" in raw:
        for r in raw["scheme"]["work"]:
            values[r["metric"]] = r["elapsedNs"] / 1e6
    if set(values) != set(trial["values"]) or any(not math.isclose(v, trial["values"][k], rel_tol=1e-12, abs_tol=1e-9) for k, v in values.items()):
        raise ValueError("Trial metric values do not reproduce from raw counters/work.")
    return values


def worker(args, path, remaining):
    timeout = remaining_budget(min(remaining, 90))
    with (path.parent / (path.name + ".worker.log")).open("w", encoding="utf-8") as log:
        child = SP.Popen(list(map(str, args)), stdout=log, stderr=SP.STDOUT, cwd=path.parent, creationflags=NO_WINDOW)
        try:
            code = child.wait(timeout=remaining_budget(timeout))
        except (SP.TimeoutExpired, TimeoutError):
            kill_owned(child)
            raise TimeoutError("Worker exceeded its deadline; process tree terminated.")
        if code:
            raise RuntimeError(f"Worker failed ({code}); see {path.name}.worker.log. Aborted at first failed trial.")


def select_paths(changed, mapping):
    files = [p for p in changed if not any(re.search(r, p) for r in mapping["ignore"])]
    uncovered = [p for p in files if any(re.search(r, p) for r in mapping["notCovered"])]
    if any(re.search(r, p) for p in files for r in mapping["allPaths"]):
        return {"areas": ["all"], "notCovered": uncovered}
    selected = set()
    for path in files:
        matched = {name for name, area in mapping["areas"].items()
                   if any(re.search(r, path) for r in area["paths"])}
        selected.update(matched or {"idle"})
        if path.startswith(("modules/", "windows/shell/adapters/modules/")):
            # Always-on QML costs load time first: startup and reload, not only memory.
            selected.update(("idle", "panels", "lifecycle"))
    return {"areas": sorted(selected), "notCovered": uncovered}


def calibrate(paths):
    return campaign_module().calibrate(paths, sys.modules[__name__])


def record_failure(data, error, output, started):
    data["error"] = str(error)
    data.pop("summary", None)
    data["complete"] = False
    data["workerAcquisitionSeconds"] = data.pop("workloadSeconds", data.get("workerAcquisitionSeconds", 0))
    data["privacy"] = PRIVATE
    data["failure"] = {"kind": "deadline-exceeded" if isinstance(error, (TimeoutError, SP.TimeoutExpired)) else "measurement-failed"}
    data["wallSeconds"] = time.monotonic() - started
    write(Path(output) / "results.json", data)


def run(args):
    global DEADLINE
    if os.name != "nt":
        raise ValueError("Measurement requires Windows; raw-data summarization is portable.")
    started = time.monotonic()
    output = external_output(args.output, [p for p in
                             (args.a, args.b, args.qt, args.native_a, args.native_b,
                              args.source_a, args.source_b) if p])
    output.mkdir(parents=True, exist_ok=False)
    selected = {s.strip().lower() for s in (args.select or args.area).split(",")}
    if "all" in selected:
        selected = set(AREAS)
    if "providers" in selected:
        selected.remove("providers")
        selected.update(PROVIDERS)
    if not selected or selected - set(AREAS):
        raise ValueError(f"Unknown areas: {sorted(selected - set(AREAS))}")
    args.runs = args.runs or (7 if selected == set(AREAS) else 9)
    if args.order != "AB" and args.plant in ("Panel", "Resources", "Reload", "Sensitivity"):
        raise ValueError("Reference-dependent plants require explicit --order AB. Requalify separately.")
    if not 0 <= args.plant_percent <= 100:
        raise ValueError("Plant percentage must be between 0 and 100.")
    mapping = read(HERE.parent / "bench/map.json")
    data = {"schemaVersion": 1, "acquisitionId": uuid.uuid4().hex, "privacy": PRIVATE, "complete": False,
            "date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "command": [PS, "-NoProfile", "-File", str(HERE / "Measure-ShellBenchmark.ps1"),
                        "-QtPrefix", args.qt, "-BuildRoot", args.a, "-BuildRootB", args.b,
                        "-RunRoot", str(output), "-Area", args.area, "-Runs", str(args.runs), "-PlantB", args.plant],
            "protocol": {"version": PROTOCOL, "runs": args.runs, "order": args.order,
                         "purpose": args.purpose,
                         "area": args.area, "mode": "Offscreen",
                         "qualification": "unqualified-public-protocol",
                         "cachePolicy": "fresh-process-profile-and-qml-cache",
                         "instrumentation": {"externalTracing": False,
                                             "acquisitionMarkers": "ready/geometry/two-frame confirmations",
                                             "overheadStatus": "not-measured"},
                         "warmupSeconds": 2, "idleSeconds": 2, "panelWarmupSeconds": 2, "panelCycles": 8,
                         "deadlineSeconds": LIMIT_SECONDS,
                         "selectedAreas": sorted(selected),
                         "floorsPercent": mapping["floorsPercent"],
                         "floorCalibration": mapping["floorCalibration"],
                         "maximumSystemCpuPercent": 60,
                         "rawRequired": True,
                         "analysisSha256": sha(__file__), "runtimeSha256": sha(HERE.parent / "bench/tools/Measure-ShellRuntime.ps1")},
            "sides": {}, "trials": [], "plantB": args.plant, "plantPercent": args.plant_percent,
            "evidenceClass": "offscreen-or-isolated-logic",
            "integrityCheckSeconds": 0, "workloadSeconds": 0, "machineCheckSeconds": 0,
            "notCovered": args.not_covered or [],
            "analysisPolicy": POLICY,
            "machine": {"os": platform.platform(), "logicalProcessors": os.cpu_count()},
            "removed": {"wakeups/s": "Windows has no documented per-process wakeup counter. Context switches are not wakeups. ETW overhead is not calibrated within this protocol.",
                        "idle CPU core-percent": "Short CPU-time-counter trials failed to detect confirmed planted 1ms/20ms work, including the longer 4s warmup/6s observation protocol. No utilization verdict is emitted. Raw process cycles/s is a distinct metric, not a conversion to utilization.",
                        "resource soak": "Long-term leak slopes cannot be established by a sub-10-minute experiment; instantaneous private bytes and working set replace the soak.",
                        "native parity": "Offscreen software rendering is not D3D11/DWM/input-to-photon or native placement throughput.",
                        "native providers": "Not covered: COM/WinRT callbacks, audio endpoints, media sessions, Explorer tray interception and notification delivery. Provider probes exercise pure QML projection helpers only."}}
    data["removed"]["native wall-time verdicts"] = "Native thread cycles/operation measures CPU work, not elapsed time. Each process has independent random stack/heap padding and no affinity restriction."
    if args.source_a:
        data["command"] += ["-SourceRoot", args.source_a]
    if args.source_b:
        data["command"] += ["-SourceRootB", args.source_b]
    if args.select:
        data["command"] += ["-SelectAreas", args.select]
    if args.not_covered:
        data["command"] += ["-NotCovered"] + args.not_covered
    if args.scheme_python:
        data["command"] += ["-SchemePython", args.scheme_python]
    data["command"] += ["-PlantPercent", str(args.plant_percent), "-Order", args.order, "-Purpose", args.purpose]
    if args.calibration:
        data["command"] += ["-Calibration", args.calibration]
    for side, root in (("A", args.native_a), ("B", args.native_b)):
        if root:
            data["command"] += ["-NativeRoot" + side, root]
    power_state = None
    DEADLINE = started + LIMIT_SECONDS
    write(output / "results.json", data)
    try:
        if args.calibration:
            calibration, _ = campaign_module().load_calibration(args.calibration, sys.modules[__name__])
            if args.purpose == "floor-discovery":
                raise ValueError("Floor discovery cannot reuse frozen calibration.")
            data["protocol"]["floorsPercent"] = calibration["floorsPercent"]
            data["protocol"]["floorCalibration"] = calibration
            data["protocol"]["floorCalibrationId"] = calibration["identitySha256"]
        elif args.purpose in ("held-out", "confirm"):
            raise ValueError("Held-out and confirmation runs require --calibration with frozen provenance.")
        integrity_started = time.monotonic()
        execution_state = C.windll.kernel32.SetThreadExecutionState
        execution_state.argtypes, execution_state.restype = [W.DWORD], W.DWORD
        power_state = execution_state(0x80000001)  # continuous, system required, not display
        if not power_state:
            raise C.WinError()
        data["machine"]["powerRequest"] = {"system": True, "display": False}
        files = ("scripts/ShellBench.py", "scripts/Measure-ShellBenchmark.ps1", "bench/tools/Measure-ShellRuntime.ps1",
                 "bench/tools/Measure-ShellLifecycle.ps1", "bench/tools/Measure-ServiceBench.ps1",
                 "bench/tools/Measure-SchemeBench.py", "bench/tools/Build-Bench.ps1",
                 "bench/Services.qml", "bench/native/main.cpp", "bench/native/CMakeLists.txt", "bench/map.json",
                 "bench/campaign.py", "bench/scenarios.json",
                 "scripts/Stage-ShellPrototype.ps1", "scripts/Caelestia-Privacy.ps1")
        data["protocol"]["filesSha256"] = {name: sha(HERE.parent / name) for name in files}
        data["sides"] = {"A": identity(args.a, args.source_a), "B": identity(args.b, args.source_b)}
        data["integrityCheckSeconds"] += time.monotonic() - integrity_started
        config_root = data["sides"]["A"]["source"]
        data["protocol"]["settingsSha256"] = {name: sha(Path(config_root) / "windows/shell" / name)
                                              for name in ("shell.json", "windows.json")}
        data["removed"].update(POLICY["excludedMetrics"])
        integrity_started = time.monotonic()
        qt_version = command([Path(args.qt) / "bin/qtpaths.exe", "--qt-version"])
        if any(side["buildRecord"]["qtVersion"] != qt_version for side in data["sides"].values()):
            raise ValueError("Qt prefix does not match the builds' Qt version.")
        data["machine"]["qtVersion"] = qt_version
        data["machine"]["qtCoreSha256"] = sha(Path(args.qt) / "bin/Qt6Core.dll")
        data["machine"]["qtRuntimeFiles"] = {
            p.relative_to(Path(args.qt)).as_posix(): sha(p)
            for folder in ("bin", "plugins", "qml")
            for p in sorted((Path(args.qt) / folder).rglob("*.dll"))}
        data["machine"]["qtRuntimeIdentitySha256"] = hashlib.sha256(
            json.dumps(data["machine"]["qtRuntimeFiles"], sort_keys=True).encode()).hexdigest()
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography") as key:
            data["machine"]["id"] = hashlib.sha256(winreg.QueryValueEx(key, "MachineGuid")[0].encode()).hexdigest()[:16]
        data["integrityCheckSeconds"] += time.monotonic() - integrity_started
        initial = machine()
        check_machine(initial, initial)
        load_check = machine()
        total = load_check["systemTimes100ns"]["total"] - initial["systemTimes100ns"]["total"]
        initial["systemCpuPercent"] = 100 * (1 - (load_check["systemTimes100ns"]["idle"] - initial["systemTimes100ns"]["idle"]) / total) if total else 0
        data["machine"]["initial"] = initial
        data["machine"]["loadCheck"] = load_check
        if initial["systemCpuPercent"] > data["protocol"]["maximumSystemCpuPercent"]:
            raise ValueError(f'Machine busy before trials: {initial["systemCpuPercent"]:.1f}% CPU, maximum 60%.')
        if "scheme" in selected and not args.scheme_python:
            raise ValueError("Scheme probe needs -SchemePython from an isolated prepared runtime; see BENCHMARKS.md.")
        if "scheme" not in selected:
            data["removed"]["scheme/wallpaper"] = "Not selected or no isolated scheme Python runtime supplied. No fixed-palette timing is substituted for quantizer work."
        required = set()
        for category in selected:
            if category in ("tiling", "tracker") or category in PROVIDERS:
                required.add(category + (".cyclesPerOperation" if category in ("tiling", "tracker") else
                                         ".windowProjectionNs" if category == "quota" else ".nanosecondsPerOperation"))
                if category in PROVIDERS and category != "quota":
                    required.add("module." + category + ".loadMs")
            elif category == "idle":
                required.update(("privateMiB", "workingSetMiB"))
            elif category == "panels":
                required.update(f"panel.{p}.{q}Ms" for p in ("dashboard", "launcher", "utilities", "sidebar") for q in ("p50", "p95"))
            elif category in ("lifecycle", "update"):
                required.update(("coldStartToReadyMs", "qmlReloadToReadyMs", "isolatedActivationMs", "payloadAssemblyMs"))
            elif category == "scheme":
                required.add("scheme.wallpaperApplyMs")
        data["protocol"]["requiredMetrics"] = sorted(required)
        data["setupSeconds"] = time.monotonic() - started
        native_roots = {"A": args.native_a, "B": args.native_b}
        if selected & {"tiling", "tracker"}:
            for side in ("A", "B"):
                if not native_roots[side]:
                    native_roots[side] = str(output / ("native-" + side))
                    cmd = [PS, "-NoProfile", "-File", HERE.parent / "bench/tools/Build-Bench.ps1",
                           "-SourceRoot", data["sides"][side]["source"], "-QtPrefix", args.qt,
                           "-BuildRoot", native_roots[side], "-PayloadRoot", data["sides"][side]["build"]]
                    worker(cmd, output / ("build-native-" + side), LIMIT_SECONDS - (time.monotonic() - started))
                native = Path(native_roots[side])
                cache = (native / "CMakeCache.txt").read_text()
                data["sides"][side]["nativeProbeSourceCheckout"] = next(
                    line.split("=", 1)[-1] for line in cache.splitlines() if line.startswith("BACKEND_ROOT:"))
                data["sides"][side]["nativeProbeSha256"] = sha(native / "native-bench.exe")
                built = read(native / "probe-build.json")
                if (built["backendRevision"] != data["sides"][side]["backendRevision"]
                        or built["probeSourceSha256"] != sha(HERE.parent / "bench/native/main.cpp")
                        or built["cmakeSha256"] != sha(HERE.parent / "bench/native/CMakeLists.txt")
                        or built["executableSha256"] != data["sides"][side]["nativeProbeSha256"]):
                    raise ValueError("Native probe build is stale or its source identity differs.")
                data["sides"][side]["nativeProbeBuild"] = built
                integrity_started = time.monotonic()
                data["sides"][side]["nativeProbeIdentity"] = probe_identity(native)
                data["sides"][side]["nativeProbeRoot"] = str(native.resolve())
                data["integrityCheckSeconds"] += time.monotonic() - integrity_started
        data["setupIncludingNativeProbeSeconds"] = time.monotonic() - started
        measurement_started = time.monotonic()
        for index in range(1, args.runs + 1):
            for side in pair_order(index, args.order):
                trial_started = time.monotonic()
                integrity_started = time.monotonic()
                for stable in data["sides"].values():
                    if stable.get("nativeProbeIdentity"):
                        verify_probe(stable["nativeProbeRoot"], stable["nativeProbeIdentity"])
                pre_integrity_seconds = time.monotonic() - integrity_started
                data["integrityCheckSeconds"] += pre_integrity_seconds
                machine_started = time.monotonic()
                before = machine()
                check_machine(initial, before)
                data["machineCheckSeconds"] += time.monotonic() - machine_started
                ident = data["sides"][side]
                plant = args.plant if side == "B" else "None"
                path = output / f"{side}-{index}"
                reference = output / f"A-{index}-reference.json"
                values, raw, commands = {}, {}, []
                data["inFlightTrial"] = {"side": side, "index": index, "raw": raw, "commands": commands}
                print(f"{side} trial {index}/{args.runs} ({args.area}, plant {plant})", flush=True)
                workload_started = time.monotonic()
                service_areas = selected & set(PROVIDERS)
                if service_areas:
                    service_path = output / f"{side}-{index}-services"
                    raw["services"] = []
                    for group in ("providers",) if service_areas == set(PROVIDERS) else sorted(service_areas):
                        service_path = output / f"{side}-{index}-services-{group}"
                        cmd = [PS, "-NoProfile", "-File", HERE.parent / "bench/tools/Measure-ServiceBench.ps1",
                               "-QtPrefix", args.qt, "-BuildRoot", ident["build"], "-SourceRoot", ident["source"],
                               "-RunRoot", service_path, "-Area", group, "-Plant", plant,
                               "-PlantPercent", args.plant_percent]
                        commands.append(list(map(str, cmd)))
                        worker(cmd, service_path, LIMIT_SECONDS - (time.monotonic() - started))
                        raw["services"].extend(read(service_path / "trial.json"))
                    for entry in raw["services"]:
                        name = entry["area"]
                        values[entry.get("metric", name + ".nanosecondsPerOperation")] = entry["nanosecondsPerOperation"]
                        if name != "quota":
                            values["module." + name + ".loadMs"] = entry["compileMs"]
                if selected & {"tiling", "tracker"}:
                    for native_area in sorted(selected & {"tiling", "tracker"}):
                        cmd = [str(Path(native_roots[side]) / "native-bench.exe"), native_area,
                               "--plant=" + str(int(plant.lower() == native_area or
                                                    (plant == "Sensitivity" and native_area == "tiling")))]
                        commands.append(cmd)
                        previous_path = os.environ["PATH"]
                        previous_percent = os.environ.get("CAELESTIA_BENCH_PLANT_PERCENT")
                        try:
                            os.environ["PATH"] = str(Path(args.qt) / "bin") + os.pathsep + previous_path
                            os.environ["CAELESTIA_BENCH_PLANT_PERCENT"] = str(args.plant_percent)
                            measurement = json.loads(command(cmd, timeout=30, cwd=output))
                        finally:
                            os.environ["PATH"] = previous_path
                            if previous_percent is None:
                                os.environ.pop("CAELESTIA_BENCH_PLANT_PERCENT", None)
                            else:
                                os.environ["CAELESTIA_BENCH_PLANT_PERCENT"] = previous_percent
                        raw[native_area] = measurement
                        values[native_area + ".cyclesPerOperation"] = measurement["cyclesPerOperation"]
                if selected & {"idle", "panels"}:
                    metric = "Quick" if {"idle", "panels"} <= selected else "Idle" if "idle" in selected else "Panel"
                    cmd = [PS, "-NoProfile", "-File", HERE.parent / "bench/tools/Measure-ShellRuntime.ps1",
                           "-QtPrefix", args.qt, "-BuildRoot", ident["build"], "-SourceRoot", ident["source"],
                           "-ConfigRoot", config_root,
                           "-RunRoot", path, "-Metric", metric, "-Mode", "Offscreen", "-Cycles", "8",
                           "-WarmupSeconds", "2", "-IdleSeconds", "2",
                           "-Plant", plant if plant in ("CPU", "Resources", "Panel", "Reload", "Sensitivity") else "None",
                           "-PlantPercent", args.plant_percent]
                    if side == "B" and plant in ("Panel", "Resources", "Sensitivity"):
                        cmd += ["-PlantReference", reference]
                    commands.append(list(map(str, cmd)))
                    worker(cmd, path, LIMIT_SECONDS - (time.monotonic() - started))
                    v, raw["runtime"] = runtime_values(path)
                    values.update(v)
                if selected & {"lifecycle", "update"}:
                    life = output / f"{side}-{index}-lifecycle"
                    cmd = [PS, "-NoProfile", "-File", HERE.parent / "bench/tools/Measure-ShellLifecycle.ps1",
                           "-QtPrefix", args.qt, "-BuildRoot", ident["build"], "-SourceRoot", ident["source"],
                           "-ConfigRoot", config_root,
                           "-RunRoot", life, "-Plant", "Reload" if plant == "Sensitivity" else
                           plant if plant in ("Reload", "Startup", "Update") else "None",
                           "-PlantPercent", args.plant_percent]
                    if side == "B" and plant in ("Reload", "Sensitivity"):
                        cmd += ["-PlantReference", reference]
                    commands.append(list(map(str, cmd)))
                    worker(cmd, life, LIMIT_SECONDS - (time.monotonic() - started))
                    raw["lifecycle"] = read(life / "trial.json")
                    values.update(raw["lifecycle"]["values"])
                if "scheme" in selected:
                    scheme_path = output / f"{side}-{index}-scheme"
                    scheme_path.mkdir()
                    cmd = [args.scheme_python, HERE.parent / "bench/tools/Measure-SchemeBench.py",
                           "--source", ident["source"], "--output", scheme_path]
                    if plant == "Scheme":
                        cmd.append("--plant")
                    commands.append(list(map(str, cmd)))
                    worker(cmd, scheme_path, LIMIT_SECONDS - (time.monotonic() - started))
                    raw["scheme"] = read(scheme_path / "trial.json")
                    values.update(raw["scheme"]["values"])
                workload_seconds = time.monotonic() - workload_started
                data["workloadSeconds"] += workload_seconds
                machine_started = time.monotonic()
                after = machine()
                check_machine(initial, after)
                data["machineCheckSeconds"] += time.monotonic() - machine_started
                integrity_started = time.monotonic()
                if (sha(Path(ident["build"]) / "logs/build.json") != ident["buildRecordSha256"]
                        or sha(Path(ident["build"]) / "quickshell/qs.exe") != ident["executableSha256"]):
                    raise ValueError("Measured build changed during the session. Aborting.")
                if any(sha(Path(ident["build"]) / p) != digest for p, digest in ident["nativeModules"].items()):
                    raise ValueError("A measured native module changed during the session.")
                if any(sha(Path(ident["build"]) / p) != digest for p, digest in ident["runtimeFiles"].items()):
                    raise ValueError("A measured runtime file changed during the session.")
                if any(sha(Path(args.qt) / p) != digest for p, digest in data["machine"]["qtRuntimeFiles"].items()):
                    raise ValueError("A measured Qt runtime file changed during the session.")
                if git(ident["source"], "rev-parse", "HEAD") != ident["revision"] or git(ident["source"], "status", "--porcelain"):
                    raise ValueError("A measured source checkout changed during the session.")
                if any(sha(HERE.parent / p) != digest for p, digest in data["protocol"]["filesSha256"].items()):
                    raise ValueError("Measurement tooling changed during the session.")
                for stable in data["sides"].values():
                    if stable.get("nativeProbeIdentity"):
                        verify_probe(stable["nativeProbeRoot"], stable["nativeProbeIdentity"])
                post_integrity_seconds = time.monotonic() - integrity_started
                data["integrityCheckSeconds"] += post_integrity_seconds
                total = after["systemTimes100ns"]["total"] - before["systemTimes100ns"]["total"]
                load = 100 * (1 - (after["systemTimes100ns"]["idle"] - before["systemTimes100ns"]["idle"]) / total) if total else 0
                if load > data["protocol"]["maximumSystemCpuPercent"]:
                    data["rejectedTrial"] = {"side": side, "index": index, "raw": raw,
                                             "values": values, "commands": commands, "machineBefore": before,
                                             "machineAfter": after, "systemCpuPercent": load}
                    raise ValueError(f"Machine became busy during {side}-{index}: {load:.1f}% CPU, maximum 60%.")
                data["trials"].append({"side": side, "index": index, "values": values, "raw": raw,
                                       "commands": commands, "machineBefore": before, "machineAfter": after,
                                       "systemCpuPercent": load,
                                       "workerAcquisitionSeconds": workload_seconds,
                                       "integrityCheckSeconds": pre_integrity_seconds + post_integrity_seconds,
                                       "wallSeconds": time.monotonic() - trial_started})
                data.pop("inFlightTrial", None)
                if side == "A":
                    write(reference, values)
                data["wallSeconds"] = time.monotonic() - started
                write(output / "results.json", data)
                # Preserve all staged bytes and evidence. Reuse/cleanup is an
                # explicit later operation, never part of a measured trial.
        # A may have changed while the final B trial was running. Recheck both
        # identities at the session boundary, not only the last measured side.
        integrity_started = time.monotonic()
        for stable in data["sides"].values():
            if stable.get("nativeProbeIdentity"):
                verify_probe(stable["nativeProbeRoot"], stable["nativeProbeIdentity"])
            if (git(stable["source"], "rev-parse", "HEAD") != stable["revision"]
                    or git(stable["source"], "status", "--porcelain")
                    or sha(Path(stable["build"]) / "logs/build.json") != stable["buildRecordSha256"]
                    or any(sha(Path(stable["build"]) / p) != digest
                           for p, digest in stable["runtimeFiles"].items())):
                raise ValueError("A measured source or payload changed before session completion.")
        data["integrityCheckSeconds"] += time.monotonic() - integrity_started
        remaining_budget(30)
        data["summary"] = summarize(data)
        data["trialLoopWallSeconds"] = time.monotonic() - measurement_started
        data["workerAcquisitionSeconds"] = data.pop("workloadSeconds")
        data["measurementSeconds"] = None
        data["measurementTimeStatus"] = "Use per-metric raw timers; worker acquisition wall includes staging, not a scored duration."
        data["wallSeconds"] = time.monotonic() - started
        write(output / "results.json", data)
        report(data, output / "report.html")
        remaining_budget(30)
        data["complete"] = True
        data["wallSeconds"] = time.monotonic() - started
        write(output / "results.json", data)
        print(f'{headline(data["summary"])} ({data["wallSeconds"]:.0f} s; {output / "results.json"})')
        for name, metric in data["summary"]["metrics"].items():
            print(f'{label(name)}: {reading(metric)}')
        # Only a resolved regression fails. "Unresolved" is reported with its
        # reading ("possibly slower, up to +X%") but A/A runs land there by chance.
        return 2 if data["summary"]["overall"] == "regressed" else 0
    except Exception as error:
        record_failure(data, error, output, started)
        print(f"FAILED in {data['wallSeconds']:.3f}s: {error}", file=sys.stderr)
        return 1
    finally:
        DEADLINE = None
        if power_state:
            execution_state(power_state)


def main():
    parser = argparse.ArgumentParser(__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("run")
    for name in ("qt", "a", "b", "output"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--source-a")
    p.add_argument("--source-b")
    p.add_argument("--select")
    p.add_argument("--scheme-python")
    p.add_argument("--native-a")
    p.add_argument("--native-b")
    p.add_argument("--runs", type=int, choices=(7, 8, 9))
    p.add_argument("--order", choices=("AB", "counterbalanced"), default="counterbalanced")
    p.add_argument("--plant-percent", type=float, default=25)
    p.add_argument("--purpose", choices=("diagnostic", "floor-discovery", "held-out", "confirm"), default="diagnostic")
    p.add_argument("--calibration")
    p.add_argument("--not-covered", nargs="*")
    p.add_argument("--area", type=str.lower, choices=("all", "providers") + AREAS, default="all")
    p.add_argument("--plant", type=lambda s: next((p for p in PLANTS if p.lower() == s.lower()), s),
                   choices=PLANTS, default="None")
    p = sub.add_parser("summarize")
    p.add_argument("results")
    p.add_argument("--output", required=True, help="New external directory, preserving acquisition evidence")
    p = sub.add_parser("reanalyze")
    p.add_argument("results")
    p.add_argument("--output", required=True)
    p.add_argument("--floors", required=True)
    p = sub.add_parser("calibrate")
    p.add_argument("results", nargs="+")
    p.add_argument("--output", required=True)
    p = sub.add_parser("select")
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("gate", help="Fail-closed automation, not acquisition exit status")
    p.add_argument("results")
    p.add_argument("--expect", choices=("improved", "same"), default="improved")
    p.add_argument("--qualification", required=True)
    p = sub.add_parser("qualify", help="Independent same-artifact A/A and added-cost evidence")
    p.add_argument("--aa", nargs="+", required=True)
    p.add_argument("--added", nargs="+", required=True)
    p.add_argument("--calibration", required=True)
    p.add_argument("--output", required=True)
    p = sub.add_parser("profile", help="Inspect trace/QML capability and write a bounded capture plan")
    p.add_argument("--output", required=True)
    p.add_argument("--qt", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--seconds", type=int, choices=range(5, 121), default=30)
    p = sub.add_parser("monitor", help="Separate read-only longer-session process observation")
    p.add_argument("--manifest", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--seconds", type=int, required=True)
    p.add_argument("--interval", type=float, default=5)
    p.add_argument("--allow-process-observation", action="store_true")
    p = sub.add_parser("scenarios", help="Public feature and coverage manifest")
    p = sub.add_parser("export-public", help="Allowlisted summary only; no raw upload")
    p.add_argument("results")
    p.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.action in ("gate", "qualify", "profile", "monitor", "scenarios", "export-public"):
        sys.path.insert(0, str(HERE.parent / "bench"))
        import campaign
        return campaign.main(args, sys.modules[__name__])
    if args.action == "run":
        return run(args)
    if args.action == "calibrate":
        target = external_output(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        write(target, calibrate(args.results))
        return 0
    if args.action == "select":
        source = HERE.parent.parent
        common = git(source, "merge-base", args.base, args.head)
        changed = git(source, "diff", "--name-only", common, args.head).splitlines()
        pin_path = "windows/deps/quickshell"
        if pin_path in changed:
            a = git(source, "rev-parse", common + ":" + pin_path)
            b = git(source, "rev-parse", args.head + ":" + pin_path)
            changed += [pin_path + "/" + p for p in git(source / pin_path, "diff", "--name-only", a, b).splitlines()]
        mapping = read(HERE.parent / "bench/map.json")
        selection = select_paths(changed, mapping)
        if args.json:
            print(json.dumps(selection))
        else:
            print("\n".join(selection["areas"]))
            for path in selection["notCovered"]:
                print(f"Not covered (native provider, disabled in probes): {path}", file=sys.stderr)
        return 0
    data = read(args.results)
    if args.action == "reanalyze":
        if summarize(data) != data["summary"]:
            raise ValueError("Original acquisition summary does not replay.")
        output = external_output(args.output)
        output.mkdir(parents=True, exist_ok=False)
        data["acquisitionSummary"] = data["summary"]
        data["acquisitionId"] = data.get("acquisitionId") or hashlib.sha256(
            json.dumps([data["date"], data["command"], data["trials"]], sort_keys=True).encode()).hexdigest()
        data["analysisPolicy"] = POLICY
        calibration = read(args.floors)
        data["protocol"]["floorsPercent"] = calibration["floorsPercent"]
        data["protocol"]["floorCalibration"] = calibration
        data["removed"].update(POLICY["excludedMetrics"])
        data["summary"] = summarize(data)
        data["analysisReplay"] = {"analysisSha256": sha(__file__), "source": str(Path(args.results).resolve())}
        write(output / "results.json", data)
        report(data, output / "report.html")
        print(f'Applied {POLICY["version"]}; original observations and original summary retained. {data["summary"]["overall"]}')
        return 0
    reproduced = summarize(data)
    if reproduced != data["summary"]:
        raise ValueError("Stored verdict differs from raw-data verdict.")
    output = external_output(args.output)
    output.mkdir(parents=True)
    write(output / "results.json", data)
    report(data, output / "report.html")
    print(json.dumps(reproduced, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
