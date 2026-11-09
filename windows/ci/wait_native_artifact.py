"""Wait for this attempt's early native transfer, never for release eligibility."""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nexus_candidate as candidate
from nexus_publish import GitHub, REPO


def wait(github, ctx, timeout=2700, clock=time.monotonic, pause=time.sleep):
    deadline = clock() + timeout
    name = f"nexus-native-{ctx['runId']}-{ctx['runAttempt']}"
    while clock() < deadline:
        rows = github.pages(f"repos/{REPO}/actions/runs/{ctx['runId']}/artifacts", "artifacts")
        candidate.require(clock() < deadline, "native-artifact-timeout")
        matches = [row for row in rows if row["name"] == name]
        candidate.require(len(matches) <= 1, "ambiguous-native-artifact")
        if matches:
            row = matches[0]
            candidate.require(row["expired"] is False
                              and str(row["workflow_run"]["id"]) == ctx["runId"]
                              and row["workflow_run"]["head_sha"] == ctx["sha"], "invalid-native-artifact")
            return name
        jobs = github.pages(
            f"repos/{REPO}/actions/runs/{ctx['runId']}/attempts/{ctx['runAttempt']}/jobs", "jobs")
        builds = [row for row in jobs if row["name"] == "Native build and offscreen regressions"]
        candidate.require(len(builds) <= 1, "ambiguous-native-job")
        candidate.require(not builds or builds[0]["status"] != "completed",
                          "native-job-concluded-without-artifact")
        pause(min(5, max(0, deadline - clock())))
    raise candidate.GateRejection("native-artifact-timeout")


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        deadline = time.monotonic() + 2700
        def request_timeout():
            remaining = deadline - time.monotonic()
            candidate.require(remaining > 0, "native-artifact-timeout")
            return min(120, remaining)
        print(wait(GitHub(timeout=request_timeout), candidate.context(os.environ),
                   timeout=max(0, deadline - time.monotonic())))
        return 0
    except PermissionError:
        print("Nexus artifact authorization denied; owner intervention required. No retry.", file=sys.stderr)
        return 1
    except subprocess.TimeoutExpired:
        print("Nexus native wait refused: native-artifact-api-timeout.", file=sys.stderr)
        return 1
    except (ValueError, OSError, KeyError, TypeError) as error:
        print("Nexus native wait refused: " + candidate.failure_reason(error) + ".", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
