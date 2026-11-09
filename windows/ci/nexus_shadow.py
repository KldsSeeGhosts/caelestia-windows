"""Main-only unsigned assembly experiment. Never release eligibility or signing."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nexus_candidate as candidate
import nexus_job
import nexus_process
import nexus_publish as publication
import nexus_sources as sources

require, read, digest = candidate.require, candidate.read, candidate.digest
STAGES = {"assembly": 900, "coverage": 300, "license-lifecycle": 600, "verify-original-zip": 300}
JOURNAL = ("services", "production", "release-toolchain", "plugins", "shell", "smoke")
STATUS = ("ready", "fallback", "failed")
PROOF = "shadow-proof.json"


def atomic(path, document):
    path = Path(path)
    temporary = path.with_suffix(".tmp")
    publication.write(temporary, document)
    nexus_job.replace_shared(temporary, path)


def shared_read(path):
    # Both the canonical journal writer and the shadow state writer replace
    # their destination. Ordinary Python Windows opens deny delete sharing.
    with nexus_job.open_shared(path) as stream:
        contents = stream.read(16 * 1024 * 1024 + 1)
    require(len(contents) <= 16 * 1024 * 1024, "json-byte-cap")
    return json.loads(contents.decode("utf-8-sig"), object_pairs_hook=candidate.object_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid-json-number")))


def state(work, ctx, status, reason):
    require(status in (*STATUS, "waiting", "running"), "invalid-shadow-status")
    atomic(Path(work) / "state.json", {
        "schema": "caelestia-nexus-shadow-state", "version": 1,
        "run": ctx, "status": status, "reason": reason})


def identity(shell, ctx):
    version = read(Path(shell) / "windows/release/version.json")
    value = f"{version['version']}-dev.{version['developmentEpoch']}.{ctx['runNumber']}.{ctx['runAttempt']}"
    require(candidate.DEV.fullmatch(value) and len(value) <= 80, "invalid-build-identity")
    return value


def journal(results):
    path = Path(results) / "integration-stages.json"
    if not path.exists():
        return None
    try:
        rows = shared_read(path)
    except FileNotFoundError:
        # Move-Item can briefly remove the destination before the rename.
        return None
    require(isinstance(rows, list) and tuple(row["name"] for row in rows) == JOURNAL,
            "shadow-integration-inventory")
    require(all(row["outcome"] in ("not_run", "running", "success", "failure") for row in rows),
            "shadow-integration-state")
    for row in rows:
        if row["outcome"] == "success":
            require(type(row["exitCode"]) is int and row["exitCode"] == 0,
                    "shadow-integration-nonpass")
    return rows


def production_ready(rows):
    if rows is None:
        return False
    require(not any(row["outcome"] == "failure" for row in rows), "shadow-integration-nonpass")
    return all(rows[JOURNAL.index(name)]["outcome"] == "success"
               for name in ("production", "release-toolchain"))


def config(work, ctx):
    value = read(Path(work) / "private/config.json")
    require(value["run"] == ctx and re.fullmatch(
        rf"Local\\CaelestiaShadow-{ctx['runId']}-{ctx['runAttempt']}-[a-f0-9]{{32}}", value["job"]),
        "shadow-control-mismatch")
    require(type(value["jobDeadline"]) is int and value["jobDeadline"] > 0, "shadow-job-budget")
    return value


def start(shell, build, tools, results, transfer, work, available, ctx):
    shell, build, tools, results, transfer, work = (
        Path(path).resolve() for path in (shell, build, tools, results, transfer, work))
    for root in (shell, build, tools, results, transfer, work):
        publication.no_links(root)
    require(not work.exists(), "fresh-shadow-work-required")
    require(all(not work.is_relative_to(root) and not root.is_relative_to(work)
                for root in (shell, build, tools, results, transfer)), "shadow-work-overlap")
    work.mkdir()
    if not available:
        # Only this pre-work decision permits canonical fallback. An invalid
        # downloaded source object is a failure, never a cache miss.
        state(work, ctx, "fallback", "sources-not-ready")
        return
    private = work / "private"
    private.mkdir()
    process = None
    try:
        job_deadline = int(os.environ["SHADOW_JOB_DEADLINE"])
        remaining = job_deadline - time.time()
        require(remaining > 0, "shadow-job-budget")
        code = nexus_process.run_stage(
            [sys.executable, "-I", "-B", Path(__file__), "materialize", "--shell", shell,
             "--transfer", transfer, "--work", work],
            private / "materialize.log", "sources", min(1800, remaining))
        require(code == 0, "shadow-source-nonpass")
        value = {"run": ctx, "job": f"Local\\CaelestiaShadow-{ctx['runId']}-{ctx['runAttempt']}-{uuid.uuid4().hex}",
                 "shell": str(shell), "build": str(build), "tools": str(tools),
                 "results": str(results), "jobDeadline": job_deadline}
        atomic(private / "config.json", value)
        state(work, ctx, "waiting", "production-not-ready")
        # Keep RUNNER_TRACKING_ID so the hosted runner also owns cancellation.
        # No token or signing key is needed by the long-lived supervisor.
        environment = {key: value for key, value in os.environ.items() if key.upper() not in
                       ("NEXUS_SIGNING_KEY", "GH_TOKEN", "GITHUB_TOKEN", "ACTIONS_RUNTIME_TOKEN")}
        with (private / "supervisor.log").open("xb") as log:
            process = subprocess.Popen(
                [sys.executable, "-I", "-B", str(Path(__file__).resolve()),
                 "supervise", "--work", str(work)],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                env=environment, creationflags=subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP)
        deadline = time.monotonic() + 10
        while not (private / "owned.json").exists():
            require(process.poll() is None and time.monotonic() < deadline, "shadow-supervisor-start")
            time.sleep(0.05)
    except BaseException:
        if (private / "config.json").exists():
            nexus_job.terminate(config(work, ctx)["job"])
        if process is not None and process.poll() is None:
            nexus_process.stop_tree(process)
        state(work, ctx, "failed", "shadow-start-failed")
        raise


def supervise(work, ctx):
    work = Path(work)
    value = config(work, ctx)
    # Intentionally keep this handle until OS process exit. Explicitly closing
    # the last handle would kill this process as well as its descendants.
    job = nexus_job.OwnedJob(value["job"])
    atomic(work / "private/owned.json", {"owned": True})
    try:
        deadline = time.monotonic() + max(0, min(3600, value["jobDeadline"] - time.time()))
        while not production_ready(journal(value["results"])):
            require(time.monotonic() < deadline, "shadow-production-timeout")
            time.sleep(0.5)
        record = read(Path(value["build"]) / "logs/build.json")
        require(record["sourceRevision"] == ctx["sha"] and record["sourceDirty"] is False,
                "shadow-native-source")
        candidate.check_native_outputs(value["build"], record)
        atomic(work / "private/native-snapshot.json", {
            "buildSha256": digest(Path(value["build"]) / "logs/build.json"),
            "nativeInputs": record["nativeInputs"]})
        state(work, ctx, "running", "assembly-started")
        code = nexus_process.run_stage(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
             Path(value["shell"]) / "windows/ci/Invoke-NexusShadowAssembly.ps1",
             "-ShellRoot", value["shell"], "-BuildRoot", value["build"],
             "-ToolRoot", value["tools"], "-OutputDirectory", work,
             "-ReleaseId", identity(value["shell"], ctx), "-Python", sys.executable],
            work / "private/packaging.log", "shadow-packaging", 2400)
        require(code == 0, "shadow-packaging-nonpass")
        state(work, ctx, "ready", "packaging-completed")
    except BaseException:
        state(work, ctx, "failed", "shadow-worker-failed")
        raise
    # Do not close job here. The OS closes its non-inherited handle on exit,
    # including on abrupt termination, and kills any remaining descendants.
    return job


def check_stage(row, name, budget):
    require(set(row) == {"stage", "outcome", "exitCode", "seconds", "timeoutSeconds"}
            and row["stage"] == name and row["outcome"] == "success"
            and type(row["exitCode"]) is int and row["exitCode"] == 0
            and type(row["seconds"]) in (int, float) and 0 <= row["seconds"] <= budget + 30
            and row["timeoutSeconds"] == budget, "shadow-gate-nonpass")


def export(work, value, ctx):
    work = Path(work)
    rows = journal(value["results"])
    require(rows is not None and all(row["outcome"] == "success" for row in rows),
            "shadow-integration-nonpass")
    # Tests may have finished after the assembler's own final source check.
    require(candidate.pair.git(value["shell"], "rev-parse", "HEAD") == ctx["sha"]
            and not candidate.pair.git(value["shell"], "status", "--porcelain",
                                       "--untracked-files=all", "--ignore-submodules=none"),
            "shadow-source-dirty")
    record = read(Path(value["build"]) / "logs/build.json")
    snapshot = read(work / "private/native-snapshot.json")
    require(snapshot["buildSha256"] == digest(Path(value["build"]) / "logs/build.json")
            and snapshot["nativeInputs"] == record["nativeInputs"], "shadow-native-changed")
    candidate.check_native_outputs(value["build"], record)
    gates = [read(work / "private" / (name + ".state.json")) for name in STAGES]
    for row, (name, budget) in zip(gates, STAGES.items()):
        check_stage(row, name, budget)
    root = "caelestia-windows-" + identity(value["shell"], ctx) + "-windows-x64"
    out = work / "out"
    require(not out.exists(), "fresh-shadow-export-required")
    out.mkdir()
    for source, name in ((work / "assembly" / (root + ".zip"), root + ".zip"),
                         (work / "assembly" / root / "release.json", "release.json"),
                         (work / "coverage/component-inventory.json", "component-inventory.json")):
        publication.no_links(source)
        shutil.copyfile(source, out / name)
    document = {"schema": "caelestia-nexus-shadow-proof", "version": 1, "run": ctx,
                "qualification": "shadow-only-not-release-evidence",
                **snapshot, "sourceInventorySha256": digest(work / "sources/component-inventory.json"),
                "gates": gates,
                "files": [{"path": path.name, "size": path.stat().st_size, "sha256": digest(path)}
                          for path in sorted(out.iterdir())]}
    candidate.public_metadata(document)
    publication.write(out / PROOF, document)


def echo_failure(work):
    # Hosted main inputs only, as in the canonical candidate's --echo mode.
    # Never retain raw logs or echo an artifact-selected path. A single bounded
    # tail diagnoses a failed gate without changing its outcome or evidence.
    try:
        private = Path(work) / "private"
        log = private / "supervisor.log"
        for name in ("materialize", *STAGES):
            stage = private / (name + ".state.json")
            if stage.exists() and read(stage)["outcome"] != "success":
                log = private / (name + ".log")
                break
        publication.no_links(log)
        nexus_process.echo_failure_tail(log)
    except (ValueError, OSError, KeyError, TypeError):
        print("NEXUS_SHADOW_DIAGNOSTIC_UNAVAILABLE", file=sys.stderr)


def join(work, ctx, integration_success, timeout=600):
    work = Path(work)
    result, reason = "failed", "shadow-join-failed"
    try:
        document = shared_read(work / "state.json")
        require(document["run"] == ctx, "shadow-state-run-mismatch")
        if document["status"] == "fallback":
            result, reason = "fallback", "sources-not-ready"
        else:
            value = config(work, ctx)
            try:
                require(integration_success, "shadow-integration-nonpass")
                deadline = time.monotonic() + max(0, min(timeout, value["jobDeadline"] - time.time()))
                while document["status"] in ("waiting", "running"):
                    require(time.monotonic() < deadline, "shadow-join-timeout")
                    time.sleep(0.5)
                    document = shared_read(work / "state.json")
                    require(document["run"] == ctx, "shadow-state-run-mismatch")
                require(document["status"] == "ready", "shadow-worker-nonpass")
                export(work, value, ctx)
                result, reason = "ready", "shadow-proof-created"
            finally:
                # This name comes only from local startup, never an artifact PID.
                nexus_job.terminate(value["job"])
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        reason = candidate.failure_reason(error)
    if result == "failed":
        echo_failure(work)
    state(work, ctx, result, reason)
    atomic(work / "join-result.json", {
        "schema": "caelestia-nexus-shadow-join", "version": 1,
        "run": ctx, "prepared": result, "reason": reason})
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write("prepared=" + result + "\n")
    print("NEXUS_SHADOW_JOIN " + result + " reason=" + reason)
    return 0 if result in ("ready", "fallback") else 1


def verify(transfer, shell, build, sources_root, ctx):
    transfer = Path(transfer)
    publication.no_links(transfer)
    document = read(sources.member(transfer, PROOF))
    require(set(document) == {"schema", "version", "run", "qualification", "buildSha256",
                              "nativeInputs", "sourceInventorySha256", "gates", "files"}
            and document["schema"] == "caelestia-nexus-shadow-proof" and document["version"] == 1
            and document["run"] == ctx and document["qualification"] == "shadow-only-not-release-evidence",
            "shadow-proof-context")
    require(document["buildSha256"] == digest(Path(build) / "logs/build.json")
            and document["nativeInputs"] == read(Path(build) / "logs/build.json")["nativeInputs"],
            "shadow-native-mismatch")
    candidate.check_native_outputs(build, {"nativeInputs": document["nativeInputs"]})
    require(document["sourceInventorySha256"] == digest(Path(sources_root) / "component-inventory.json"),
            "shadow-sources-mismatch")
    require(len(document["gates"]) == len(STAGES), "shadow-gate-inventory")
    for row, (name, budget) in zip(document["gates"], STAGES.items()):
        check_stage(row, name, budget)
    expected = {"release.json", "component-inventory.json",
                "caelestia-windows-" + identity(shell, ctx) + "-windows-x64.zip"}
    require({path.name for path in transfer.iterdir()} == expected | {PROOF}
            and len(document["files"]) == len(expected)
            and {row["path"] for row in document["files"]} == expected, "shadow-file-inventory")
    for row in document["files"]:
        require(set(row) == {"path", "size", "sha256"}, "shadow-file-record")
        path = sources.member(transfer, row["path"])
        require(type(row["size"]) is int and path.is_file()
                and path.stat().st_size == row["size"] and digest(path) == row["sha256"],
                "shadow-bytes-mismatch")
    return document


def compare(status, transfer, shell, build, canonical, report, ctx):
    """Diagnostic only. Never changes the canonical candidate or release assets."""
    result, reason, equal = "failed", "shadow-comparison-failed", None
    try:
        require(status in STATUS, "invalid-shadow-status")
        if status == "fallback":
            result, reason = "fallback", "sources-not-ready"
        else:
            require(status == "ready", "shadow-worker-nonpass")
            canonical = Path(canonical)
            document = verify(transfer, shell, build, canonical / "sources", ctx)
            name = "caelestia-windows-" + identity(shell, ctx) + "-windows-x64"
            pairs = {"zip": (Path(transfer) / (name + ".zip"), canonical / "out" / (name + ".zip")),
                     "manifest": (Path(transfer) / "release.json", canonical / "assembly" / name / "release.json"),
                     "coverage": (Path(transfer) / "component-inventory.json",
                                  canonical / "out/component-inventory.json")}
            equal = {name: digest(first) == digest(second) for name, (first, second) in pairs.items()}
            result = "equal" if all(equal.values()) else "mismatch"
            reason = "canonical-byte-comparison"
    except (ValueError, OSError, KeyError, TypeError) as error:
        reason = candidate.failure_reason(error)
    document = {"schema": "caelestia-nexus-shadow-comparison", "version": 1,
                "run": ctx, "prepared": status, "result": result, "reason": reason, "equal": equal,
                "releaseAcceptance": "canonical-only"}
    candidate.public_metadata(document)
    atomic(report, document)
    print("NEXUS_SHADOW_COMPARISON " + result + " reason=" + reason)
    return 0 if result in ("equal", "fallback") else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "supervise", "join", "materialize", "compare"))
    for name in ("shell", "build", "tools", "results", "transfer", "work", "canonical", "report"):
        parser.add_argument("--" + name, type=Path)
    parser.add_argument("--source-ready", choices=("true", "false"), default="false")
    parser.add_argument("--status", choices=STATUS)
    parser.add_argument("--integration-result", choices=("success", "failure", "cancelled", "skipped"))
    args = parser.parse_args()
    try:
        ctx = candidate.context(os.environ)
        if args.action == "start":
            start(args.shell, args.build, args.tools, args.results, args.transfer, args.work,
                  args.source_ready == "true", ctx)
        elif args.action == "supervise":
            supervise(args.work, ctx)
        elif args.action == "join":
            return join(args.work, ctx, args.integration_result == "success")
        elif args.action == "materialize":
            sources.materialize(args.shell, args.transfer, args.work / "sources", ctx)
        else:
            return compare(args.status, args.transfer, args.shell, args.build,
                           args.canonical, args.report, ctx)
        return 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("NEXUS_SHADOW_REFUSED " + candidate.failure_reason(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
