"""Run public A/A and added-cost controls without shell, providers or desktop.

These test acquisition/replay logic and ordinary subprocess timing only.
They cannot qualify native metrics, set app floors or demonstrate app savings.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("shellbench", HERE.parent / "scripts/ShellBench.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
parser = argparse.ArgumentParser(__doc__)
parser.add_argument("--output", required=True)
args = parser.parse_args()
output = bench.external_output(args.output)
output.mkdir(parents=True)
started = time.perf_counter()
record = {"schemaVersion": 1, "evidenceClass": "fixture", "wholeAppQualification": False,
          "protocol": bench.PROTOCOL, "toolSha256": bench.sha(__file__),
          "harnessSha256": bench.sha(HERE.parent / "scripts/ShellBench.py"),
          "probeSha256": bench.sha(HERE / "fixture_probe.py"), "experiments": []}
setup = time.perf_counter()
record["setupSeconds"] = setup - started
for repeat in range(1, 4):
    for kind in ("aa", "added"):
        trials = []
        experiment_started = time.perf_counter()
        for index in range(1, 9):
            for side in bench.pair_order(index, "counterbalanced"):
                cmd = [sys.executable, "-B", str(HERE / "fixture_probe.py"), "--added-percent",
                       "100" if kind == "added" and side == "B" else "0"]
                probe = subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=True)
                raw = json.loads(probe.stdout)
                if raw["operations"] <= 0 or raw["elapsedNs"] <= 0 or raw["checksum"] <= 0:
                    raise ValueError("Fixture did no measurable work.")
                trials.append({"index": index, "side": side, "raw": raw,
                               "values": {"fixture.nsPerOperation": raw["elapsedNs"] / raw["operations"]}})
        data = {"schemaVersion": 1, "evidenceClass": "fixture",
                "sides": {side: {"revision": record["probeSha256"]} for side in ("A", "B")},
                "removed": {"whole-shell": "Arithmetic fixture only; no shell or desktop qualification."},
                "protocol": {"version": bench.PROTOCOL, "runs": 8, "order": "counterbalanced",
                             "requiredMetrics": ["fixture.nsPerOperation"],
                             "floorsPercent": {"fixture.nsPerOperation": 10},
                             "floorStatus": "arbitrary fixture threshold, not app calibration"},
                "trials": trials}
        data["summary"] = bench.summarize(data)
        if data["summary"] != bench.summarize(json.loads(json.dumps(data))):
            raise ValueError("Fixture replay mismatch.")
        data["wallSeconds"] = time.perf_counter() - experiment_started
        filename = f"{kind}-{repeat}.json"
        bench.write(output / filename, data)
        record["experiments"].append({"file": filename, "sha256": bench.sha(output / filename),
                                     "kind": kind, "repeat": repeat,
                                     "expected": "same" if kind == "aa" else "regressed",
                                     "actual": data["summary"]["overall"], "wallSeconds": data["wallSeconds"]})
record["subprocessCount"] = 96
record["wallSeconds"] = time.perf_counter() - started
record["limits"] = "A/A misses and unresolved outcomes retained. Not native, QML, desktop, ETW overhead or whole-app performance evidence."
bench.write(output / "fixture-controls.json", record)
print(json.dumps(record, indent=2))
