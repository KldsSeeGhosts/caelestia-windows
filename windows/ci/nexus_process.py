"""Bounded candidate stages. Private logs, periodic progress, owned-tree cleanup."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def stop_tree(process):
    if os.name == "nt":
        # Only the PID returned by this runner's Popen is eligible. Never
        # enumerate or kill by name, and never retry authentication.
        result = subprocess.run(
            [str(Path(os.environ["SystemRoot"]) / "System32/taskkill.exe"),
             "/PID", str(process.pid), "/T", "/F"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15,
            creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode and process.poll() is None:
            process.kill()
    elif process.poll() is None:
        process.kill()
    process.wait(timeout=10)


def echo_failure_tail(log):
    # Read only a bounded suffix, not an arbitrarily large build log.
    with Path(log).open("rb") as source:
        source.seek(max(0, Path(log).stat().st_size - 65536))
        tail = source.read(65536).decode("utf-8-sig", errors="replace").splitlines()[-80:]
    text = "\n".join(tail)
    if len(text) > 16000:
        text = "[earlier output truncated]\n" + text[-15970:]
    print(text, file=sys.stderr, flush=True)


def run_stage(command, log, name, timeout, heartbeat=15, echo=False):
    if (not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", name)
            or not math.isfinite(timeout) or not 0 < timeout <= 3600
            or not math.isfinite(heartbeat) or heartbeat <= 0 or not command):
        raise ValueError("invalid-stage-contract")
    log = Path(log)
    state = log.with_suffix(".state.json")
    started = time.monotonic()
    code, outcome = 1, "launch-failed"
    process = None
    print(f"NEXUS_STAGE_START {name} budget={timeout:g}s", flush=True)
    try:
        # Opening the private log must succeed before any child is launched.
        with log.open("xb") as output:
            environment = dict(os.environ, GIT_TERMINAL_PROMPT="0")
            # The candidate path never signs. Do not pass an accidentally
            # inherited publication key to builds, fetches or diagnostics.
            environment.pop("NEXUS_SIGNING_KEY", None)
            environment.pop("GH_TOKEN", None)
            process = subprocess.Popen(
                list(map(str, command)), stdin=subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT, env=environment,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            while True:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    stop_tree(process)
                    code, outcome = 124, "timeout"
                    break
                try:
                    code = process.wait(timeout=min(heartbeat, remaining))
                    outcome = "success" if code == 0 else "failure"
                    break
                except subprocess.TimeoutExpired:
                    print(f"NEXUS_STAGE_PROGRESS {name} elapsed={time.monotonic() - started:.1f}s "
                          f"logBytes={os.fstat(output.fileno()).st_size}", flush=True)
    finally:
        # Also release children on interruption/logging exceptions, not only
        # the ordinary timeout branch.
        if process is not None and process.poll() is None:
            stop_tree(process)
        elapsed = round(time.monotonic() - started, 3)
        document = {"stage": name, "outcome": outcome, "exitCode": code,
                    "seconds": elapsed, "timeoutSeconds": timeout}
        temporary = state.with_suffix(".tmp")
        temporary.write_text(json.dumps(document) + "\n", encoding="utf-8")
        temporary.replace(state)
        print(f"NEXUS_STAGE_END {name} outcome={outcome} exit={code} seconds={elapsed}", flush=True)
    if code:
        print(f"Private diagnostic log: {log}", file=sys.stderr, flush=True)
        if echo:
            echo_failure_tail(log)
    return code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--heartbeat", type=float, default=15)
    parser.add_argument("--echo", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    try:
        return run_stage(command, args.log, args.name, args.timeout, args.heartbeat, args.echo)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"NEXUS_STAGE_REFUSED {args.name} error={type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
