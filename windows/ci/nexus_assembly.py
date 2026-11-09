"""Unprivileged early assembly and exact-tested sealing. No signing or writes to GitHub."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import copy
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nexus_candidate as candidate
import nexus_process
import nexus_publish as publish
import pair_result as pair

require, read, digest = candidate.require, candidate.read, candidate.digest
PUBLIC_EVIDENCE = {
    "pair-result.json", "candidate-result.json", "pair-request.json", "integration-stages.json",
    "services-summary.json", "shell-summary.json", "portable.xml", "integration.xml",
    "plugins.xml", "native-build.json",
}
ASSEMBLY_GATES = publish.GATES[1:]
HEADER = {"schema", "version", "repository", "event", "ref", "workflow", "sourceRevision",
          "runId", "runAttempt", "runNumber", "release", "assets", "gates", "qualification"}


def production_record(shell, build, sha):
    record = read(Path(build) / "logs/build.json")
    require(record["sourceRevision"] == sha and record["sourceDirty"] is False,
            "production-source-mismatch")
    require(pair.git(shell, "rev-parse", "HEAD") == sha
            and not pair.git(shell, "status", "--porcelain", "--untracked-files=all",
                             "--ignore-submodules=none"), "production-source-not-exact-clean")
    candidate.check_native_outputs(build, record)
    return record


def resume(shell, build, results):
    journal = pair.safe_journal(results)
    for row in journal:
        if row["name"] in ("production", "release-toolchain"):
            require(row["outcome"] == "success" and row["exitCode"] == 0,
                    "production-not-successful")
        else:
            require(row == {"name": row["name"], "outcome": "not_run", "exitCode": None,
                            "durationSeconds": None}, "resume-already-attempted")
    production_record(shell, build, pair.git(shell, "rev-parse", "HEAD"))


def assembly_identity(shell, build, ctx):
    record = production_record(shell, build, ctx["sha"])
    version_file = Path(shell) / "windows/release/version.json"
    version = read(version_file)
    lock = read(Path(shell) / "windows/sources.lock.json")
    backend = lock["quickshell"]["revision"]
    require(record["backendMode"] == "pinned" and record["backendRevision"] ==
            record["pinnedBackendRevision"] == record["lockBackendRevision"] == backend
            and pair.git(shell, "ls-tree", "HEAD", "--", "windows/deps/quickshell") ==
            "160000 commit " + backend + "\twindows/deps/quickshell", "assembly-backend-pin-mismatch")
    require(record["nativeVersion"] == version["version"]
            and record["versionFileSha256"] == digest(version_file)
            and record["publicRelease"] is True and record["pluginTests"] is True
            and record["captureBundled"] is True, "build-version-provenance-mismatch")
    identity = (version["version"] + "-dev." + str(version["developmentEpoch"]) + "." +
                ctx["runNumber"] + "." + ctx["runAttempt"])
    require(candidate.DEV.fullmatch(identity) and len(identity) <= 80, "invalid-build-identity")
    return identity


def run_gates(plan):
    # Each bounded child owns its log, extraction/output root and state file.
    rows = read(plan)
    require(isinstance(rows, list) and len(rows) == 3
            and {row["name"] for row in rows} ==
            {"coverage", "license-lifecycle", "verify-original-zip"}, "invalid-assembly-gates")
    with ThreadPoolExecutor(max_workers=3) as pool:
        tasks = [pool.submit(nexus_process.run_stage, row["command"], row["log"], row["name"],
                             row["timeout"], echo=row["echo"]) for row in rows]
        codes = [task.result() for task in tasks]
    require(all(code == 0 for code in codes), "assembly-gate-nonpass")


def seal(shell, build, results, validator, directory, ctx):
    directory = Path(directory)
    publish.no_links(directory)
    unsealed = read(directory / "unsealed.json")
    require(set(unsealed) == HEADER | {"nativeInputs", "nativeToolchain", "nativeSupervisor"},
            "unsealed-fields")
    require(unsealed["schema"] == "caelestia-nexus-unsealed" and unsealed["version"] == 1
            and publish.candidate_context(unsealed) == ctx
            and unsealed["repository"] == ctx["repository"]
            and unsealed["event"] == ctx["event"] and unsealed["ref"] == ctx["ref"]
            and unsealed["workflow"] == ctx["workflow"]
            and unsealed["gates"] == ASSEMBLY_GATES
            and unsealed["qualification"] == "component-offscreen-and-data-only-not-windows11-acceptance",
            "unsealed-run-binding")
    identity = candidate.verify_live_evidence(shell, build, results, validator, ctx)
    record = read(Path(build) / "logs/build.json")
    require(unsealed["nativeInputs"] == record["nativeInputs"], "tested-native-bytes-changed")
    require(unsealed["nativeToolchain"] == record["toolchain"], "native-toolchain-version-mismatch")
    require(unsealed["nativeSupervisor"] == record["supervisor"], "native-supervisor-metadata-mismatch")
    release = unsealed["release"]
    require(release["buildVersion"] == identity and release["backendRevision"] == record["backendRevision"]
            and release["sourceRevision"] == ctx["sha"], "unsealed-build-binding")
    require(release["provenance"] == {"runId": ctx["runId"], "runAttempt": ctx["runAttempt"]},
            "unsealed-provenance")
    expected = (publish.EVIDENCE - PUBLIC_EVIDENCE) | {release["bundle"]["name"]}
    require({row["name"] for row in unsealed["assets"]} == expected, "unsealed-asset-set")
    publish.assert_assets(directory, unsealed["assets"], ("unsealed.json",))
    candidate.public_metadata(unsealed)
    candidate.export_evidence(shell, build, results, validator, ctx, directory)
    doc = {key: copy.deepcopy(unsealed[key]) for key in HEADER}
    doc["schema"] = "caelestia-nexus-candidate"
    doc["gates"] = publish.GATES.copy()
    doc["release"]["provenance"].update(
        pairResultSha256=digest(directory / "pair-result.json"),
        candidateReceiptSha256=digest(directory / "candidate-result.json"))
    doc["assets"] = publish.asset_rows(directory, expected | PUBLIC_EVIDENCE)
    candidate.public_metadata(doc)
    publish.write(directory / "candidate.json", doc)
    publish.verify_candidate_header(directory, ctx, ("unsealed.json",))
    # Only this private handoff file is removed. It is never a release asset.
    (directory / "unsealed.json").unlink()
    return identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("identity", "resume", "seal"):
        entry = sub.add_parser(action)
        for name in ("shell", "build"):
            entry.add_argument("--" + name, required=True)
        if action in ("resume", "seal"):
            entry.add_argument("--results", required=True)
        if action == "seal":
            for name in ("validator", "directory"):
                entry.add_argument("--" + name, required=True)
    gates = sub.add_parser("gates")
    gates.add_argument("--plan", required=True)
    args = parser.parse_args()
    try:
        if args.action == "resume":
            resume(args.shell, args.build, args.results)
        elif args.action == "gates":
            run_gates(args.plan)
        elif args.action == "identity":
            print(assembly_identity(args.shell, args.build, candidate.context(os.environ)))
        else:
            print(seal(args.shell, args.build, args.results, args.validator, args.directory,
                       candidate.context(os.environ)))
        return 0
    except (ValueError, OSError, KeyError, TypeError, ImportError) as error:
        print("Nexus assembly refused: " + candidate.failure_reason(error) + ".", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
