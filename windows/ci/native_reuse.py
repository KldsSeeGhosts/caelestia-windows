"""Trusted main artifact discovery and read-only verification. Never pair evidence."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nexus_candidate import check_native_outputs, digest, read, require

WORKFLOW = ".github/workflows/windows-build.yml"


def select_run(runs, base):
    return next((run for run in runs if
                 run.get("path") == WORKFLOW and run.get("event") == "push"
                 and run.get("head_branch") == "main" and run.get("conclusion") == "success"
                 and run.get("head_sha") == base and run.get("status") == "completed"), None)


def select_artifact(artifacts, base):
    matches = [a for a in artifacts if a.get("name") == f"native-reuse-{base}"
               and a.get("expired") is False]
    require(len(matches) == 1, "reuse-artifact-unavailable")
    return matches[0]


def discover(base, api):
    query = urllib.parse.urlencode(dict(event="push", branch="main", status="success",
                                       head_sha=base, per_page=100))
    runs = api(f"actions/workflows/windows-build.yml/runs?{query}")["workflow_runs"]
    run = select_run(runs, base)
    require(run is not None, "trusted-main-run-unavailable")
    artifact = select_artifact(api(f"actions/runs/{run['id']}/artifacts?per_page=100")["artifacts"], base)
    return run["id"], artifact["name"]


def git(shell, *args):
    return subprocess.check_output(["git", "-C", str(shell), *args]).decode().strip()


def verify(shell, build, inventory, base, head):
    require(re.fullmatch(r"[a-f0-9]{40}", base) is not None, "invalid-base")
    require(git(shell, "merge-base", base, head) == base, "base-not-ancestor")
    for path, reason in (("windows/deps/quickshell", "backend-gitlink-changed"),
                         ("windows/sources.lock.json", "source-lock-changed"),
                         ("windows/toolchain.json", "toolchain-spec-changed")):
        before = git(shell, "ls-tree", base, "--", path)
        require(bool(before) and before == git(shell, "ls-tree", head, "--", path), reason)
    # Run the same fail-closed classifier independently of the scope job.
    command = ["pwsh" if os.name != "nt" else "powershell.exe", "-NoProfile", "-NonInteractive",
               "-File", str(Path(shell) / "windows/ci/Get-NativeBuildRequired.ps1"),
               "-RepoRoot", str(shell), "-Base", base, "-Head", head, "-EventName", "pull_request"]
    env = {key: value for key, value in os.environ.items() if key != "GITHUB_OUTPUT"}
    output = subprocess.check_output(command, env=env, text=True)
    require(output.strip() == "Native validation mode: reuse", "native-diff-refused")
    record = read(Path(build) / "logs/build.json")
    require(record.get("sourceRevision") == base, "build-source-mismatch")
    require(record.get("sourceDirty") is False, "dirty-native-build")
    require(record.get("backendMode") == "pinned", "unpinned-native-build")
    link = git(shell, "rev-parse", f"{base}:windows/deps/quickshell")
    require(record.get("backendRevision") == link
            == read(Path(shell) / "windows/sources.lock.json")["quickshell"]["revision"],
            "backend-lock-mismatch")
    check_native_outputs(build, record)
    rows = read(inventory)
    require(isinstance(rows, list) and len(rows) > len(record["nativeInputs"]), "missing-reuse-inventory")
    seen = set()
    for row in rows:
        name = row.get("path", "")
        require(set(row) == {"path", "sha256"} and "\\" not in name
                and not name.startswith("/") and ":" not in name
                and all(part not in ("", ".", "..") for part in name.split("/"))
                and name.casefold() not in seen, "unsafe-reuse-inventory")
        seen.add(name.casefold())
        require(re.fullmatch(r"[a-f0-9]{64}", row["sha256"]) is not None
                and digest(Path(build) / name) == row["sha256"], "reuse-file-hash-mismatch")
    actual = {p.relative_to(build).as_posix().casefold() for p in Path(build).rglob("*") if p.is_file()}
    require(actual == seen, "incomplete-reuse-inventory")
    require("caelestia/ctesttestfile.cmake" in seen
            and any(name.startswith("caelestia/") and name.endswith(".exe") for name in seen),
            "missing-plugin-tests")
    return rows


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("action", choices=("discover", "verify", "summary"))
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--shell", default=".")
    parser.add_argument("--build")
    parser.add_argument("--inventory")
    parser.add_argument("--output", required=True)
    parser.add_argument("--run-id")
    parser.add_argument("--artifact")
    parser.add_argument("--tests")
    args = parser.parse_args()
    if args.action == "discover":
        def api(path):
            request = urllib.request.Request(
                f"{os.environ['GITHUB_API_URL']}/repos/{os.environ['GITHUB_REPOSITORY']}/{path}",
                headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                         "Accept": "application/vnd.github+json"})
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        run_id, artifact = discover(args.base, api)
        with open(args.output, "a", encoding="utf-8") as output:
            output.write(f"run-id={run_id}\nartifact={artifact}\n")
    elif args.action == "verify":
        rows = verify(args.shell, Path(args.build), args.inventory, args.base, args.head)
        Path(args.output).write_text(json.dumps({"evidenceClass": "native-reuse-tests-only",
            "baseSha": args.base, "headSha": git(args.shell, "rev-parse", args.head),
            "producingRunId": args.run_id,
            "artifact": args.artifact, "verifiedHashes": rows}, indent=2) + "\n")
    else:
        summary = read(args.output)
        summary["tests"] = read(Path(args.tests) / "reuse-tests.json")
        summary["backendFixtures"] = "skipped: unchanged backend pin validated by trusted base main run"
        summary["evidenceClass"] = "native-reuse-tests-only"
        Path(args.output).write_text(json.dumps(summary, indent=2) + "\n")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write("## Verified native reuse (not pair or release evidence)\n\n```json\n"
                         + json.dumps(summary, indent=2) + "\n```\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Native reuse refused: {error}", file=sys.stderr)
        sys.exit(1)
