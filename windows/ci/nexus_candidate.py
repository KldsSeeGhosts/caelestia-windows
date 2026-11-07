"""Independent same-run evidence gate. No compilation, signing or network."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pair_result as pair

REPOSITORY = "KldsSeeGhosts/caelestia-windows"
PRODUCER = "ae98287c8cd96db4ea4642cc91a1cd9ba7c32a1f"
VALIDATOR = "220ab389252a15b8f4d9db25076aa01a927b3b07c62f3a07a76d1431d560f275"
SHA = re.compile(r"[a-f0-9]{40}")
DIGEST = re.compile(r"[a-f0-9]{64}")
DEV = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-dev\.([1-9][0-9]*)\.([1-9][0-9]*)\.([1-9][0-9]*)")


class GateRejection(ValueError):
    """A fixed, non-secret reason from a reviewed evidence/publisher gate."""


def failure_reason(error):
    # Never echo arbitrary exception values, child output, API bodies, keys,
    # filesystem paths or process arguments from the signing environment.
    if isinstance(error, GateRejection) and re.fullmatch(r"[a-z][a-z0-9-]{0,95}", str(error)):
        return str(error)
    return type(error).__name__


def require(value, message):
    if not value:
        raise GateRejection(message)


def object_pairs(rows):
    result, seen = {}, set()
    for key, value in rows:
        require(key.casefold() not in seen, "ambiguous-json")
        seen.add(key.casefold())
        result[key] = value
    return result


def read(path):
    path = Path(path)
    require(path.stat().st_size <= 16 * 1024 * 1024, "json-byte-cap")
    return json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=object_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid-json-number")))


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def context(env):
    require(env.get("GITHUB_ACTIONS") == "true", "actions-context-required")
    require(env.get("GITHUB_REPOSITORY") == REPOSITORY
            and env.get("GITHUB_EVENT_NAME") == "push"
            and env.get("GITHUB_REF") == "refs/heads/main", "trusted-main-push-required")
    require(env.get("GITHUB_WORKFLOW_REF") ==
            REPOSITORY + "/.github/workflows/windows-build.yml@refs/heads/main",
            "producer-workflow-mismatch")
    sha = env.get("GITHUB_SHA", "")
    require(SHA.fullmatch(sha) and env.get("GITHUB_WORKFLOW_SHA") == sha,
            "workflow-source-sha-mismatch")
    result = {"repository": REPOSITORY, "event": "push", "ref": "refs/heads/main",
              "workflow": ".github/workflows/windows-build.yml", "sha": sha}
    for key, name in (("runId", "GITHUB_RUN_ID"), ("runAttempt", "GITHUB_RUN_ATTEMPT"),
                      ("runNumber", "GITHUB_RUN_NUMBER")):
        value = env.get(name, "")
        require(isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*", value),
                "invalid-run-identity")
        result[key] = value
    return result


def check_pair_header(result, ctx):
    require(result["schemaVersion"] == 1 and result["result"] == "pass"
            and result["releaseEligible"] is True and result["pairMode"] == "pinned"
            and result["reasons"] == [], "release-ineligible")
    require(result["run"] == {"id": ctx["runId"], "attempt": ctx["runAttempt"],
                              "workflowSha": ctx["sha"]}, "pair-run-mismatch")
    require(result["pair"]["shell"] == ctx["sha"]
            and result["pair"]["backend"] == result["pair"]["gitlinkBackend"]
            == result["pair"]["lockBackend"] and result["pair"]["onBackendMain"] is True,
            "pair-main-pin-mismatch")
    require(result["producerContract"] == {"producerRevision": PRODUCER,
                                          "validatorSha256": VALIDATOR}, "producer-pin-mismatch")


def check_sources(shell, ctx, request):
    shell = Path(shell)
    pair.source(shell, "shell", ctx["sha"])
    backend = shell / "windows/deps/quickshell"
    pair.source(backend, "backend", request["backend"])
    lock = read(shell / "windows/sources.lock.json")
    require(pair.git(shell, "ls-tree", "HEAD", "--", "windows/deps/quickshell") ==
            "160000 commit " + request["backend"] + "\twindows/deps/quickshell",
            "gitlink-mismatch")
    require(lock["quickshell"]["revision"] == request["backend"]
            and request["backend"] == request["gitlinkBackend"] == request["lockBackend"],
            "backend-pin-mismatch")
    pair.git(backend, "merge-base", "--is-ancestor", request["backend"], "refs/remotes/origin/main")


def verify_receipt(shell, evidence, validator, ctx):
    request = read(Path(evidence) / "pair-request.json")
    check_sources(shell, ctx, request)
    return verify_receipt_data(shell, evidence, validator, ctx)


def verify_receipt_data(shell, evidence, validator, ctx):
    """Data verifier after live-source or immutable historical Git validation."""
    evidence, shell = Path(evidence), Path(shell)
    result = read(evidence / "pair-result.json")
    check_pair_header(result, ctx)
    request = read(evidence / "pair-request.json")
    require(request["mode"] == "pinned" and request["status"] == "resolved"
            and request["shell"] == ctx["sha"] and request["onBackendMain"] is True,
            "request-mismatch")
    contract = read(shell / "windows/ci/pair-contract.json")
    require(contract["producerRevision"] == PRODUCER and contract["validatorSha256"] == VALIDATOR
            and contract["producerRepository"] == pair.REPOS["backend"]
            and contract["validatorPath"] == ".github/scripts/candidate_contract.py",
            "producer-pin-mismatch")
    module = pair.validator(validator, contract)  # Hash checked BEFORE import.
    receipt = read(evidence / "candidate-result.json")
    pair.verify(receipt, request, shell, module)
    check_tool_versions(shell, receipt, module)
    require(result["candidateReceipt"]["sha256"] == digest(evidence / "candidate-result.json"),
            "receipt-hash-mismatch")
    require(result["toolchain"] == receipt["toolchain"]["actual"], "toolchain-mismatch")
    # Recount sanitized producer reports independently of the edited boolean.
    for name in ("portable", "integration"):
        counts, _ = module.junit(evidence / (name + ".xml"))
        for field in ("total", "executed", "failed", "skipped"):
            require(counts[field] == receipt["tests"][name][field], "report-count-mismatch")
        require(counts["executed"] > 0 and counts["failed"] == 0, "empty-or-failed-report")
    for suite in ("Services", "Shell"):
        summary = read(evidence / (suite.lower() + "-summary.json"))
        require(summary["sourceRevision"] == ctx["sha"] and summary["sourceDirty"] is False
                and summary["passed"] is True and summary["results"]
                and all(type(row["exitCode"]) is int and row["exitCode"] == 0
                        for row in summary["results"]), "suite-nonpass")
        require(len(summary["results"]) == result["suiteCounts"][suite.lower()]["executedCommands"],
                "suite-inventory-mismatch")
    counts, _ = module.junit(evidence / "plugins.xml")
    require(counts["executed"] > 0 and counts["failed"] == 0, "plugin-nonpass")
    require(all(row["outcome"] == "success" and row["exitCode"] == 0
                for row in pair.safe_journal(evidence)), "stage-nonpass")
    return request, receipt


def check_tool_versions(shell, receipt, module):
    spec = read(Path(shell) / "windows/toolchain.json")
    expected = {"contractId": spec["id"], **{name: spec[name] for name in module.TOOLS}}
    require(receipt["toolchain"]["expected"] == expected
            and all(receipt["toolchain"]["actual"][name] == value for name, value in expected.items()),
            "declared-toolchain-version-mismatch")

def check_native_outputs(build, record):
    build = Path(build)
    rows = record.get("nativeInputs")
    require(isinstance(rows, list) and len(rows) >= 3, "missing-native-inventory")
    expected = {"quickshell/qs.exe", "install/caelestia-capture.exe", "install/DesktopTakeover.dll"}
    expected.update(path.relative_to(build).as_posix() for path in (build / "install/qml").rglob("*") if path.is_file())
    seen = set()
    for row in rows:
        require(set(row) == {"path", "sha256"} and row["path"] in expected
                and row["path"].casefold() not in seen and DIGEST.fullmatch(row["sha256"]),
                "invalid-native-inventory")
        seen.add(row["path"].casefold())
        path = build / row["path"]
        require(path.is_file() and digest(path) == row["sha256"], "tested-native-bytes-changed")
    require(seen == {name.casefold() for name in expected}, "incomplete-native-inventory")


def verify_live_evidence(shell, build, results, validator, ctx):
    results = Path(results)
    # Recompute through the existing canonical validator, without replacing any
    # original receipt. A forged pass flag cannot substitute for these inputs.
    stored = read(results / "pair-result.json")
    check_pair_header(stored, ctx)
    check_sources(shell, ctx, read(results / "pair-request.json"))
    computed = pair.compute_envelope(argparse.Namespace(
        results=str(results), shell=str(shell), validator=str(validator), build_root=str(build),
        workflow_outcome="success", event=ctx["event"], ref=ctx["ref"],
        run_id=ctx["runId"], attempt=ctx["runAttempt"], workflow_sha=ctx["sha"]))
    require(stored == computed, "independent-envelope-mismatch")
    for suite in ("Services", "Shell"):
        summary = read(results / suite / "summary.json")
        require(summary["sourceRevision"] == ctx["sha"] and summary["sourceDirty"] is False,
                "tested-suite-source-mismatch")
    contract = read(Path(shell) / "windows/ci/pair-contract.json")
    module = pair.validator(validator, contract)
    receipt = read(results / "candidate-result.json")
    check_tool_versions(shell, receipt, module)
    build_record = read(Path(build) / "logs/build.json")
    check_native_outputs(build, build_record)
    require(all(build_record["toolchain"][key] == value for key, value in receipt["toolchain"]["actual"].items()),
            "native-toolchain-version-mismatch")
    version_file = Path(shell) / "windows/release/version.json"
    version = read(version_file)
    require(build_record["sourceRevision"] == ctx["sha"] and build_record["sourceDirty"] is False
            and build_record["nativeVersion"] == version["version"]
            and build_record["versionFileSha256"] == digest(version_file),
            "build-version-provenance-mismatch")
    identity = (version["version"] + "-dev." + str(version["developmentEpoch"]) + "." +
                ctx["runNumber"] + "." + ctx["runAttempt"])
    require(DEV.fullmatch(identity) and len(identity) <= 80, "invalid-build-identity")
    return identity


def public_metadata(value):
    """Reject private machine paths in extra retained JSON, never redact it."""
    if isinstance(value, str):
        require(len(value) <= 2048 and not re.search(
            r"(?<![A-Za-z])[A-Za-z]:[\\/]|\\\\|/(?:Users|home)/", value),
            "private-candidate-metadata")
    elif isinstance(value, dict):
        for key, item in value.items():
            public_metadata(key)
            public_metadata(item)
    elif isinstance(value, list):
        for item in value:
            public_metadata(item)


def export_evidence(shell, build, results, validator, ctx, output):
    output, results = Path(output), Path(results)
    # This function is called only after verify_live_evidence. Do not retain
    # environment.json, raw build.json, fixture output, paths or raw JUnit.
    require(output.is_dir(), "missing-candidate-output")
    contract = read(Path(shell) / "windows/ci/pair-contract.json")
    module = pair.validator(validator, contract)
    for name in ("pair-result.json", "candidate-result.json", "pair-request.json",
                 "integration-stages.json"):
        public_metadata(read(results / name))
        shutil.copyfile(results / name, output / name)
    for suite in ("Services", "Shell"):
        public_metadata(read(results / suite / "summary.json"))
        shutil.copyfile(results / suite / "summary.json", output / (suite.lower() + "-summary.json"))
    for source, destination in (("portable.xml", "portable.xml"),
                                ("integration.xml", "integration.xml"),
                                ("plugins.raw.xml", "plugins.xml")):
        _, clean = module.junit(results / source)
        (output / destination).write_text(clean, encoding="utf-8")
    native = read(Path(build) / "logs/build.json")
    fields = ("sourceRevision", "sourceDirty", "backendRevision", "backendMode",
              "pinnedBackendRevision", "lockBackendRevision", "m3shapesRevision",
              "captureSourcePath", "captureSourceRevision", "captureOriginRevision",
              "captureCargoLockSha256", "captureExecutable", "captureSha256",
              "captureBundled", "publicRelease", "pluginTests", "nativeVersion",
              "versionFileSha256", "supervisor", "nativeInputs")
    proof = {key: native[key] for key in fields}
    proof["toolchain"] = read(results / "candidate-result.json")["toolchain"]["actual"]
    public_metadata(proof)
    (output / "native-build.json").write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    verify_receipt(shell, output, validator, ctx)


def main():
    parser = argparse.ArgumentParser()
    for name in ("shell", "build", "results", "validator"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--export-evidence")
    args = parser.parse_args()
    try:
        identity = verify_live_evidence(args.shell, args.build, args.results, args.validator, context(os.environ))
        if args.export_evidence:
            export_evidence(args.shell, args.build, args.results, args.validator, context(os.environ), args.export_evidence)
        print(identity)
        return 0
    except (ValueError, OSError, KeyError, TypeError, ImportError) as error:
        print("Nexus exact-tested evidence rejected: " + failure_reason(error) + ".", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
