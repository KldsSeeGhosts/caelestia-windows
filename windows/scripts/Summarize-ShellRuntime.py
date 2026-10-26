"""Summarize Measure-ShellRuntime CSVs without third-party dependencies."""

import argparse
import csv
import json
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
    args = parser.parse_args()
    result = {path.name: summarize(path) for path in args.runs}
    output = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(output, encoding="utf-8")
    else:
        print(output, end="")
