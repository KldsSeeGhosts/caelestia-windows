"""Exact-event idle controls, separate from method.py's short CPU workload.

Uses its production staging, isolated environment and immutable-input receipts.
Only a synthetic status executable can run. Never starts the shell entry.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess as SP
import tempfile

import method

HERE, ROOT = method.HERE, method.ROOT


def qualify(session):
    """Fixed 60-second count controls. No timing or whole-shell verdict."""
    a, aa, added, b = (session[n] for n in ("a", "aa", "added", "b"))
    if not all(60 <= row["minutes"] * 60 <= 61 for row in (a, aa, added, b)):
        raise ValueError("Count controls require complete 60-second windows.")
    if a["processStarts"] != 4 or aa["processStarts"] != a["processStarts"]:
        raise ValueError("Recorder baseline/A/A failed.")
    if abs(a["clockWakeups"] - 60) > 1 or abs(aa["clockWakeups"] - a["clockWakeups"]) > 1:
        raise ValueError("Clock baseline/A/A failed.")
    if added["processStarts"] - a["processStarts"] != 4 or abs(added["plantedWakeups"] - 60) > 1:
        raise ValueError("Independent added-count control failed.")
    if abs(added["clockWakeups"] - a["clockWakeups"]) > 1:
        raise ValueError("Clock drift during added-count control.")
    if b["processStarts"] != 0 or b["clockWakeups"] > 2:
        raise ValueError("Candidate missed the idle targets.")
    return {"recorderStartsSaved": a["processStarts"] - b["processStarts"],
            "clockWakeupsSaved": a["clockWakeups"] - b["clockWakeups"]}


def run(args, name, revision=None, plant=False):
    stage = args.output / name
    method.command(["powershell.exe", "-NoProfile", "-File", HERE / "Stage-Bench.ps1",
                    "-Destination", stage], timeout=45)
    shell = stage / "imports/qs"
    if revision:
        for service in ("Recorder", "Time"):
            text = method.command(["git", "-C", ROOT, "show",
                                   f"{revision}:windows/shell/adapters/services/{service}.qml"])
            (shell / f"services/{service}.qml").write_text(text, encoding="utf-8")
    # Never instantiate the real host controller, even if a test regresses.
    (shell / "services/Glazier.qml").write_text(
        'pragma Singleton\nimport QtQuick\nQtObject {\n'
        'property bool launchedHost: false\n'
        'function hostOptions() { return []; }\n'
        'function sendHostCommand(args, executable) { return false; }\n'
        '}\n', encoding="utf-8")
    profile = stage / "profile"
    header = "\n".join(f"//@ pragma {n}Dir {profile / n.lower()}"
                       for n in ("Data", "State", "Cache"))
    entry = shell / "IdleWork.qml"
    entry.write_text(header + "\n" + (HERE / "IdleWork.qml").read_text(), encoding="utf-8")
    env = method.environment(args.qt, args.build, stage, "idle", 0)
    env.update(CAELESTIA_COMBINED_LIVE="1", CAELESTIA_CAPTURE_EXE=str(args.stub),
               CAELESTIA_IDLE_LOG=str(stage / "starts.txt"),
               CAELESTIA_IDLE_SECONDS=str(args.seconds),
               CAELESTIA_IDLE_TEST="1" if args.test else "0",
               CAELESTIA_IDLE_PLANT="1" if plant else "0")
    payload_hash = method.digest(method.tree(shell))
    with (stage / "stdout.log").open("w") as out, (stage / "stderr.log").open("w") as err:
        child = SP.Popen([str(args.build / "quickshell/qs.exe"), "--no-color", "--path", str(entry)],
                         env=env, stdout=out, stderr=err, creationflags=method.NO_WINDOW)
        try:
            code = child.wait(timeout=args.seconds + 25)
        except SP.TimeoutExpired:
            child.kill()
            child.wait()
            raise RuntimeError(f"{name}: owned host timed out")
    log = (stage / "stdout.log").read_text() + (stage / "stderr.log").read_text()
    match = re.search(r"CAELESTIA_IDLE_RESULT (\{[^\r\n]+\})", log)
    if code or not match or re.search(
            r"CAELESTIA_IDLE_FAIL|ReferenceError|TypeError|SyntaxError|binding loop|is not a type", log):
        raise RuntimeError(f"{name}: invalid trial, inspect {stage}")
    result = json.loads(match[1])
    starts = [int(line) for line in (stage / "starts.txt").read_text().splitlines()]
    result.update(processStarts=sum(result["begin"] <= t < result["end"] for t in starts),
                  totalStarts=len(starts), stageSha256=payload_hash,
                  sourceRevision=revision or method.command(["git", "rev-parse", "HEAD"]))
    result["minutes"] = (result["end"] - result["begin"]) / 60000
    if args.test:
        if (result["processStarts"] != 0 or result["clockWakeups"] > args.seconds // 60 + 1
                or result["assertions"] < 14):
            raise RuntimeError(f"Idle regression: {result}")
    method.write(stage / "counts.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--qt", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--baseline")
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--sessions", type=int, default=3)
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()
    if not 16 <= args.seconds <= 120 or not 1 <= args.sessions <= 3:
        parser.error("Use 16..120 seconds and 1..3 sessions.")
    args.output = args.output or Path(tempfile.mkdtemp(prefix="caelestia-idle-"))
    args.output = args.output.resolve()
    temp = Path(tempfile.gettempdir()).resolve()
    if temp not in args.output.parents:
        parser.error("Output must be under Temp.")
    args.output.mkdir(exist_ok=True)
    if any(args.output.iterdir()):
        parser.error("Output must be empty; never overwrite an acquisition.")
    args.stub = args.output / "status-stub.exe"
    method.command([Path(os.environ["WINDIR"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe",
                    "/nologo", "/target:exe", f"/out:{args.stub}", HERE / "StatusStub.cs"])
    receipt = {"identity": method.identity(ROOT, args.build, args.qt),
               "helperSha256": method.sha(args.stub), "sessions": []}
    if args.test:
        receipt["test"] = run(args, "regression")
    else:
        if not args.baseline or not re.fullmatch("[0-9a-f]{40}", args.baseline):
            parser.error("Comparison requires a full --baseline SHA.")
        for session in range(args.sessions):
            # Four independent processes, unchanged staged inputs throughout.
            jobs = [("a", args.baseline, False), ("aa", args.baseline, False),
                    ("added", args.baseline, True), ("b", None, False)]
            if session % 2:
                jobs.reverse()
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = {name: pool.submit(run, args, f"{session}-{name}", rev, plant)
                           for name, rev, plant in jobs}
                result = {name: f.result() for name, f in futures.items()}
                receipt["sessions"].append(result)
                method.write(args.output / "raw.json", receipt)
                result["qualification"] = qualify(result)
            method.write(args.output / "raw.json", receipt)
    method.write(args.output / "raw.json", receipt)
    print(json.dumps({"receipt": str(args.output / "raw.json"),
                      "test": receipt.get("test"), "sessions": receipt["sessions"]}, indent=2))


if __name__ == "__main__":
    main()
