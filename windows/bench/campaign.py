"""Campaign controls for ShellBench, not a second measurement framework."""
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time
import uuid
import re

HERE = Path(__file__).resolve().parent
PRIVATE = "PRIVATE-local-evidence; never upload raw receipts automatically"
TAIL_MINIMUM = 200


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def raw_identity(data):
    """Analysis, paths to reports, renamed IDs and edited verdicts are not new work."""
    acquisition = data.get("acquisitionId", "")
    if not re.fullmatch(r"[a-f0-9]{32}", acquisition):
        raise ValueError("Campaign evidence requires an original acquisitionId.")
    trial_ids = [digest(t["raw"]) for t in data["trials"]]
    if len(trial_ids) != len(set(trial_ids)):
        raise ValueError("Reused raw trials within one acquisition are not independent observations.")
    return {"acquisitionId": acquisition,
            "rawIdentity": digest([{"index": t["index"], "side": t["side"], "raw": t["raw"]}
                                   for t in data["trials"]]),
            "trialRawIdentities": sorted(set(trial_ids))}


class AcquisitionRegistry:
    def __init__(self):
        self.ids, self.raw, self.trials = set(), set(), set()

    def add(self, data):
        identity = raw_identity(data)
        if (identity["acquisitionId"] in self.ids or identity["rawIdentity"] in self.raw
                or self.trials.intersection(identity["trialRawIdentities"])):
            raise ValueError("Reused acquisition or raw trials are not independent or held-out evidence.")
        self.ids.add(identity["acquisitionId"])
        self.raw.add(identity["rawIdentity"])
        self.trials.update(identity["trialRawIdentities"])
        return identity


def replay(path, bench):
    data = bench.read(path)
    if (Path(path).parent / "outer-deadline.json").exists():
        raise ValueError("Outer deadline failure accompanies this acquisition.")
    if data.get("error") or data.get("evidenceClass") == "fixture":
        raise ValueError("Failed acquisitions and fixtures cannot qualify a campaign.")
    if not data.get("protocol", {}).get("rawRequired"):
        raise ValueError("Campaign evidence requires replayable raw observations.")
    if "analysisReplay" in data or "acquisitionSummary" in data:
        raise ValueError("Analysis replays cannot supply original independent acquisitions.")
    raw_identity(data)
    if data.get("complete") is not True:
        raise ValueError("Incomplete or killed acquisition cannot enter a campaign.")
    if any("tiling" in t["raw"] or "tracker" in t["raw"] for t in data["trials"]):
        for side in ("A", "B"):
            probe = data["sides"][side].get("nativeProbeIdentity")
            if not probe or any(not probe.get(k) for k in ("executableSha256", "receiptSha256", "toolchain")):
                raise ValueError("Native acquisition lacks immutable probe/toolchain identity.")
    result = bench.summarize(data)
    if result != data.get("summary"):
        raise ValueError("Stored summary does not reproduce from raw work.")
    if not 0 < data.get("wallSeconds", 0) <= 580:
        raise ValueError("Missing or out-of-budget acquisition time.")
    if data.get("plantB", "None") != "None":
        percent = data.get("plantPercent", 0)
        if not math.isfinite(percent) or not 0 < percent <= 100:
            raise ValueError("Added-cost qualification requires a positive finite plant size.")
        area = "tiling" if data["plantB"] == "Sensitivity" and any("tiling" in t["raw"] for t in data["trials"]) else data["plantB"].lower()
        if area in ("tiling", "tracker", "audio", "media", "tray", "notifications", "quota"):
            for trial in data["trials"]:
                entries = ([trial["raw"][area]] if area in ("tiling", "tracker")
                           else [r for r in trial["raw"].get("services", []) if r["area"] == area])
                if not entries:
                    raise ValueError("Added-cost work has no raw operation evidence.")
                for raw in entries:
                    expected = raw["operations"] * (1 + percent / 100 if trial["side"] == "B" else 1)
                    if abs(raw["actualOperations"] - expected) > 1 or (
                            trial["side"] == "B" and raw["actualOperations"] <= raw["operations"]):
                        raise ValueError("Added-cost operation count does not match the declared plant.")
        verify_timing_plants(data)
    return data, result


def environment(data):
    """Qualification is local to this configuration, not a universal floor."""
    p = data["protocol"]
    return {key: p.get(key) for key in
            ("version", "order", "mode", "runs", "cachePolicy", "floorsPercent",
             "settingsSha256", "filesSha256", "warmupSeconds", "idleSeconds",
             "panelWarmupSeconds", "panelCycles", "selectedAreas", "instrumentation",
             "floorCalibrationId")} | {
        "machine": {key: data["machine"].get(key) for key in ("id", "qtVersion", "qtCoreSha256", "qtRuntimeFiles")},
        "nativeProbes": {side: data["sides"][side].get("nativeProbeIdentity")
                         for side in ("A", "B")}}


def payload(side):
    return {k: side[k] for k in ("revision", "backendRevision", "executableSha256", "nativeModules",
                                 "buildRecordSha256", "runtimeFiles")} | {
        "nativeProbeIdentity": side.get("nativeProbeIdentity")}


def discovery_environment(data):
    value = environment(data)
    value.pop("floorsPercent", None)
    value.pop("floorCalibrationId", None)
    return value


def calibrate(paths, bench):
    registry, inputs, ratios, context = AcquisitionRegistry(), [], {}, None
    if len(paths) < 3:
        raise ValueError("Floor discovery requires at least three independent original A/A acquisitions.")
    for path in paths:
        data, result = replay(path, bench)
        if (data["plantB"] != "None" or data["protocol"].get("purpose") != "floor-discovery"
                or data["protocol"].get("floorCalibrationId")):
            raise ValueError("Calibration requires original unplanted floor-discovery acquisitions.")
        if payload(data["sides"]["A"]) != payload(data["sides"]["B"]):
            raise ValueError("Floor discovery requires identical A/A payload/probe identities.")
        current = discovery_environment(data)
        if context is not None and context != current:
            raise ValueError("Floor discovery environment changed.")
        context = current
        inputs.append({"path": str(Path(path).resolve()), "sha256": bench.sha(path),
                       **registry.add(data)})
        for name, metric in result["metrics"].items():
            ratios.setdefault(name, []).extend(metric["pairedLogRatios"])
    floors = {}
    for name, values in ratios.items():
        center = statistics.median(values)
        floors[name] = max(2, 1.5 * 1.4826 * statistics.median(abs(x - center) for x in values) * 100)
    record = {"schemaVersion": 2, "role": "frozen-floor-discovery", "protocol": bench.PROTOCOL,
              "privacy": PRIVATE, "method": "max(2%, 1.5 * 1.4826 * MAD of paired A/A log ratios * 100)",
              "environment": context, "inputs": inputs, "floorsPercent": floors}
    record["identitySha256"] = digest(record)
    return record


def load_calibration(path, bench):
    if not path:
        raise ValueError("Explicit frozen calibration provenance is required.")
    record = bench.read(path)
    if record.get("role") != "frozen-floor-discovery" or record.get("protocol") != bench.PROTOCOL:
        raise ValueError("Missing current frozen floor-discovery provenance.")
    for item in record["inputs"]:
        if bench.sha(item["path"]) != item["sha256"]:
            raise ValueError("Floor discovery input changed.")
    expected = calibrate([i["path"] for i in record["inputs"]], bench)
    if expected != record:
        raise ValueError("Frozen calibration does not reproduce from original raw discovery trials.")
    registry = AcquisitionRegistry()
    for item in record["inputs"]:
        registry.add(bench.read(item["path"]))
    return record, registry


def held_out(data, calibration, purpose):
    if (data["protocol"].get("purpose") != purpose
            or data["protocol"].get("floorCalibrationId") != calibration["identitySha256"]
            or data["protocol"]["floorsPercent"] != calibration["floorsPercent"]
            or discovery_environment(data) != calibration["environment"]):
        raise ValueError("Acquisition lacks matching frozen, held-out calibration provenance.")


def claimability(data, name):
    if name.startswith("panel.") and name.endswith(".p95Ms"):
        panel = name.split(".")[1]
        counts = [sum(a.get("panel") == panel for a in t["raw"].get("runtime", {}).get("actions", []))
                  for t in data["trials"]]
        enough = bool(counts) and min(counts) >= TAIL_MINIMUM
        return {"claimable": enough, "status": "claimable" if enough else "diagnostic-only-insufficient-observations",
                "minimumPerPanelPerTrial": TAIL_MINIMUM, "observationsPerTrial": counts}
    return {"claimable": True, "status": "claimable"}


def qualify(args, bench):
    output = bench.external_output(args.output)
    output.mkdir(parents=True)
    result, _ = qualification_report(args.aa, args.added, getattr(args, "calibration", None), bench)
    bench.write(output / "qualification.json", result)
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "qualified" else 3


def qualification_report(aa_paths, added_paths, calibration_path, bench):
    calibration, registry = load_calibration(calibration_path, bench)
    receipts, observations = [], []
    context = None
    for group, paths in (("aa", aa_paths), ("added", added_paths)):
        for path in paths:
            data, summary = replay(path, bench)
            identity = registry.add(data)
            held_out(data, calibration, "held-out")
            if payload(data["sides"]["A"]) != payload(data["sides"]["B"]):
                raise ValueError("Controls require identical unmodified A/A source and native payloads.")
            current = environment(data)
            if context is not None and context != current:
                raise ValueError("Qualification configuration, ordering or tooling changed.")
            context = current
            if (group == "aa") != (data["plantB"] == "None"):
                raise ValueError("A/A must be unplanted; added-cost controls must name their plant.")
            receipts.append({"path": str(Path(path).resolve()), "sha256": bench.sha(path), "group": group, **identity})
            observations.append((group, data, summary))
    names = set().union(*(r["metrics"] for _, _, r in observations))
    metrics = {}
    for name in sorted(names):
        aa = [r["metrics"].get(name) for g, _, r in observations if g == "aa"]
        planted = [(d["plantB"], nominal_effect(d, name), r["metrics"][name])
                   for g, d, r in observations if g == "added" and name in r["metrics"]
                   and affected(d["plantB"], name)]
        # Report every unresolved outcome and miss. Never silently drop it.
        groups = {}
        for plant, nominal, metric in planted:
            group_effect = {k: nominal[k] for k in ("unit", "amount", "basis")}
            groups.setdefault((plant, json.dumps(group_effect, sort_keys=True)), []).append((metric, nominal))
        detected = [{"plant": plant, "nominalEffect": json.loads(nominal),
                     "metricSpecificEffects": [effect for _, effect in values],
                     "repeats": len(values), "outcomes": [m["verdict"] for m, _ in values],
                     "observedPercent": [m["deltaPercent"] for m, _ in values],
                     "resolutionPercent": [m["resolutionPercent"] for m, _ in values]}
                    for (plant, nominal), values in sorted(groups.items())]
        passed = [g for g in detected if g["repeats"] >= 3
                  and all(v == "regressed" for v in g["outcomes"])]
        policies = [claimability(d, name) for _, d, _ in observations]
        claimable = all(p["claimable"] for p in policies)
        metrics[name] = {
            "qualified": claimable and len(aa) >= 3 and all(m and m["verdict"] == "same" for m in aa) and bool(passed),
            "claimStatus": "claimable" if claimable else "diagnostic-only-insufficient-observations",
            "observationPolicy": policies,
            "aaOutcomes": [m["verdict"] if m else "missing" for m in aa],
            "addedCost": detected,
            "smallestTestedDetectedNominalPercent": min(
                (g["nominalEffect"]["amount"] for g in passed if g["nominalEffect"]["unit"] == "percent-extra-operations"),
                default=None),
            "limits": "Only tested plants on this configuration. No extrapolation to smaller effects or whole-shell savings."}
    result = {"schemaVersion": 2, "privacy": PRIVATE, "protocol": bench.PROTOCOL, "environment": context,
              "calibration": {"path": str(Path(calibration_path).resolve()), "sha256": bench.sha(calibration_path),
                              "identitySha256": calibration["identitySha256"]},
              "inputs": receipts, "metrics": metrics,
              "status": "qualified" if metrics and all(m["qualified"] for m in metrics.values()) else "partial"}
    return result, registry


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


def positive(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise ValueError("Missing positive plant evidence: " + label)
    return value


def verify_timing_plants(data):
    plant = data["plantB"]
    pairs = {t["index"]: t for t in data["trials"] if t["side"] == "A"}
    supported = False
    for trial in data["trials"]:
        if trial["side"] != "B":
            continue
        raw, baseline = trial["raw"], pairs[trial["index"]]["values"]
        if plant in ("Panel", "Sensitivity") and "runtime" in raw:
            runtime = raw["runtime"]
            shown = [a for a in runtime["actions"] if a["panel"] != "idle"]
            for action in shown:
                panel = action["panel"]
                reference = positive(baseline.get(f"panel.{panel}.p50Ms"), "paired panel p50")
                recorded = runtime.get("plantReferenceValues", {}).get(f"panel.{panel}.p50Ms")
                if recorded != reference:
                    raise ValueError("Panel plant lacks the actual paired reference.")
                requested = positive(runtime.get("plantPanelDelaysMs", {}).get(panel), "panel requested delay")
                if requested != round(reference * data["plantPercent"] / 100):
                    raise ValueError("Panel delay does not match the recorded p50 reference.")
                if (action.get("plantDelayFires") != 1 or action.get("plantDelayRequestedMs") != requested
                        or positive(action.get("plantDelayMeasuredMs"), "actual fired delay") + 1 < requested):
                    raise ValueError("Panel timing plant did not actually fire for the observed opening.")
            supported |= bool(shown)
        if plant in ("Reload", "Startup", "Update", "Sensitivity") and "lifecycle" in raw:
            life = raw["lifecycle"]
            kind = "Reload" if plant == "Sensitivity" else plant
            if life.get("plant") != kind:
                raise ValueError("Lifecycle plant label differs from requested execution.")
            if kind in ("Reload", "Startup"):
                requested = positive(life.get("reloadExtraMs" if kind == "Reload" else "startupExtraMs"), "lifecycle requested delay")
                if kind == "Reload":
                    reference = positive(baseline.get("qmlReloadToReadyMs"), "paired reload reference")
                    if life.get("reloadReferenceMs") != reference or not math.isclose(requested, round(reference * data["plantPercent"] / 100, 3)):
                        raise ValueError("Reload plant does not match paired reference.")
                elif requested != 400:
                    raise ValueError("Startup plant is a fixed 400ms cost, not the requested percentage.")
                events = [e for e in life.get("plantEvidence", []) if e.get("kind") == kind]
                if not events or any(e.get("requestedMs") != requested or e.get("iterations", 0) <= 0
                                     or positive(e.get("elapsedMs"), "executed lifecycle delay") + 1 < requested for e in events):
                    raise ValueError("Lifecycle timing plant has no executed delay marker.")
                supported = True
            elif kind == "Update":
                assembly = life.get("assemblyPlantEvidence", [])
                if (life.get("activationValidationHashes") != 256 or life.get("assemblyValidationHashes") != 256
                        or not assembly or assembly[-1].get("hashesCompleted") != 256
                        or not re.fullmatch("[a-fA-F0-9]{64}", life.get("activationValidationChecksum", ""))
                        or not re.fullmatch("[a-fA-F0-9]{64}", assembly[-1].get("checksum", ""))):
                    raise ValueError("Update plant lacks actually completed hash work.")
                positive(life.get("activationExtraValidationMs"), "activation hash duration")
                positive(assembly[-1].get("elapsedMs"), "assembly hash duration")
                supported = True
        if plant == "Scheme" and "scheme" in raw:
            for work in raw["scheme"]["work"]:
                if (work.get("extraQuantizations") != 8 or len(work.get("extraQuantizationChecksums", [])) != 8
                        or any(not re.fullmatch("[a-f0-9]{64}", c) for c in work["extraQuantizationChecksums"])):
                    raise ValueError("Scheme plant lacks completed additional quantizations.")
                positive(work.get("extraQuantizationNs"), "additional quantizer duration")
                supported = True
        if plant == "Sensitivity" and "tiling" in raw:
            supported = True  # The operation-count check in replay validates this portion.
        if plant in ("Resources", "Sensitivity") and "runtime" in raw and "privateMiB" in trial["values"]:
            positive(raw["runtime"].get("plantResourceBytes"), "retained resource bytes")
            supported = True  # derive_runtime verifies actual retention.
    if plant in ("Panel", "Reload", "Startup", "Update", "Scheme", "Sensitivity", "Resources") and not supported:
        raise ValueError("Requested timing/resource plant executed no relevant observed work.")


def nominal_effect(data, name):
    plant = data["plantB"]
    if name.startswith("panel."):
        panel = name.split(".")[1]
        amounts = [t["raw"]["runtime"]["plantPanelDelaysMs"][panel] for t in data["trials"] if t["side"] == "B"]
        unit, amount, basis = "percent-of-paired-p50", data["plantPercent"], "p50 delay reference, not p95 percentage"
    elif name == "qmlReloadToReadyMs":
        amounts = [t["raw"]["lifecycle"]["reloadExtraMs"] for t in data["trials"] if t["side"] == "B"]
        unit, amount, basis = "percent-of-paired-reload", data["plantPercent"], "paired reload milliseconds"
    elif name == "coldStartToReadyMs":
        return {"unit": "milliseconds", "amount": 400, "basis": "fixed startup burn"}
    elif name == "isolatedActivationMs":
        return {"unit": "additional-hashes", "amount": 256, "basis": "actual activation hash completions"}
    elif name.startswith("scheme."):
        return {"unit": "additional-quantizations", "amount": 8, "basis": "actual quantizer completions"}
    elif name in ("privateMiB", "workingSetMiB"):
        amounts = [t["raw"]["runtime"]["plantResourceBytes"] / 1024**2
                   for t in data["trials"] if t["side"] == "B"]
        unit, amount, basis = "percent-of-paired-private-commit", data["plantPercent"], "retained MiB; not a working-set percentage"
    else:
        return {"unit": "percent-extra-operations", "amount": data["plantPercent"], "basis": "nominal operation count"}
    a = {t["index"]: t["values"][name] for t in data["trials"] if t["side"] == "A"}
    relative = [100 * cost / a[t["index"]] for cost, t in zip(
        amounts, [t for t in data["trials"] if t["side"] == "B"])]
    quantity = "addedMiBByPair" if name in ("privateMiB", "workingSetMiB") else "addedMillisecondsByPair"
    return {"unit": unit, "amount": amount, "basis": basis, quantity: amounts,
            "relativeToThisMetricPercentByPair": relative}


def gate(args, bench):
    data, summary = replay(args.results, bench)
    if data["plantB"] != "None":
        raise ValueError("A planted acquisition cannot demonstrate a production improvement.")
    qualification = bench.read(args.qualification)
    if bench.sha(qualification["calibration"]["path"]) != qualification["calibration"]["sha256"]:
        raise ValueError("Frozen calibration changed.")
    for record in qualification["inputs"]:
        if bench.sha(record["path"]) != record["sha256"]:
            raise ValueError("Qualification input changed.")
    rebuilt, registry = qualification_report(
        [r["path"] for r in qualification["inputs"] if r["group"] == "aa"],
        [r["path"] for r in qualification["inputs"] if r["group"] == "added"],
        qualification["calibration"]["path"], bench)
    if rebuilt != qualification:
        raise ValueError("Qualification verdict does not reproduce from independent held-out raw controls.")
    registry.add(data)
    calibration, _ = load_calibration(qualification["calibration"]["path"], bench)
    held_out(data, calibration, "confirm")
    if qualification["environment"] != environment(data):
        raise ValueError("Qualification does not apply to this environment/protocol/configuration.")
    metrics = summary["metrics"]
    if any(not claimability(data, n)["claimable"] for n in metrics):
        raise ValueError("Tail metric is diagnostic-only: at least 200 observations per panel per trial required.")
    if any(not qualification["metrics"].get(n, {}).get("qualified") for n in metrics):
        raise ValueError("A selected metric lacks independent A/A and added-cost qualification.")
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


def public_summary(data, bench):
    """Construct only allowlisted fields, never recursive blacklisting/redaction."""
    allowed = set(bench.read(HERE / "map.json")["floorsPercent"]) | {"fixture.nsPerOperation"}
    verdicts = {"same", "improved", "regressed", "unresolved"}
    numeric = ("delta", "deltaPercent", "floorPercent", "resolutionPercent")
    result = {"schemaVersion": 1, "privacy": "allowlisted-public-summary",
              "wholeAppCertification": False, "failureRecorded": bool(data.get("error") or data.get("failure")),
              "metrics": {}}
    result["evidenceClass"] = (data.get("evidenceClass") if data.get("evidenceClass") in
                               ("fixture", "offscreen-or-isolated-logic", "profile", "process-observation")
                               else "unclassified")
    if data.get("protocol", {}).get("version") == bench.PROTOCOL:
        result["protocol"] = bench.PROTOCOL
    if "trials" in data and not result["failureRecorded"]:
        summary = bench.summarize(data)
        if summary != data.get("summary"):
            raise ValueError("Public export requires a replayable stored summary.")
        result["trialCount"] = len(data["trials"])
        result["overall"] = summary["overall"] if summary["overall"] in verdicts else "unresolved"
        for name in sorted(allowed.intersection(summary["metrics"])):
            metric = summary["metrics"][name]
            row = {"verdict": metric["verdict"] if metric["verdict"] in verdicts else "unresolved"}
            for key in numeric:
                value = metric.get(key)
                if isinstance(value, (int, float)) and math.isfinite(value):
                    row[key] = value
            for side in ("A", "B"):
                value = metric.get(side, {}).get("median")
                if isinstance(value, (int, float)) and math.isfinite(value):
                    row[side + "Median"] = value
            policy = claimability(data, name)
            row["observationPolicySatisfied"] = policy["claimable"]
            result["metrics"][name] = row
    elif isinstance(data.get("metrics"), dict):
        # Qualification exports do not include raw receipts, local paths,
        # calibration/environment identities or free-form nominal-effect text.
        for name in sorted(allowed.intersection(data["metrics"])):
            metric = data["metrics"][name]
            result["metrics"][name] = {"qualified": metric.get("qualified") is True,
                                      "aaOutcomes": [v for v in metric.get("aaOutcomes", []) if v in verdicts]}
    for key in ("captureExecuted", "complete", "scoredBenchmark"):
        if isinstance(data.get(key), bool):
            result[key] = data[key]
    return result


def export_public(args, bench):
    output = bench.external_output(args.output)
    data = bench.read(args.results)
    if data.get("schemaVersion") == 2 and "calibration" in data and "inputs" in data:
        rebuilt, _ = qualification_report(
            [r["path"] for r in data["inputs"] if r["group"] == "aa"],
            [r["path"] for r in data["inputs"] if r["group"] == "added"],
            data["calibration"]["path"], bench)
        if rebuilt != data:
            raise ValueError("Qualification must reproduce before public summary export.")
    summary = public_summary(data, bench)
    output.mkdir(parents=True)
    bench.write(output / "public-summary.json", summary)
    print(json.dumps(summary, indent=2))
    return 0


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
                handle = self.k.OpenProcess(0x1000 | 0x100000, False, entry["pid"])
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
    result = {"schemaVersion": 1, "privacy": PRIVATE, "evidenceClass": "process-observation", "scoredBenchmark": False,
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
    result = {"schemaVersion": 1, "privacy": PRIVATE, "workflow": "explore/profile", "scoredBenchmark": False,
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
        return {"qualify": qualify, "gate": gate, "profile": profile, "monitor": monitor,
                "export-public": export_public}[args.action](args, bench)
    except (ValueError, KeyError, OSError) as error:
        print(json.dumps({"status": "refused", "reason": str(error)}))
        return 1
