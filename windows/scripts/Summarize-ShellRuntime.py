"""Summarize Measure-ShellRuntime CSVs without third-party dependencies."""

import argparse
import csv
import hashlib
import json
import math
import re
import statistics
from pathlib import Path


RESOURCES = {
    "privateMiB": ("privateBytes", 1024**2),
    "workingSetMiB": ("workingSet", 1024**2),
    "handles": ("handles", 1),
    "gdi": ("gdi", 1),
    "user": ("user", 1),
    "threads": ("threads", 1),
    "cpuCorePercent": ("cpuCorePercent", 1),
    "cpuMachinePercent": ("cpuMachinePercent", 1),
}


def slope(rows, key, divisor):
    x = [row["elapsedSeconds"] / 60 for row in rows]
    y = [row[key] / divisor for row in rows]
    mx, my = statistics.mean(x), statistics.mean(y)
    return sum((a - mx) * (b - my) for a, b in zip(x, y)) / sum(
        (a - mx) ** 2 for a in x
    )


def distribution(values):
    return {
        "runs": len(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "spread": max(values) - min(values),
    }


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def summarize_trial(path):
    metadata = read_json(path / "metadata.json")
    completion = read_json(path / "completion.json")
    errors = list(completion["errors"])
    work = completion["work"]
    with (path / "samples.csv").open(encoding="utf-8-sig", newline="") as stream:
        rows = [
            {k: v if k == "phase" else float(v) for k, v in row.items()}
            for row in csv.DictReader(stream)
        ]
    actions_path = path / "actions.jsonl"
    actions = [
        json.loads(line)
        for line in actions_path.read_text(encoding="utf-8-sig").splitlines()
        if line.strip()
    ] if actions_path.exists() else []
    log = "\n".join(
        (path / name).read_text(encoding="utf-8-sig")
        for name in ("stdout.log", "stderr.log") if (path / name).exists()
    )
    warning_lines = [line for line in log.splitlines() if re.search(r"\bWARN\b", line)]
    diagnostics = [
        line for line in log.splitlines()
        if re.search(r"\b(?:WARN|ERROR|FATAL|CRITICAL)\b", line)
        and not (
            metadata["mode"] == "Offscreen"
            and re.search(r"Cannot find font directory|does not support setting window masks", line)
        )
        and not (
            metadata["mode"] == "NonVisible"
            and "The foreground lock refused activation for the floating window" in line
        )
    ]
    errors.extend(diagnostics)
    trace_path = path / "transition.jsonl"
    dropped = 0
    if trace_path.exists():
        for line in trace_path.read_text(encoding="utf-8-sig").splitlines():
            event = json.loads(line)
            if event.get("event") == "trace_dropped":
                dropped += int(event["count"])
    if not completion["completed"] and not errors:
        errors.append("Trial did not complete.")
    if not rows or not metadata.get("screen", {}).get("ready"):
        errors.append("No confirmed render loop or process counters.")
    metrics = {}
    counters = {}
    category = metadata["metric"]
    if category == "Idle":
        idle = [r for r in rows if r["phase"] == "idle"]
        if (len(idle) < 2 or work["idleIntervals"] != len(idle) - 1
                or idle[-1]["elapsedSeconds"] - idle[0]["elapsedSeconds"] < metadata["workload"]["idleSeconds"]):
            errors.append("Idle intervals were not confirmed.")
        else:
            elapsed = idle[-1]["elapsedSeconds"] - idle[0]["elapsedSeconds"]
            cpu = idle[-1]["cpuSeconds"] - idle[0]["cpuSeconds"]
            core = 100 * cpu / elapsed
            if not 0 <= core <= 100 * metadata["logicalProcessors"] * 1.01:
                errors.append("CPU time exceeds available processor time.")
            metrics["idleCpuCorePercent"] = core
            metrics["idleCpuMachinePercent"] = core / metadata["logicalProcessors"]
            counters["idle"] = {"elapsedSeconds": elapsed, "cpuSeconds": cpu, "intervals": len(idle) - 1}
    elif category == "Resources":
        initial = [r for r in rows if r["phase"] == "initial-idle"]
        final = [r for r in rows if r["phase"] == "final-idle"]
        cycles = [r for r in rows if r["phase"] == "cycle"]
        expected = metadata["workload"]["cycles"]
        if (not initial or not final or len(cycles) != expected
                or work["cyclesCompleted"] != expected or work["panelsShown"] != expected):
            errors.append("Resource workload did not complete every cycle.")
        elif len(cycles) >= 2:
            for label in ("privateMiB", "workingSetMiB", "handles", "gdi", "user"):
                key, divisor = RESOURCES[label]
                start = statistics.median(r[key] / divisor for r in initial)
                end = statistics.median(r[key] / divisor for r in final)
                metrics[label + "NetGrowth"] = end - start
                metrics[label + "SlopePerMinute"] = slope(cycles, key, divisor)
                per_cycle = [dict(row, elapsedSeconds=row["cycle"] * 60) for row in cycles]
                metrics[label + "SlopePerCycle"] = slope(per_cycle, key, divisor)
                counters[label] = {
                    "initialIdleMedian": start, "finalIdleMedian": end,
                    "peak": max(r[key] / divisor for r in rows),
                    "recoverySlopePerMinute": slope(final, key, divisor) if len(final) >= 2 else None,
                }
    elif category == "Panel":
        shown = [a for a in actions if a["panel"] != "idle"]
        if len(shown) != metadata["workload"]["cycles"] or work["panelsShown"] != len(shown):
            errors.append("Not every requested panel was presented.")
        elif shown:
            metrics["panelRequestToFrameObservedMs"] = statistics.median(a["requestToFrameObservedMs"] for a in shown)
            metrics["panelShellRequestToFrameMs"] = statistics.median(a["shellRequestToFrameMs"] for a in shown)
            for panel in sorted({a["panel"] for a in shown}):
                panel_actions = [a for a in shown if a["panel"] == panel]
                prefix = "panel" + panel[0].upper() + panel[1:]
                metrics[prefix + "RequestToFrameObservedMs"] = statistics.median(
                    a["requestToFrameObservedMs"] for a in panel_actions
                )
                metrics[prefix + "ShellRequestToFrameMs"] = statistics.median(
                    a["shellRequestToFrameMs"] for a in panel_actions
                )
            counters["panelTransportOverheadMs"] = distribution([
                a["requestToFrameObservedMs"] - a["shellRequestToFrameMs"] for a in shown
            ])
    elif category == "Reload":
        if work["reloadsCompleted"] != 1 or not metadata.get("finalState", {}).get("ready"):
            errors.append("Reload did not render a new generation.")
        else:
            metrics["reloadRequestToReadyMs"] = metadata["reloadMilliseconds"]
    if len(actions) != work["actionsConfirmed"]:
        errors.append("Action log and work count disagree.")
    if any(not math.isfinite(v) for v in metrics.values()):
        errors.append("Non-finite metric.")
    return {
        "path": str(path), "metadata": metadata, "metrics": metrics, "counters": counters,
        "panelScales": {a["panel"]: a.get("dpr") for a in actions if a["panel"] != "idle"},
        "errorCount": len(errors), "errors": errors, "work": work,
        "transitionTraceDropped": dropped,
        "warnings": warning_lines,
        "systemCpuPercent": distribution([r["systemCpuPercent"] for r in rows]) if rows else None,
        "startupPhases": [line for line in log.splitlines() if "quickshell.startup" in line],
    }


def trial_contract(trial):
    meta = trial["metadata"]
    return {
        "machine": meta["machine"], "os": meta["os"],
        "logicalProcessors": meta["logicalProcessors"], "qtVersion": meta["qtVersion"],
        "metric": meta["metric"], "mode": meta["mode"], "workload": meta["workload"],
        "dpr": meta.get("screen", {}).get("dpr"),
        "width": meta.get("screen", {}).get("width"), "height": meta.get("screen", {}).get("height"),
        "windowsBuild": meta.get("windowsBuild"), "protocolSha256": meta.get("protocolSha256"),
        "controlGates": meta.get("controlGates"),
        "qtCoreSha256": meta.get("qtCoreSha256"), "configSha256": meta.get("configSha256"),
        "workloadDimensions": meta.get("workloadDimensions"),
        "culture": meta.get("culture"), "uiCulture": meta.get("uiCulture"),
        "panelScales": trial["panelScales"],
    }


def aggregate(manifest_path):
    manifest = read_json(manifest_path)
    analysis_sha256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    groups = {}
    for run in manifest["runs"]:
        key = f'{run["side"]}/{run["metric"]}'
        group = groups.setdefault(key, {"trials": [], "errors": []})
        if run["exitCode"]:
            group["errors"].append(f'{run["path"]}: worker exited with {run["exitCode"]}')
        if run.get("displayChanged"):
            group["errors"].append(f'{run["path"]}: the display topology changed during the trial')
        try:
            group["trials"].append(summarize_trial(Path(run["path"])))
        except (OSError, ValueError, KeyError, ZeroDivisionError) as error:
            group["errors"].append(f'{run["path"]}: {error}')
    for group_name, group in groups.items():
        category = group_name.split("/", 1)[1]
        order = [run["side"] for run in manifest["runs"] if run["metric"] == category]
        if manifest["twoBuilds"] and order != ["A" if i % 2 == 0 else "B" for i in range(len(order))]:
            group["errors"].append("Trials did not alternate A, B.")
        trials = group["trials"]
        group["errorCount"] = len(group["errors"]) + sum(t["errorCount"] for t in trials)
        group["work"] = {
            key: sum(t["work"][key] for t in trials)
            for key in trials[0]["work"]
        } if trials else {}
        contracts = [dict(trial_contract(t), analysisSha256=analysis_sha256) for t in trials]
        group["contract"] = contracts[0] if contracts else None
        valid = (
            len(trials) >= 5 and not group["errorCount"]
            and all(c == group["contract"] for c in contracts)
            and all(t["metrics"] for t in trials)
            and all(t["metrics"].keys() == trials[0]["metrics"].keys() for t in trials)
        )
        group["valid"] = valid
        group["metrics"] = {
            name: distribution([t["metrics"][name] for t in trials])
            for name in trials[0]["metrics"]
        } if valid else {}
    return {
        "schemaVersion": 3, "analysisSha256": analysis_sha256,
        "manifest": manifest, "groups": groups,
        "errorCount": sum(g["errorCount"] for g in groups.values()),
        "comparison": compare_groups(groups, groups, "A", "B") if manifest["twoBuilds"] else {},
    }


# Verdict contract. See windows/docs/BENCHMARKS.md. Every current metric is a
# cost, so a higher median is a regression.
VERDICT_SCHEMA = 1
EXIT_CODES = {"measured": 0, "same": 0, "improved": 0, "regressed": 2, "inconclusive": 3, "mismatch": 4}
# Worst first. A run with several comparisons reports the worst overall verdict.
SEVERITY = ["mismatch", "regressed", "inconclusive", "improved", "same", "measured"]
# Metrics that are reported but never decide the overall verdict. Empty: every
# measured metric resolved a stable verdict in the A/A and plant runs.
ADVISORY = frozenset()


def compare_groups(baseline, candidate, baseline_side="A", candidate_side="A", categories=None):
    """Compare medians per metric. A metric is the same while the median delta
    stays within the larger run-to-run range (max - min) of the two sides."""
    comparison = {}
    if categories is None:
        categories = {
            key.split("/", 1)[1]
            for source, side in ((baseline, baseline_side), (candidate, candidate_side))
            for key in source if key.startswith(side + "/")
        }
    for category in sorted(categories):
        a = baseline.get(baseline_side + "/" + category)
        b = candidate.get(candidate_side + "/" + category)
        mismatch = []
        if not a or not b:
            reason = "No %s trials for %s." % ("baseline" if not a else "candidate", category)
        elif not a["valid"] or not b["valid"]:
            reason = "The %s trials failed, were incomplete, or numbered fewer than five." % (
                "baseline" if not a["valid"] else "candidate")
        elif a["contract"] != b["contract"]:
            mismatch = sorted(k for k in set(a["contract"]) | set(b["contract"])
                              if a["contract"].get(k) != b["contract"].get(k))
            reason = "Contract mismatch: " + ", ".join(mismatch) + "."
        else:
            reason = None
        names = {
            name for group in (a, b) if group
            for name in list(group["metrics"]) + [n for t in group.get("trials", []) for n in t["metrics"]]
        }
        for name in sorted(names or {category}):
            entry = {"group": category, "gating": name not in ADVISORY}
            before = a["metrics"].get(name) if a else None
            after = b["metrics"].get(name) if b else None
            if reason or not before or not after:
                entry.update(verdict="inconclusive", contractMismatch=mismatch,
                             reason=reason or "Metric missing from the %s." % ("baseline" if not before else "candidate"))
            else:
                delta = after["median"] - before["median"]
                noise = max(before["spread"], after["spread"])
                entry.update(
                    verdict="same" if abs(delta) <= noise else "regressed" if delta > 0 else "improved",
                    baselineMedian=before["median"], candidateMedian=after["median"], delta=delta,
                    deltaPercent=100 * delta / before["median"] if before["median"] else None,
                    noiseFloor=noise, baseline=before, candidate=after,
                )
            comparison[name] = entry
    return comparison


def overall_verdict(comparison):
    gating = [entry for entry in comparison.values() if entry["gating"]]
    if not gating:
        return "inconclusive"
    if any(entry.get("contractMismatch") for entry in gating):
        return "mismatch"
    for verdict in ("regressed", "inconclusive", "improved"):
        if any(entry["verdict"] == verdict for entry in gating):
            return verdict
    return "same"


def build_verdict(result, baseline_name=None):
    """The agent-facing result: no paths, no logs, one overall verdict and exit code."""
    comparisons = []
    if result["manifest"]["twoBuilds"]:
        comparisons.append(("A", "B", result["comparison"]))
    if "baselineComparison" in result:
        comparisons.append(("baseline:" + baseline_name, "A", result["baselineComparison"]))
    documents = [
        {"baseline": base, "candidate": cand, "overall": overall_verdict(comparison), "metrics": comparison}
        for base, cand, comparison in comparisons
    ]
    groups = result["groups"]
    if documents:
        overall = min((d["overall"] for d in documents), key=SEVERITY.index)
    else:
        overall = "measured" if groups and all(g["valid"] for g in groups.values()) else "inconclusive"
    return {
        "schemaVersion": VERDICT_SCHEMA, "overall": overall, "exitCode": EXIT_CODES[overall],
        "analysisSha256": result["analysisSha256"],
        "displays": result["manifest"].get("displays"),
        "powerRequest": result["manifest"].get("powerRequest"),
        "displayChangedTrials": sum(1 for run in result["manifest"]["runs"] if run.get("displayChanged")),
        "groups": {
            key: {"valid": g["valid"], "trials": len(g["trials"]), "errorCount": g["errorCount"],
                  **provenance(g)}
            for key, g in groups.items()
        },
        "comparisons": documents,
    }


def provenance(group):
    meta = group["trials"][0]["metadata"] if group["trials"] else {}
    return {
        "shellRevision": meta.get("shellRevision"), "backendPin": meta.get("backendPin"),
        "buildSourceRevision": (meta.get("build") or {}).get("sourceRevision"),
        "payloadSha256": meta.get("payloadSha256"), "plant": meta.get("plant"),
    }


def baseline_projection(result, side):
    """One side of a run as a shareable baseline: contracts, distributions and
    per-trial values only. Comparisons read a baseline as side A."""
    groups = {}
    for key, group in result["groups"].items():
        group_side, category = key.split("/", 1)
        if group_side == side:
            groups["A/" + category] = {
                "valid": group["valid"], "errorCount": group["errorCount"], "contract": group["contract"],
                "metrics": group["metrics"], "work": group["work"],
                "trials": [{"metrics": t["metrics"]} for t in group["trials"]],
                **provenance(group),
            }
    return {"schemaVersion": 3, "side": side, "analysisSha256": result["analysisSha256"], "groups": groups}


def summarize(path):
    metadata = json.loads((path / "metadata.json").read_text(encoding="utf-8-sig"))
    completion = json.loads((path / "completion.json").read_text(encoding="utf-8-sig"))
    with (path / "samples.csv").open(encoding="utf-8-sig", newline="") as stream:
        rows = [
            {k: v if k in ("utc", "phase") else float(v) for k, v in row.items()}
            for row in csv.DictReader(stream)
        ]
    duration, idle = metadata["durationSeconds"], metadata["idleSeconds"]
    initial = [r for r in rows if 30 <= r["elapsedSeconds"] < idle]
    final = [r for r in rows if r["elapsedSeconds"] >= duration - idle + 30]
    # Ignore the first complete UI traversal for an additional warmed slope.
    warm = [r for r in rows if r["elapsedSeconds"] >= idle + 240]
    actions = [json.loads(line) for line in (path / "actions.jsonl").read_text(encoding="utf-8-sig").splitlines()]
    if not completion["completed"] or len(rows) < duration // 15 + 1:
        raise ValueError(f"Incomplete measurement: {path}")
    if len(warm) < 2 or not initial or not final:
        raise ValueError("Use the standard 20-minute profile for this summary")
    resources = {}
    for label, (key, divisor) in RESOURCES.items():
        start = statistics.median(r[key] / divisor for r in initial)
        end = statistics.median(r[key] / divisor for r in final)
        resources[label] = {
            "initialIdleMedian": round(start, 4),
            "finalIdleMedian": round(end, 4),
            "change": round(end - start, 4),
            "firstSample": round(rows[0][key] / divisor, 4),
            "lastSample": round(rows[-1][key] / divisor, 4),
            "peak": round(max(r[key] / divisor for r in rows), 4),
            "slopePerMinute": round(slope(rows, key, divisor), 5),
            "warmSlopePerMinute": round(slope(warm, key, divisor), 5),
        }
        if key.startswith("cpu"):
            resources[label]["initialIdleMean"] = round(statistics.mean(r[key] for r in initial), 5)
            resources[label]["finalIdleMean"] = round(statistics.mean(r[key] for r in final), 5)
    gaps = [b["elapsedSeconds"] - a["elapsedSeconds"] for a, b in zip(rows, rows[1:])]
    return {
        "sourceRevision": metadata["sourceRevision"],
        "processId": metadata["processId"],
        "durationSeconds": rows[-1]["elapsedSeconds"],
        "samples": len(rows), "actions": len(actions),
        "sampleGapSeconds": {"min": min(gaps), "max": max(gaps)},
        "summaryWindows": {
            "initialIdle": f"30 <= t < {idle}",
            "finalIdle": f"t >= {duration - idle + 30}",
            "warmSlope": f"t >= {idle + 240}",
            "slope": "ordinary least squares across every 15-second sample",
        },
        "resources": resources,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--manifest", action="store_true", help="Aggregate alternating trials from one runner manifest")
    parser.add_argument("--compare", type=Path, help="Compare with a stored benchmark JSON")
    parser.add_argument("--verdict", type=Path, help="Write verdict.json and exit with its exit code")
    parser.add_argument("--baselines", type=Path, help="Write baseline-<side>.json projections into this directory")
    args = parser.parse_args()
    verdict = None
    if args.manifest:
        if len(args.runs) != 1:
            parser.error("--manifest requires one manifest")
        result = aggregate(args.runs[0])
        if args.compare:
            # Only categories measured now; a baseline may hold more.
            measured = {key.split("/", 1)[1] for key in result["groups"] if key.startswith("A/")}
            result["baselineComparison"] = compare_groups(
                read_json(args.compare)["groups"], result["groups"], categories=measured)
        if args.baselines:
            for side in sorted({key.split("/", 1)[0] for key in result["groups"]}):
                (args.baselines / f"baseline-{side}.json").write_text(
                    json.dumps(baseline_projection(result, side), indent=2) + "\n", encoding="utf-8")
        if args.verdict:
            verdict = build_verdict(result, args.compare.stem if args.compare else None)
            args.verdict.write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
    else:
        result = {
            path.name: summarize_trial(path) if read_json(path / "metadata.json").get("schemaVersion") == 2 else summarize(path)
            for path in args.runs
        }
    output = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(output, encoding="utf-8")
    else:
        print(output, end="")
    if verdict:
        raise SystemExit(verdict["exitCode"])
