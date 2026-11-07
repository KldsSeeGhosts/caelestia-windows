"""Exact-pair consumer. No authentication, release actions or raw public logs."""

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

REPOS = {"shell": "KldsSeeGhosts/caelestia-windows",
         "backend": "KldsSeeGhosts/caelestia-quickshell-windows"}
SHA = re.compile(r"[a-f0-9]{40}")
DIGEST = re.compile(r"[a-f0-9]{64}")
GATES = ("services", "production", "release-toolchain", "plugins", "shell", "smoke")
COMMANDS = {
    "sources": "trusted candidate_contract.py sources --backend <backend> --shell <shell>",
    "producer": "python -B -m unittest discover -s <trusted>/.github/candidate-contract -p test_*.py",
    "prepare": "powershell Prepare-Toolchain.ps1 -ToolRoot <tools> -InstallRust",
    "configure": "powershell <trusted>/Invoke-WindowsFixtureGate.ps1 -Phase configure -ContractRoot <shell> -ToolRoot <tools> -BuildRoot <fixtures> -Results <results> -Jobs <jobs>",
    "build": "powershell <trusted>/Invoke-WindowsFixtureGate.ps1 -Phase build -ContractRoot <shell> -ToolRoot <tools> -BuildRoot <fixtures> -Results <results> -Jobs <jobs>",
    "portable": "powershell <trusted>/Invoke-WindowsFixtureGate.ps1 -Phase portable -ContractRoot <shell> -ToolRoot <tools> -BuildRoot <fixtures> -Results <results> -Jobs <jobs>",
    "integration": "powershell Invoke-PairIntegration.ps1 -ShellRoot <shell> -BackendRoot <backend> -Mode <mode> -BackendSha <backend-sha> -ToolRoot <tools> -Jobs <jobs> -BuildRoot <build> -Results <results> -JUnit <results>/integration.raw.xml",
    "services": "powershell Test-Validation.ps1 -Suite Services -BuildRoot <build> -QtPrefix <qt> -OutputRoot <results>/Services",
    "production": "powershell Build-Prototype.ps1 -BuildRoot <build> -QtPrefix <qt> -LlvmBin <llvm> -Cli11Include <cli11> -ToolsBin <tools> -Jobs <jobs> -PublicRelease -PluginTests [explicit candidate parameters]",
    "release-toolchain": "powershell New-CaelestiaRelease.ps1 -BuildRoot <build> -ValidateToolchainOnly",
    "plugins": "ctest --test-dir <build>/caelestia --output-on-failure --timeout 60 --no-tests=error --output-junit <results>/plugins.raw.xml",
    "shell": "powershell Test-Validation.ps1 -Suite Shell -BuildRoot <build> -QtPrefix <qt> -OutputRoot <results>/Shell",
    "smoke": "powershell Test-Smoke.ps1 -BuildRoot <build> -QtPrefix <qt> -RunRoot <results>/smoke [explicit candidate SHA]",
}


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    require(result.returncode == 0, "git-operation-failed")
    return result.stdout.decode("utf-8").strip()


def source(root, key, expected):
    root = Path(root).resolve()
    require(Path(git(root, "rev-parse", "--show-toplevel")).resolve() == root,
            "source-root-mismatch")
    require(git(root, "remote", "get-url", "origin").removesuffix(".git")
            == "https://github.com/" + REPOS[key], "noncanonical-repository")
    require(git(root, "rev-parse", "HEAD") == expected, "resolved-sha-mismatch")
    require(not git(root, "status", "--porcelain", "--untracked-files=all",
                    "--ignore-submodules=none"), "dirty-source")


def digests(shell):
    texts = [(Path(shell) / name).read_text(encoding="utf-8-sig") for name in (
        "windows/toolchain.json", "windows/toolchain/python-bootstrap.lock.txt",
        "windows/toolchain/python-tools.lock.txt")]
    return (hashlib.sha256(texts[0].encode()).hexdigest(),
            hashlib.sha256("\n".join(texts).encode()).hexdigest())


def resolve(args):
    results, shell = Path(args.results).resolve(), Path(args.shell).resolve()
    require(not results.is_relative_to(shell), "results-inside-source")
    require(not results.exists() or results.is_dir() and not any(results.iterdir()),
            "fresh-results-required")
    request_path = results / "pair-request.json"
    require(not request_path.exists(), "fresh-results-required")
    request = {"schemaVersion": 1, "mode": args.mode, "status": "incomplete",
               "reason": None, "shell": None, "backend": None,
               "gitlinkBackend": None, "lockBackend": None, "onBackendMain": None,
               "specSha256": None, "contractSha256": None}
    write(request_path, request)
    try:
        require(SHA.fullmatch(args.shell_sha or ""), "immutable-shell-sha-required")
        request["shell"] = args.shell_sha
        require(args.mode in ("pinned", "candidate"), "invalid-mode")
        require(not args.backend_sha if args.mode == "pinned" else
                SHA.fullmatch(args.backend_sha or ""),
                "candidate-sha-required" if args.mode == "candidate"
                else "candidate-sha-requires-candidate-mode")
        for name in ("windows/toolchain.json", "windows/ci/pair-contract.json",
                     "windows/ci/Invoke-PairIntegration.ps1"):
            require((shell / name).is_file(), "incompatible-shell-revision")
        source(shell, "shell", args.shell_sha)
        lock = read(shell / "windows/sources.lock.json")["quickshell"]
        entry = git(shell, "ls-tree", "HEAD", "--", "windows/deps/quickshell")
        match = re.fullmatch(r"160000 commit ([a-f0-9]{40})\twindows/deps/quickshell", entry)
        require(match, "backend-gitlink-missing")
        require(lock["repository"].removesuffix(".git") ==
                "https://github.com/" + REPOS["backend"], "noncanonical-lock-repository")
        request["gitlinkBackend"], request["lockBackend"] = match[1], lock["revision"]
        require(match[1] == lock["revision"], "gitlink-lock-mismatch")
        backend_sha = args.backend_sha if args.mode == "candidate" else match[1]
        request["backend"] = backend_sha
        require(SHA.fullmatch(backend_sha or ""), "immutable-backend-sha-required")
        if args.mode == "candidate":
            backend = Path(args.candidate_root).resolve()
            require(not backend.is_relative_to(shell) and not shell.is_relative_to(backend),
                    "candidate-root-must-be-separate")
            require(not backend.exists(), "fresh-candidate-root-required")
            backend.mkdir(parents=True)
            git(backend, "init", "--quiet")
            git(backend, "remote", "add", "origin", "https://github.com/" + REPOS["backend"])
            try:
                git(backend, "fetch", "--no-tags", "--depth=1", "origin", backend_sha)
            except ValueError:
                raise ValueError("backend-commit-not-found") from None
            git(backend, "checkout", "--quiet", "--detach", "FETCH_HEAD")
        else:
            backend = shell / "windows/deps/quickshell"
        source(backend, "backend", backend_sha)
        # Full main ancestry is necessary, not a shallow negative inference.
        if git(backend, "rev-parse", "--is-shallow-repository") == "true":
            git(backend, "fetch", "--unshallow", "--no-tags", "origin")
        git(backend, "fetch", "--no-tags", "origin",
            "+refs/heads/main:refs/remotes/origin/main")
        ancestry = subprocess.run(["git", "-C", str(backend), "merge-base",
                                  "--is-ancestor", backend_sha, "refs/remotes/origin/main"],
                                 capture_output=True).returncode
        require(ancestry in (0, 1), "backend-main-ancestry-unverified")
        request["onBackendMain"] = ancestry == 0
        require(args.mode != "pinned" or ancestry == 0, "pinned-backend-not-on-main")
        request["specSha256"], request["contractSha256"] = digests(shell)
        request["status"] = "resolved"
        write(results / "pair-local.json", {"shellRoot": str(shell), "backendRoot": str(backend)})
        if args.github_output:
            with Path(args.github_output).open("a", encoding="utf-8") as output:
                for key, value in (("mode", args.mode), ("shell_sha", args.shell_sha),
                                   ("backend_sha", backend_sha), ("backend_root", str(backend))):
                    output.write(f"{key}={value}\n")
    except (ValueError, OSError, KeyError, TypeError) as error:
        request["status"] = "refused"
        # Only our fixed refusal vocabulary is public.
        request["reason"] = (str(error) if isinstance(error, ValueError)
                             and re.fullmatch(r"[a-z-]+", str(error)) else "invalid-source-input")
        raise
    finally:
        write(request_path, request)


def bootstrap(shell, backend, target):
    contract = read(Path(shell) / "windows/ci/pair-contract.json")
    require(contract["schemaVersion"] == 1 and contract["contractSchemaVersion"] == 1,
            "unsupported-producer-contract")
    require(contract["producerRepository"] == REPOS["backend"], "producer-repository-mismatch")
    require(SHA.fullmatch(contract["producerRevision"]), "invalid-producer-revision")
    require(contract["validatorPath"] == ".github/scripts/candidate_contract.py"
            and DIGEST.fullmatch(contract["validatorSha256"]), "invalid-validator-pin")
    git(backend, "fetch", "--no-tags", "origin", contract["producerRevision"])
    target = Path(target)
    for root in (Path(shell).resolve(), Path(backend).resolve()):
        require(not target.resolve().is_relative_to(root), "trusted-directory-inside-source")
    require(not target.exists(), "fresh-trusted-directory-required")
    for name in (contract["validatorPath"], ".github/scripts/Invoke-WindowsFixtureGate.ps1",
                 ".github/candidate-contract/test_candidate_contract.py",
                 ".github/candidate-contract/v1.schema.json"):
        result = subprocess.run(["git", "-C", str(backend), "show",
                                 contract["producerRevision"] + ":" + name], capture_output=True)
        require(result.returncode == 0, "trusted-producer-blob-missing")
        if name == contract["validatorPath"]:
            require(hashlib.sha256(result.stdout).hexdigest() == contract["validatorSha256"],
                    "trusted-validator-digest-mismatch")
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(result.stdout)
    return contract


def validator(path, contract):
    path = Path(path)
    require(hashlib.sha256(path.read_bytes()).hexdigest() == contract["validatorSha256"],
            "trusted-validator-digest-mismatch")
    spec = importlib.util.spec_from_file_location("trusted_pair_validator", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify(receipt, request, shell, module):
    spec, combined = digests(shell)
    module.validate(receipt, kind="downstream", backend_sha=request["backend"],
                    shell_sha=request["shell"], contract_sha256=combined, spec_sha256=spec)
    require(receipt["kind"] == "downstream", "expected-downstream-kind")
    for key in REPOS:
        item = receipt["sources"][key]
        require(item["requested"] == item["resolved"] == request[key], "expected-pair-mismatch")
    require(spec == request["specSha256"] == receipt["toolchain"]["specSha256"]
            and combined == request["contractSha256"] == receipt["toolchain"]["contractSha256"],
            "expected-toolchain-digest-mismatch")
    require(receipt["tests"]["integration"]["executed"] > 0, "zero-integration-tests")


def integration_report(results, junit):
    """Combine actual gate execution and CTest cases, not fabricated assertions."""
    results = Path(results)
    journal = safe_journal(results)
    root = ET.Element("testsuite")
    for item in journal:
        case = ET.SubElement(root, "testcase", name=item["name"])
        if item["outcome"] == "not_run":
            ET.SubElement(case, "skipped", message="not-run-after-failure-or-cancellation")
        elif item["outcome"] != "success" or item["exitCode"] != 0:
            ET.SubElement(case, "failure", message="integration-stage-failed")
    plugins = results / "plugins.raw.xml"
    if plugins.exists():
        parsed = ET.parse(plugins).getroot()
        cases = list(parsed.iter("testcase"))
        require(cases, "zero-plugin-tests")
        root.extend(cases)
    else:
        require(journal[3]["outcome"] != "success", "plugin-report-missing")
    ET.ElementTree(root).write(junit, encoding="utf-8", xml_declaration=True)


def safe_journal(results):
    journal = read(Path(results) / "integration-stages.json")
    require(isinstance(journal, list) and [item["name"] for item in journal] == list(GATES),
            "integration-stage-set-mismatch")
    for row in journal:
        require(set(row) == {"name", "outcome", "exitCode", "durationSeconds"}
                and row["outcome"] in ("not_run", "running", "success", "failure"),
                "invalid-integration-stage")
        require(row["exitCode"] is None or type(row["exitCode"]) is int, "invalid-stage-exit")
        duration = row["durationSeconds"]
        require(duration is None or type(duration) in (int, float)
                and math.isfinite(duration) and duration >= 0, "invalid-stage-duration")
        if row["outcome"] in ("success", "failure"):
            require(row["exitCode"] is not None and duration is not None, "stage-details-missing")
    return journal


def suite_counts(results):
    counts = {}
    for suite in ("Services", "Shell"):
        if not (Path(results) / suite / "summary.json").exists():
            counts[suite.lower()] = {"reportedPassed": False, "executedCommands": 0,
                                    "reason": "not-run-or-summary-missing"}
            continue
        summary = read(Path(results) / suite / "summary.json")
        rows = summary["results"]
        require(type(summary["passed"]) is bool and isinstance(rows, list),
                "invalid-suite-summary")
        assertions, uncounted = 0, 0
        for row in rows:
            require(re.fullmatch(r"[A-Za-z0-9_-]+", row["name"]), "invalid-suite-step-name")
            log = (Path(results) / suite / (row["name"] + ".log")).read_text(encoding="utf-8-sig")
            values = re.findall(r'"assertions"\s*:\s*(\d+)', log)
            if values:
                value = int(values[-1])
                require(0 <= value <= 1000000, "invalid-fixture-assertion-count")
                assertions += value
            else:
                uncounted += 1
        require(all(type(row["exitCode"]) is int for row in rows), "invalid-suite-exit")
        counts[suite.lower()] = {"executedCommands": len(rows), "reportedAssertions": assertions,
                                "reportedPassed": summary["passed"],
                                "failedCommands": sum(row["exitCode"] != 0 for row in rows),
                                "commandsWithoutAssertionCount": uncounted,
                                "reason": "last-fixture-assertion-marker-per-command; not native acceptance"}
    return counts


def public_counts(counts):
    clean = {}
    for key in ("total", "executed", "failed", "skipped"):
        require(type(counts[key]) is int and counts[key] >= 0, "invalid-test-count")
        clean[key] = counts[key]
    require(clean["total"] == clean["executed"] + clean["skipped"]
            and clean["failed"] <= clean["executed"], "test-count-mismatch")
    clean["skips"] = []
    for skip in counts["skips"]:
        clean["skips"].append({
            "test": skip["test"] if re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", skip["test"]) else "redacted",
            "reason": skip["reason"] if re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", skip["reason"])
            else "reported-skip-details-excluded"})
    return clean


def verify_build(build_root, request, shell):
    build = read(Path(build_root) / "logs/build.json")
    require(build["backendMode"] == request["mode"]
            and build["backendRevision"] == request["backend"]
            and build["sourceRevision"] == request["shell"]
            and build["pinnedBackendRevision"] == request["gitlinkBackend"]
            and build["lockBackendRevision"] == request["lockBackend"],
            "built-pair-mismatch")
    require(build["sourceDirty"] is False and build["publicRelease"] is True
            and build["pluginTests"] is True and build["captureBundled"] is True,
            "incomplete-production-build")
    require(build["toolchain"]["contractSha256"] == request["contractSha256"],
            "production-toolchain-digest-mismatch")
    lock = read(Path(shell) / "windows/sources.lock.json")
    for name in ("m3shapes",):
        require(SHA.fullmatch(build[name + "Revision"])
                and build[name + "Revision"] == lock[name]["revision"], "built-dependency-mismatch")
    capture = lock["glazier"]
    require(capture["representation"] == "in-tree" and capture["sourceRevision"] == "shell"
            and capture["path"] == "windows/capture"
            and capture["cargoLockPath"] == "windows/capture/Cargo.lock"
            and capture["executable"] == "caelestia-capture.exe"
            and capture["originRevision"] == capture["revision"]
            and SHA.fullmatch(capture["originRevision"]),
            "invalid-capture-source-contract")
    require(build["captureSourceRevision"] == request["shell"]
            and build["captureSourcePath"] == capture["path"]
            and build["captureOriginRevision"] == capture["originRevision"]
            and build["captureExecutable"] == capture["executable"]
            and DIGEST.fullmatch(capture["cargoLockSha256"])
            and build["captureCargoLockSha256"] == capture["cargoLockSha256"]
            and hashlib.sha256((Path(shell) / capture["cargoLockPath"]).read_bytes()).hexdigest()
            == capture["cargoLockSha256"],
            "built-capture-source-mismatch")
    require(DIGEST.fullmatch(build["captureSha256"])
            and hashlib.sha256((Path(build_root) / "install" / capture["executable"]).read_bytes()).hexdigest()
            == build["captureSha256"],
            "built-capture-binary-mismatch")
    return {key: build[key] for key in (
        "sourceRevision", "backendRevision", "backendMode",
        "m3shapesRevision", "captureSourceRevision", "captureSourcePath",
        "captureOriginRevision", "captureCargoLockSha256", "captureExecutable", "captureSha256")}


def compute_envelope(args):
    results, shell = Path(args.results), Path(args.shell)
    result = {"schemaVersion": 1, "pairMode": None, "result": "non-pass",
              "releaseEligible": False, "reasons": [], "pair": None,
              "producerContract": None, "candidateReceipt": None,
              "suiteCounts": {}, "stages": [], "producerStages": {}, "builtPair": None,
              "toolchain": None, "tests": {},
              "commands": COMMANDS.copy(),
              "run": {"id": args.run_id if re.fullmatch(r"\d*", args.run_id) else None,
                      "attempt": args.attempt if re.fullmatch(r"\d*", args.attempt) else None,
                      "workflowSha": args.workflow_sha if SHA.fullmatch(args.workflow_sha) else None},
              "evidenceClass": "component-offscreen",
              "limitation": "offscreen staged graph; not Windows 11 graphics or hardware qualification"}
    try:
        request = read(results / "pair-request.json")
        require(request["mode"] in ("candidate", "pinned"), "invalid-mode")
        for key in ("shell", "backend", "gitlinkBackend", "lockBackend"):
            require(request[key] is None or isinstance(request[key], str)
                    and SHA.fullmatch(request[key]), "invalid-request-identity")
        require(request["onBackendMain"] is None or type(request["onBackendMain"]) is bool,
                "invalid-main-ancestry")
        # Explicit allowlist, never publish local roots or exception text.
        result["pairMode"] = request["mode"] if request["mode"] in ("candidate", "pinned") else None
        result["pair"] = {key: request[key] for key in (
            "shell", "backend", "gitlinkBackend", "lockBackend", "onBackendMain")}
        require(request["status"] == "resolved", "pair-request-not-resolved")
        contract = read(shell / "windows/ci/pair-contract.json")
        require(SHA.fullmatch(contract["producerRevision"])
                and DIGEST.fullmatch(contract["validatorSha256"]), "invalid-producer-pin")
        result["producerContract"] = {key: contract[key] for key in (
            "producerRevision", "validatorSha256")}
        module = validator(args.validator, contract)
        receipt_path = results / "candidate-result.json"
        receipt = read(receipt_path)
        actual = receipt["toolchain"]["actual"]
        require(isinstance(actual, dict) and actual, "actual-toolchain-missing")
        require(all(re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", key)
                    and (type(value) is int or isinstance(value, str)
                         and re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", value))
                    for key, value in actual.items()), "unsafe-toolchain-field")
        result["toolchain"] = actual
        result["candidateReceipt"] = {
            "sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
            "result": receipt["result"] if receipt["result"] in
            ("pass", "non-pass", "incomplete", "cancelled") else "non-pass"}
        result["tests"] = {name: public_counts(receipt["tests"][name])
                           for name in ("producer", "portable", "integration")
                           if name in receipt["tests"]}
        # Preserve sanitized actual stages even for a failed run.
        for name in ("sources", "producer", "prepare", "configure", "build", "portable", "integration"):
            row = receipt["stages"][name]
            require(row["outcome"] in ("not_run", "running", "success", "failure"),
                    "invalid-producer-stage")
            require(row["exitCode"] is None or type(row["exitCode"]) is int, "invalid-producer-exit")
            duration = row["durationSeconds"]
            require(duration is None or type(duration) in (int, float)
                    and math.isfinite(duration) and duration >= 0, "invalid-producer-duration")
            result["producerStages"][name] = {key: row[key] for key in
                                              ("outcome", "exitCode", "durationSeconds")}
        result["stages"] = safe_journal(results)
        result["commands"]["production"] = COMMANDS["production"].replace(
            " [explicit candidate parameters]",
            " -BackendRoot <backend> -CandidateBackendRevision " + request["backend"]
            if request["mode"] == "candidate" else "")
        result["commands"]["smoke"] = COMMANDS["smoke"].replace(
            " [explicit candidate SHA]", " -CandidateBackendRevision " + request["backend"]
            if request["mode"] == "candidate" else "")
        result["suiteCounts"] = suite_counts(results)
        plugin_counts = None
        if (results / "plugins.raw.xml").exists():
            plugin_counts, _ = module.junit(results / "plugins.raw.xml")
            result["suiteCounts"]["plugins"] = public_counts(plugin_counts)
        require(args.workflow_outcome == "success", "workflow-nonpass")
        verify(receipt, request, shell, module)
        result["builtPair"] = verify_build(args.build_root, request, shell)
        require(plugin_counts is not None and plugin_counts["executed"] > 0 and plugin_counts["failed"] == 0,
                "plugin-tests-nonpass")
        require(all(result["suiteCounts"][name]["reportedPassed"]
                    and result["suiteCounts"][name]["executedCommands"] > 0
                    and result["suiteCounts"][name]["failedCommands"] == 0
                    for name in ("services", "shell")), "suite-summary-nonpass")
        result["suiteCounts"]["integration"] = public_counts(receipt["tests"]["integration"])
        result["suiteCounts"]["smoke"] = {"executed": 1, "failed": 0, "skipped": 0,
                                         "reason": "production-graph-ready-first-frame-and-clean-exit"}
        require(all(row["outcome"] == "success" and row["exitCode"] == 0
                    for row in result["stages"]), "integration-stages-nonpass")
        result["result"] = "pass"
        if request["mode"] != "pinned":
            result["reasons"].append("candidate-mode")
        if args.event != "push" or args.ref != "refs/heads/main":
            result["reasons"].append("not-main-push")
        if not (request["gitlinkBackend"] == request["lockBackend"] == request["backend"]
                and request["onBackendMain"] is True):
            result["reasons"].append("not-final-main-pin")
        # github.sha on this push must be the tested shell, never a preflight relabel.
        if args.workflow_sha != request["shell"]:
            result["reasons"].append("workflow-shell-sha-mismatch")
        result["releaseEligible"] = not result["reasons"]
    except (ValueError, OSError, KeyError, TypeError, ImportError, ET.ParseError):
        result["reasons"].append("pair-validation-nonpass")
    return result


def envelope(args):
    result = compute_envelope(args)
    write(Path(args.results) / "pair-result.json", result)
    return 0 if result["result"] == "pass" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    request = sub.add_parser("resolve")
    request.add_argument("--mode", choices=("pinned", "candidate"), required=True)
    request.add_argument("--backend-sha", default="")
    request.add_argument("--shell-sha", required=True)
    request.add_argument("--shell", required=True)
    request.add_argument("--candidate-root", required=True)
    request.add_argument("--results", required=True)
    request.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    trust = sub.add_parser("bootstrap")
    for name in ("shell", "backend", "target"):
        trust.add_argument("--" + name, required=True)
    report = sub.add_parser("integration-report")
    report.add_argument("--results", required=True)
    report.add_argument("--junit", required=True)
    end = sub.add_parser("envelope")
    for name in ("results", "shell", "validator", "workflow-outcome", "build-root"):
        end.add_argument("--" + name, required=True)
    for name in ("event", "ref", "run-id", "attempt", "workflow-sha"):
        end.add_argument("--" + name, default="")
    args = parser.parse_args()
    try:
        if args.action == "resolve":
            resolve(args)
        elif args.action == "bootstrap":
            bootstrap(args.shell, args.backend, args.target)
        elif args.action == "integration-report":
            integration_report(args.results, args.junit)
        else:
            return envelope(args)
        return 0
    except (ValueError, OSError, KeyError, TypeError, ET.ParseError) as error:
        category = (str(error) if isinstance(error, ValueError)
                    and re.fullmatch(r"[a-z-]+", str(error)) else "invalid-pair-input-or-report")
        print("Exact pair operation refused: " + category + "; raw output excluded.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
