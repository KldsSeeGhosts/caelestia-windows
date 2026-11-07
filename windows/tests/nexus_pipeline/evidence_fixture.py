"""Complete synthetic pair evidence through the actual pinned validator."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


def create(root, source):
    sys.path.insert(0, str(source / "windows/ci"))
    import nexus_candidate as c
    import pair_result as p
    root = Path(root)
    shell = root / "shell"
    backend = shell / "windows/deps/quickshell"
    backend.mkdir(parents=True)
    def git(where, *args):
        return subprocess.check_output(["git", "-C", str(where), *args], stderr=subprocess.DEVNULL).decode().strip()
    def commit(where):
        git(where, "add", "--all")
        git(where, "-c", "user.name=Evidence Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "fixture")
        return git(where, "rev-parse", "HEAD")
    for where, repo in ((backend, p.REPOS["backend"]), (shell, p.REPOS["shell"])):
        git(where, "init", "--quiet")
        git(where, "remote", "add", "origin", "https://github.com/" + repo)
    (backend / "source.txt").write_text("fixture")
    backend_sha = commit(backend)
    git(backend, "update-ref", "refs/remotes/origin/main", backend_sha)
    def put(name, value):
        path = shell / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value) + "\n", encoding="utf-8")
    capture = b"synthetic capture Cargo lock\n"
    lock = {"quickshell": {"revision": backend_sha, "repository": "https://github.com/" + p.REPOS["backend"]},
            "m3shapes": {"revision": "d" * 40},
            "glazier": {"representation": "in-tree", "sourceRevision": "shell", "path": "windows/capture",
                        "cargoLockPath": "windows/capture/Cargo.lock", "cargoLockSha256": hashlib.sha256(capture).hexdigest(),
                        "executable": "caelestia-capture.exe", "originRevision": "e" * 40, "revision": "e" * 40}}
    put("windows/sources.lock.json", lock)
    spec = c.read(source / "windows/toolchain.json")
    put("windows/toolchain.json", spec)
    for name in ("python-bootstrap.lock.txt", "python-tools.lock.txt"):
        path = shell / "windows/toolchain" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((source / "windows/toolchain" / name).read_bytes())
    put("windows/ci/pair-contract.json", c.read(source / "windows/ci/pair-contract.json"))
    put("windows/ci/Invoke-PairIntegration.ps1", {})
    put("windows/release/version.json", {"schema": 1, "version": "0.2.0", "developmentEpoch": "1", "profileSchema": 1})
    (shell / "windows/capture").mkdir()
    (shell / "windows/capture/Cargo.lock").write_bytes(capture)
    git(shell, "add", "--all")
    git(shell, "update-index", "--add", "--cacheinfo", "160000," + backend_sha + ",windows/deps/quickshell")
    sha = commit(shell)
    ctx = {"repository": c.REPOSITORY, "event": "push", "ref": "refs/heads/main", "workflow": ".github/workflows/windows-build.yml",
           "sha": sha, "runId": "12", "runAttempt": "2", "runNumber": "8"}
    validator = root / "candidate_contract.py"
    validator.write_bytes((source / "windows/tests/nexus_pipeline/pinned_candidate_contract.py").read_bytes())
    assert c.digest(validator) == c.VALIDATOR
    module = p.validator(validator, c.read(shell / "windows/ci/pair-contract.json"))
    spec_hash, contract_hash = p.digests(shell)
    request = {"mode": "pinned", "status": "resolved", "shell": sha, "backend": backend_sha,
               "gitlinkBackend": backend_sha, "lockBackend": backend_sha, "onBackendMain": True,
               "specSha256": spec_hash, "contractSha256": contract_hash}
    results = root / "results"; results.mkdir()
    p.write(results / "pair-request.json", request)
    receipt = module.new_receipt("downstream", backend_sha, sha)
    for row in receipt["sources"].values():
        row.update(resolved=row["requested"], dirty=False)
    for stage in module.stages("downstream"):
        module.start(receipt, stage)
        module.finish(receipt, stage, 0, 0.01)
    expected = {"contractId": spec["id"], **{name: spec[name] for name in module.TOOLS}}
    actual = {**expected, "contractSha256": contract_hash, "schemaVersion": 1}
    receipt["toolchain"] = {"specSha256": spec_hash, "contractSha256": contract_hash, "expected": expected, "actual": actual}
    receipt["producer"] = {"pythonVersion": "3.12.10"}
    receipt["omittedTiers"] = {name: {"count": 1, "reason": "separate-trusted-acceptance"} for name in ("native", "desktop", "gpu", "machine")}
    for name, count in (("portable", 2), ("integration", 7)):
        (results / (name + ".xml")).write_text("<testsuite>" + '<testcase name="fixture"/>' * count + "</testsuite>")
        counts, _ = module.junit(results / (name + ".xml"))
        receipt["tests"][name] = counts
    receipt["tests"]["producer"] = {"total": 1, "executed": 1, "failed": 0, "skipped": 0, "skips": []}
    assert module.finalize(receipt, "success")
    p.write(results / "candidate-result.json", receipt)
    p.write(results / "integration-stages.json", [
        {"name": name, "outcome": "success", "exitCode": 0, "durationSeconds": 0.1} for name in p.GATES])
    (results / "plugins.raw.xml").write_text('<testsuite><testcase name="plugin"/></testsuite>')
    for suite in ("Services", "Shell"):
        (results / suite).mkdir()
        p.write(results / suite / "summary.json", {"schemaVersion": 1, "sourceRevision": sha, "sourceDirty": False,
                "passed": True, "results": [{"name": "fixture", "exitCode": 0}]})
        (results / suite / "fixture.log").write_text('{"assertions":1}')
    build = root / "build"
    (build / "install").mkdir(parents=True)
    (build / "install/caelestia-capture.exe").write_bytes(b"inert native fixture bytes")
    (build / "quickshell").mkdir()
    (build / "quickshell/qs.exe").write_bytes(b"inert quickshell")
    (build / "install/DesktopTakeover.dll").write_bytes(b"inert supervisor")
    (build / "install/qml/Fixture").mkdir(parents=True)
    (build / "install/qml/Fixture/plugin.dll").write_bytes(b"inert plugin")
    native = {"sourceRevision": sha, "sourceDirty": False, "backendRevision": backend_sha, "backendMode": "pinned",
              "pinnedBackendRevision": backend_sha, "lockBackendRevision": backend_sha, "m3shapesRevision": "d" * 40,
              "captureSourceRevision": sha, "captureSourcePath": "windows/capture", "captureOriginRevision": "e" * 40,
              "captureCargoLockSha256": lock["glazier"]["cargoLockSha256"], "captureExecutable": "caelestia-capture.exe",
              "captureSha256": c.digest(build / "install/caelestia-capture.exe"), "captureBundled": True,
              "publicRelease": True, "pluginTests": True, "toolchain": actual, "nativeVersion": "0.2.0",
              "versionFileSha256": c.digest(shell / "windows/release/version.json"),
              "supervisor": {"sourceSha256": "a" * 64, "assemblySha256": "b" * 64, "clrVersion": "4.0.30319.42000"}}
    native["nativeInputs"] = [{"path": name, "sha256": c.digest(build / name)} for name in
                             ("quickshell/qs.exe", "install/caelestia-capture.exe",
                              "install/DesktopTakeover.dll", "install/qml/Fixture/plugin.dll")]
    p.write(build / "logs/build.json", native)
    args = type("Args", (), dict(results=str(results), shell=str(shell), validator=str(validator), build_root=str(build),
                workflow_outcome="success", event="push", ref="refs/heads/main", run_id="12", attempt="2", workflow_sha=sha))()
    result = p.compute_envelope(args)
    assert result["releaseEligible"], result
    p.write(results / "pair-result.json", result)
    return shell, build, results, validator, ctx
