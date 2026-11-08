"""Owner-gated immutable release/pointer transactions. No builds or login."""
import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
import zipfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nexus_candidate as candidate
import pair_result as pair

REPO = candidate.REPOSITORY
REMOTE = "https://github.com/" + REPO + ".git"
BRANCH = "nexus-channels"
GATES = ["independent-pair", "sources", "assembly", "coverage", "license-lifecycle", "verify-original-zip", "independent-payload"]
REQUIRED_JOBS = {"Fast regressions", "Installer and colour regressions (1/2)",
                 "Installer and colour regressions (2/2)",
                 "Native build and offscreen regressions", "Windows validation"}
EVIDENCE = {"pair-result.json", "candidate-result.json", "pair-request.json", "integration-stages.json",
            "services-summary.json", "shell-summary.json", "portable.xml", "integration.xml",
            "plugins.xml", "native-build.json", "project-source.zip", "supplier-source.zip",
            "component-inventory.json", "source-assets-inventory.json", "manifest.sha256"}
require, read, digest = candidate.require, candidate.read, candidate.digest


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def utc():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def stamp(value):
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def safe_name(name):
    require(isinstance(name, str) and 0 < len(name) <= 255 and name not in (".", "..")
            and not re.search(r'[\\/:*?"<>|\x00-\x1f\x7f]|[. ]$', name)
            and not re.match(r"(?i)^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[0-9¹²³]|LPT[0-9¹²³])(\.|$)", name),
            "unsafe-asset-name")
    return name


def no_links(path):
    path = Path(path).absolute()
    for parent in (path, *path.parents):
        if parent.exists():
            info = parent.lstat()
            require(not stat.S_ISLNK(info.st_mode)
                    and not getattr(info, "st_file_attributes", 0) & 1024, "linked-output")


def checked_run(arguments, *, cwd=None, env=None, input_bytes=None, timeout=120, diagnostic_log=None):
    result = subprocess.run(list(map(str, arguments)), cwd=cwd, env=env, input=input_bytes,
                            capture_output=True, timeout=timeout)
    if result.returncode != 0:
        # Never print argv, environments, stdin or arbitrary child output in
        # the signing process. Keep private diagnostics outside release assets.
        if diagnostic_log is not None:
            Path(diagnostic_log).write_bytes(result.stdout + b"\n--- stderr ---\n" + result.stderr)
            print("Private stage diagnostic log: " + str(diagnostic_log), file=sys.stderr)
        require(False, "external-command-refused-exit-" + str(result.returncode).replace("-", "negative-"))
    return result.stdout


class GitHub:
    """Only env GH_TOKEN; never login, auth setup, credential persistence or clobber."""
    def api(self, path, method="GET", body=None, missing=False):
        args = ["gh", "api", "--hostname", "github.com", path, "--method", method]
        payload = None
        if body is not None:
            args += ["--input", "-"]
            payload = json.dumps(body).encode()
        result = subprocess.run(args, input=payload, capture_output=True, timeout=120)
        if result.returncode:
            error = result.stderr.decode(errors="replace")
            if "HTTP 401" in error or "HTTP 403" in error:
                raise PermissionError("GitHub authorization denied; owner setup required.")
            if missing and "HTTP 404" in error:
                return None
            raise ValueError("github-api-refused")
        return json.loads(result.stdout, object_pairs_hook=candidate.object_pairs)

    def pages(self, path, field):
        rows = []
        for page in range(1, 11):
            result = self.api(path + ("&" if "?" in path else "?") + f"per_page=100&page={page}")
            batch = result[field]
            require(isinstance(batch, list), "invalid-github-page")
            rows.extend(batch)
            if len(batch) < 100:
                return rows
        raise ValueError("github-page-cap")

    def download(self, asset, destination, expected):
        # Authenticated API downloads also work while a release is a draft.
        # Bound stdout incrementally, including stalled bodies; never retain
        # raw gh diagnostics or follow an arbitrary asset URL from metadata.
        require(asset["size"] == expected["size"], "remote-asset-size-mismatch")
        args = ["gh", "api", "--hostname", "github.com", "-H", "Accept: application/octet-stream",
                f"repos/{REPO}/releases/assets/{asset['id']}"]
        no_links(destination)
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        chunks = queue.Queue(maxsize=4)
        stop = threading.Event()
        def reader():
            try:
                while not stop.is_set():
                    block = process.stdout.read(65536)
                    while not stop.is_set():
                        try:
                            chunks.put(block, timeout=0.1)
                            break
                        except queue.Full:
                            continue
                    if not block:
                        return
            except (OSError, ValueError):
                return
        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        sha, total, deadline = hashlib.sha256(), 0, time.monotonic() + 600
        try:
            with Path(destination).open("xb") as output:
                while True:
                    remaining = deadline - time.monotonic()
                    require(remaining > 0, "download-time-budget")
                    try:
                        block = chunks.get(timeout=remaining)
                    except queue.Empty:
                        raise ValueError("download-time-budget") from None
                    if not block:
                        break
                    total += len(block)
                    require(total <= expected["size"] <= 2147483648, "download-byte-cap")
                    sha.update(block)
                    output.write(block)
            require(process.wait(timeout=max(1, deadline - time.monotonic())) == 0
                    and total == expected["size"] and sha.hexdigest() == expected["sha256"],
                    "remote-asset-hash-mismatch")
        finally:
            stop.set()
            if process.poll() is None:
                process.kill()  # This invocation's transport only, never a shell/installer.
            process.wait()
            process.stdout.close()
            thread.join(timeout=1)

    def upload(self, tag, path):
        # No --clobber, delete, replacement, latest or existing-tag mutation.
        checked_run(["gh", "release", "upload", tag, str(path), "--repo", REPO], timeout=600)


def validate_run(github, ctx, artifact=False):
    run = github.api(f"repos/{REPO}/actions/runs/{ctx['runId']}/attempts/{ctx['runAttempt']}")
    require(str(run["id"]) == ctx["runId"] and str(run["run_attempt"]) == ctx["runAttempt"]
            and str(run["run_number"]) == ctx["runNumber"] and run["event"] == "push"
            and run["head_branch"] == "main" and run["head_sha"] == ctx["sha"]
            and run["path"] == ".github/workflows/windows-build.yml"
            and run["repository"]["full_name"] == REPO
            and run["head_repository"]["full_name"] == REPO, "untrusted-run-provenance")
    # This run is still in progress while its publish job executes. Require the
    # exact attempt's independent prerequisite jobs, not a fictitious completed
    # whole-workflow success.
    jobs = github.pages(f"repos/{REPO}/actions/runs/{ctx['runId']}/attempts/{ctx['runAttempt']}/jobs", "jobs")
    for name in REQUIRED_JOBS:
        matching = [row for row in jobs if row["name"] == name]
        require(len(matching) == 1 and matching[0]["conclusion"] == "success"
                and matching[0]["head_sha"] == ctx["sha"], "required-job-nonpass")
    if artifact:
        rows = github.pages(f"repos/{REPO}/actions/runs/{ctx['runId']}/artifacts", "artifacts")
        name = f"nexus-candidate-{ctx['runId']}-{ctx['runAttempt']}"
        matching = [row for row in rows if row["name"] == name]
        require(len(matching) == 1 and matching[0]["expired"] is False
                and str(matching[0]["workflow_run"]["id"]) == ctx["runId"]
                and matching[0]["workflow_run"]["head_sha"] == ctx["sha"]
                and matching[0]["workflow_run"]["repository_id"] == run["repository"]["id"],
                "same-run-artifact-required")


class Crypto:
    def __init__(self, shell, work, trust, secret):
        self.shell, self.work, self.trust, self.secret = Path(shell), Path(work), Path(trust), secret
        self.counter = 0
        self.prefix = uuid.uuid4().hex

    def invoke(self, action, channel, keys, document=None, payload=None):
        self.counter += 1
        directory = self.work / f"crypto-{self.prefix}-{self.counter}"
        directory.mkdir()
        (directory / "keys.dsse.json").write_bytes(keys)
        write(directory / "request.json", {"channel": channel})
        if document is not None:
            (directory / "document.dsse.json").write_bytes(document)
        if payload is not None:
            write(directory / "payload.json", payload)
        environment = dict(os.environ)
        environment.pop("NEXUS_SIGNING_KEY", None)
        if action.startswith("Sign"):
            environment["NEXUS_SIGNING_KEY"] = self.secret
        checked_run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                     self.shell / "windows/ci/Invoke-NexusCrypto.ps1", "-Action", action,
                     "-Directory", directory, "-TrustPath", self.trust], env=environment,
                    diagnostic_log=directory / "crypto.private.log")
        if action.startswith("Read"):
            return read(directory / "result.json")["payload"]
        return (directory / "envelope.dsse.json").read_bytes()


class ChannelBranch:
    def __init__(self, work, remote=REMOTE):
        self.root = Path(work) / "pointers"
        self.root.mkdir()
        checked_run(["git", "init", "--quiet", self.root])
        checked_run(["git", "-C", self.root, "remote", "add", "origin", remote])
        self.remote = remote

    def read(self, channel):
        checked_run(["git", "-C", self.root, "-c", "credential.helper=", "fetch",
                     "--no-tags", "--depth=1", "origin", "refs/heads/" + BRANCH])
        checked_run(["git", "-C", self.root, "checkout", "--quiet", "--detach", "FETCH_HEAD"])
        keys = self.root / "v1/keys.dsse.json"
        path = self.root / ("v1/" + channel + ".dsse.json")
        no_links(keys); no_links(path)
        require(keys.is_file() and keys.stat().st_size <= 65536, "owner-keys-bootstrap-required")
        require(not path.exists() or path.stat().st_size <= 65536, "pointer-byte-cap")
        return keys.read_bytes(), path.read_bytes() if path.is_file() else None

    def push(self, channel, envelope):
        path = self.root / ("v1/" + channel + ".dsse.json")
        no_links(path)
        path.write_bytes(envelope)
        checked_run(["git", "-C", self.root, "add", "--", "v1/" + channel + ".dsse.json"])
        checked_run(["git", "-C", self.root, "-c", "user.name=Caelestia Nexus",
                     "-c", "user.email=nexus@users.noreply.github.com",
                     "commit", "--quiet", "-m", "Refresh " + channel + " authenticated pointer"])
        environment = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        if self.remote == REMOTE:
            import base64
            token = environment.get("GH_TOKEN", "")
            require(bool(token), "missing-github-token")
            # In-memory Git config only. No token URL, auth config or credential
            # helper writes. Never log this environment.
            environment.update(GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="credential.helper",
                               GIT_CONFIG_VALUE_0="", GIT_CONFIG_KEY_1="http.https://github.com/.extraheader",
                               GIT_CONFIG_VALUE_1="AUTHORIZATION: basic " +
                               base64.b64encode(("x-access-token:" + token).encode()).decode())
        result = subprocess.run(["git", "-C", str(self.root), "push", "--porcelain", "origin",
                                 "HEAD:refs/heads/" + BRANCH], env=environment, capture_output=True, timeout=120)
        if result.returncode == 0:
            return True
        error = (result.stdout + result.stderr).decode(errors="replace")
        if "non-fast-forward" in error or "fetch first" in error:
            return False
        # Never retry authentication or unrelated transport denials.
        raise PermissionError("Pointer push refused; owner intervention required.")


def decimal_key(value):
    return len(value), value


def build_key(version):
    match = candidate.DEV.fullmatch(version)
    require(match is not None, "invalid-build-version")
    return tuple(decimal_key(part) for part in match.groups())


def asset_rows(directory, names):
    return [{"name": name, "size": (Path(directory) / name).stat().st_size,
             "sha256": digest(Path(directory) / name)} for name in sorted(names)]


def assert_assets(directory, rows, extras=()):
    directory = Path(directory)
    require(isinstance(rows, list) and 1 <= len(rows) <= 64, "asset-inventory-cap")
    expected = set()
    for row in rows:
        require(set(row) == {"name", "size", "sha256"}, "asset-fields")
        name = safe_name(row["name"])
        require(name.casefold() not in expected and type(row["size"]) is int
                and 1 <= row["size"] <= 2147483648 and candidate.DIGEST.fullmatch(row["sha256"]),
                "invalid-asset")
        expected.add(name.casefold())
        path = directory / name
        no_links(path)
        require(path.is_file() and path.stat().st_size == row["size"] and digest(path) == row["sha256"],
                "candidate-asset-hash-mismatch")
    actual = set()
    for path in directory.iterdir():
        no_links(path)
        require(path.is_file(), "non-file-candidate-artifact")
        require(path.name.casefold() not in actual, "case-duplicate-artifact")
        actual.add(path.name.casefold())
    require(actual == expected | {name.casefold() for name in extras}, "unlisted-candidate-artifact")
    require(sum(row["size"] for row in rows) <= 6 * 1024**3, "asset-total-cap")


def candidate_context(doc):
    return {"repository": REPO, "event": "push", "ref": "refs/heads/main",
            "workflow": ".github/workflows/windows-build.yml", "sha": doc["sourceRevision"],
            **{key: doc[key] for key in ("runId", "runAttempt", "runNumber")}}


def verify_candidate_header(directory, ctx, extras=()):
    directory = Path(directory)
    doc = read(directory / "candidate.json")
    require(set(doc) == {"schema", "version", "repository", "event", "ref", "workflow", "sourceRevision",
                         "runId", "runAttempt", "runNumber", "release", "assets", "gates", "qualification"},
            "candidate-fields")
    require(doc["schema"] == "caelestia-nexus-candidate" and doc["version"] == 1
            and candidate_context(doc) == ctx and doc["repository"] == REPO
            and doc["event"] == "push" and doc["ref"] == "refs/heads/main"
            and doc["workflow"] == ".github/workflows/windows-build.yml"
            and doc["gates"] == GATES
            and doc["qualification"] == "component-offscreen-and-data-only-not-windows11-acceptance",
            "candidate-run-binding")
    release = doc["release"]
    require(candidate.DEV.fullmatch(release["buildVersion"])
            and release["buildVersion"].split(".")[-2:] == [ctx["runNumber"], ctx["runAttempt"]]
            and release["sourceRevision"] == ctx["sha"], "candidate-build-binding")
    expected = EVIDENCE | {release["bundle"]["name"]}
    require({row["name"] for row in doc["assets"]} == expected, "candidate-asset-set")
    assert_assets(directory, doc["assets"], ("candidate.json", *extras))
    require(release["provenance"] == {
        "runId": ctx["runId"], "runAttempt": ctx["runAttempt"],
        "pairResultSha256": digest(directory / "pair-result.json"),
        "candidateReceiptSha256": digest(directory / "candidate-result.json")}, "candidate-receipt-binding")
    candidate.public_metadata(doc)
    return doc


def extract_source(archive, destination):
    """Bounded data-only source ZIP extraction. No git/script execution here."""
    destination = Path(destination)
    no_links(destination)
    require(not destination.exists(), "fresh-source-extraction-required")
    with zipfile.ZipFile(archive) as source:
        entries, seen, files, total = source.infolist(), set(), set(), 0
        require(0 < len(entries) <= 50000, "source-entry-cap")
        for entry in entries:
            require(entry.orig_filename == entry.filename and "\\" not in entry.orig_filename,
                    "noncanonical-source-entry")
            name = entry.filename[:-1] if entry.is_dir() else entry.filename
            for part in name.split("/"):
                safe_name(part)
            require(name.casefold() not in seen, "duplicate-source-entry")
            seen.add(name.casefold())
            if not entry.is_dir():
                files.add(name.casefold())
            mode = (entry.external_attr >> 16) & 0o170000
            require(mode in (0, 0o100000, 0o040000) and not entry.external_attr & 1088,
                    "source-link-device")
            total += entry.file_size
            require(0 <= entry.file_size <= 4 * 1024**3 and total <= 4 * 1024**3, "source-unpacked-cap")
        for name in seen:
            parts = name.split("/")
            require(not any("/".join(parts[:i]) in files for i in range(1, len(parts))), "source-file-directory-collision")
        require(shutil.disk_usage(destination.parent).free >= total + 16 * 1024**2, "source-free-space")
        destination.mkdir()
        for entry in entries:
            path = destination.joinpath(*entry.filename.rstrip("/").split("/"))
            no_links(path)
            if entry.is_dir():
                path.mkdir(parents=True, exist_ok=True)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            with source.open(entry) as input_stream, path.open("xb") as output:
                count = 0
                while block := input_stream.read(65536):
                    count += len(block)
                    require(count <= entry.file_size, "source-entry-overflow")
                    output.write(block)
                require(count == entry.file_size, "source-entry-underflow")


def verify_payload(shell, directory, work, ctx, validator, historical=False):
    directory, shell, work = Path(directory), Path(shell), Path(work)
    if historical:
        # Export DATA from the exact historical commit, not executable scripts.
        # Its canonical origin/main ancestry is independently checked first.
        require(pair.git(shell, "remote", "get-url", "origin").removesuffix(".git") == REMOTE.removesuffix(".git"),
                "source-repository-mismatch")
        pair.git(shell, "merge-base", "--is-ancestor", ctx["sha"], "HEAD")
        snapshot = work / "historical-source-data"
        for name in ("windows/toolchain.json", "windows/toolchain/python-bootstrap.lock.txt",
                     "windows/toolchain/python-tools.lock.txt", "windows/sources.lock.json",
                     "windows/ci/pair-contract.json", "windows/release/version.json",
                     "windows/release/source-assets.json", "windows/release/vendor-privacy-review.json",
                     "windows/capture/Cargo.lock"):
            path = snapshot / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(checked_run(["git", "-C", shell, "show", ctx["sha"] + ":" + name]))
        result = read(directory / "pair-result.json")
        candidate.check_pair_header(result, ctx)
        request = read(directory / "pair-request.json")
        lock = read(snapshot / "windows/sources.lock.json")
        require(request["shell"] == ctx["sha"] and request["backend"] == lock["quickshell"]["revision"]
                and pair.git(shell, "ls-tree", ctx["sha"], "--", "windows/deps/quickshell") ==
                "160000 commit " + request["backend"] + "\twindows/deps/quickshell", "historical-source-pin")
        # The same data/receipt verifier below is used; source identity already
        # comes from immutable canonical Git objects rather than an artifact.
        source = snapshot
    else:
        source = shell
    # Keep the receipt verification's identity check explicit, not a CLI bypass.
    if historical:
        request, receipt = candidate.verify_receipt_data(source, directory, validator, ctx)
    else:
        request, receipt = candidate.verify_receipt(source, directory, validator, ctx)
    data = read(directory / "candidate.json")
    release = data["release"]
    version = read(source / "windows/release/version.json")
    require(release["buildVersion"] == version["version"] + "-dev." + str(version["developmentEpoch"]) +
            "." + ctx["runNumber"] + "." + ctx["runAttempt"], "version-source-binding")
    # Independently rerun reviewed supplier acquisition/notices, not merely an
    # edited "coverage passed" field. No rebuild and no historical code runs.
    for root in (shell, shell / "windows/deps/quickshell", shell / "windows/deps/m3shapes"):
        if pair.git(root, "rev-parse", "--is-shallow-repository") == "true":
            checked_run(["git", "-C", root, "-c", "credential.helper=", "fetch", "--unshallow", "origin"], timeout=600)
    reprepared = work / "independent-source-assets"
    checked_run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                 shell / "windows/scripts/Prepare-CaelestiaSourceAssets.ps1",
                 "-SourceRoot", shell, "-SourceRevision", ctx["sha"],
                 "-OutputDirectory", reprepared, "-CacheDirectory", work / "supplier-cache"], timeout=3600,
                diagnostic_log=work / "independent-sources.private.log")
    original_inventory = read(directory / "source-assets-inventory.json")
    fresh_inventory = read(reprepared / "component-inventory.json")
    for inventory in (original_inventory, fresh_inventory):
        # Git can legally repack a self-contained source bundle differently.
        # Verify the supplied bundles' exact commits separately; every other
        # recipe/supplier/notice/source-ownership field must reproduce exactly.
        for project in inventory["projects"]:
            project.pop("sha256")
    require(original_inventory == fresh_inventory, "independent-source-notice-reproduction-mismatch")
    assets_root = work / "source-assets"
    assets_root.mkdir()
    extract_source(directory / "project-source.zip", assets_root / "project-source")
    extract_source(directory / "supplier-source.zip", assets_root / "supplier-source")
    args = ["powershell.exe", "-NoProfile", "-NonInteractive", "-File", shell / "windows/ci/Test-NexusCandidatePayload.ps1",
            "-CandidateDirectory", directory, "-OutputDirectory", work / "payload-check",
            "-SourceDataRoot", source, "-AssetsRoot", assets_root]
    checked_run(args, timeout=600, diagnostic_log=work / "independent-payload.private.log")
    return data


def ancestor(shell, older, newer):
    require(candidate.SHA.fullmatch(older) and candidate.SHA.fullmatch(newer), "invalid-source-sha")
    result = subprocess.run(["git", "-C", str(shell), "merge-base", "--is-ancestor", older, newer],
                            capture_output=True, timeout=120)
    require(result.returncode in (0, 1), "source-ancestry-unavailable")
    return result.returncode == 0


def find_release(github, tag):
    current = github.api(f"repos/{REPO}/releases/tags/{tag}", missing=True)
    if current is not None:
        return current
    # The by-tag endpoint is documented for published releases. Authenticated
    # draft recovery therefore also uses the bounded releases list. Never
    # treat an API/auth failure or an ambiguous list as a missing release.
    for page in range(1, 11):
        rows = github.api(f"repos/{REPO}/releases?per_page=100&page={page}")
        require(isinstance(rows, list), "invalid-release-list")
        matches = [row for row in rows if row["tag_name"] == tag]
        require(len(matches) <= 1, "ambiguous-draft-release")
        if matches:
            return matches[0]
        if len(rows) < 100:
            return None
    raise ValueError("draft-lookup-page-cap")


def assert_tag(github, release, required=False):
    existing_ref = github.api(f"repos/{REPO}/git/ref/tags/{release['tag']}", missing=not required)
    require(not required or existing_ref is not None, "published-tag-missing")
    if existing_ref is not None:
        obj = existing_ref["object"]
        if obj["type"] == "tag":
            obj = github.api(f"repos/{REPO}/git/tags/{obj['sha']}")["object"]
        require(obj["type"] == "commit" and obj["sha"] == release["sourceRevision"], "immutable-tag-target-mismatch")


def ensure_release(github, directory, release, rows, signed_record, record_name):
    """Draft -> verified assets -> publish. Recovery never clobbers bytes."""
    tag = release["tag"]
    assert_tag(github, release)
    current = find_release(github, tag)
    if current is None:
        current = github.api(f"repos/{REPO}/releases", "POST", {
            "tag_name": tag, "target_commitish": release["sourceRevision"],
            "name": release["displayVersion"], "draft": True,
            "prerelease": "-" in release["displayVersion"], "make_latest": "false",
            "body": ("Immutable tested artifact; metadata authentication is separate from Authenticode.\n\n"
                     f"[Changelog at tested source](https://github.com/{REPO}/blob/"
                     + release["sourceRevision"] + "/CHANGELOG.md)\n\n"
                     f"[Exact source](https://github.com/{REPO}/tree/" + release["sourceRevision"]
                     + ")\n\nSee the attached authenticated release record and corresponding source assets.")})
    require(current["tag_name"] == tag and current["target_commitish"] == release["sourceRevision"]
            and current["prerelease"] == ("-" in release["displayVersion"]), "release-identity-mismatch")
    assets = current["assets"]
    require(len(assets) <= 64, "release-asset-cap")
    names = [asset["name"] for asset in assets]
    expected_names = {row["name"] for row in rows} | {record_name}
    require(len(names) == len(set(name.casefold() for name in names))
            and set(names) <= expected_names, "unexpected-immutable-assets")
    # A record generated on a retry has randomized ECDSA signatures. Preserve
    # the already authenticated original bytes if its payload is identical.
    record_path = Path(directory) / record_name
    record_path.write_bytes(signed_record)
    all_rows = rows + [{"name": record_name, "size": len(signed_record), "sha256": hashlib.sha256(signed_record).hexdigest()}]
    for row in all_rows:
        found = next((asset for asset in assets if asset["name"] == row["name"]), None)
        if found is None:
            require(current["draft"] is True, "published-release-missing-asset")
            github.upload(tag, Path(directory) / row["name"])
        else:
            download = Path(directory) / ("verify-" + row["name"])
            github.download(found, download, row)
            download.unlink()
    current = find_release(github, tag)
    require(current is not None, "uploaded-release-missing")
    require({asset["name"] for asset in current["assets"]} == expected_names, "release-asset-set-mismatch")
    # Download/hash every asset, including newly uploaded ones, before the
    # immutable publish transition and before exposing any channel pointer.
    for row in all_rows:
        asset = next(asset for asset in current["assets"] if asset["name"] == row["name"])
        download = Path(directory) / ("verify-" + row["name"])
        github.download(asset, download, row)
        download.unlink()
    if current["draft"]:
        github.api(f"repos/{REPO}/releases/{current['id']}", "PATCH", {"draft": False, "make_latest": "false"})
    # Publishing creates the tag for a new draft. Recheck the authoritative
    # resolved tag after that transition, never expose a raced tag via pointer.
    assert_tag(github, release, required=True)


def release_equal(left, right):
    return left == right


def make_pointer(channel, release, old, keys_version):
    sequence = old["sequence"] + 1 if old else 1
    require(type(sequence) is int and sequence <= 2**63 - 1, "pointer-sequence-exhausted")
    now = utc()
    return {"type": "caelestia-update-channel", "schema": 1, "repository": REPO,
            "channel": channel, "sequence": sequence, "issuedAt": stamp(now),
            "expires": stamp(now + dt.timedelta(days=14)), "keysVersion": keys_version, "release": release}


def keys_version(keys):
    # Signing/reading always independently authenticates this exact envelope.
    import base64
    doc = json.loads(keys, object_pairs_hook=candidate.object_pairs)
    return json.loads(base64.b64decode(doc["payload"], validate=True),
                      object_pairs_hook=candidate.object_pairs)["version"]


def publish_pointer(branch, crypto, channel, release, decide, before_first=None):
    ready = False
    for _ in range(3):
        keys, envelope = branch.read(channel)
        old = crypto.invoke("ReadChannel", channel, keys, document=envelope) if envelope is not None else None
        decision = decide(old)
        if decision != "advance":
            return decision
        if not ready and before_first:
            before_first(keys)
            ready = True
        payload = make_pointer(channel, release, old, keys_version(keys))
        signed = crypto.invoke("SignChannel", channel, keys, payload=payload)
        if branch.push(channel, signed):
            return "published"
    raise ValueError("pointer-cas-exhausted")


def development(directory, ctx, github, branch, crypto, shell, verify):
    doc = verify_candidate_header(directory, ctx)
    validate_run(github, ctx, artifact=True)
    verify(doc)
    release = doc["release"]
    rows = doc["assets"] + asset_rows(directory, ["candidate.json"])
    def decide(old):
        if old is None:
            return "advance"
        previous = old["release"]
        if build_key(release["buildVersion"]) == build_key(previous["buildVersion"]):
            require(release_equal(release, previous), "same-version-different-payload")
            return "unchanged"
        if build_key(release["buildVersion"]) < build_key(previous["buildVersion"]):
            return "superseded"
        require(ancestor(shell, previous["sourceRevision"], release["sourceRevision"]), "non-descendant-publication")
        return "advance"
    def prepare(keys):
        payload = {"type": "caelestia-release-record", "schema": 1, "repository": REPO,
                   "channel": "development", "signedAt": stamp(utc()), "release": release, "assets": rows}
        record = existing_record(github, crypto, keys, release["tag"], "development", payload, directory)
        ensure_release(github, directory, release, rows, record, "release-record.dsse.json")
    return publish_pointer(branch, crypto, "development", release, decide, prepare)


def existing_record(github, crypto, keys, tag, channel, expected, directory):
    current = find_release(github, tag)
    name = "release-record.dsse.json" if channel == "development" else "alias-record.dsse.json"
    found = next((asset for asset in current["assets"] if asset["name"] == name), None) if current else None
    if found:
        require(0 < found["size"] <= 65536 and re.fullmatch(r"sha256:[a-f0-9]{64}", found.get("digest", "")),
                "existing-record-server-digest-required")
        path = Path(directory) / ("existing-" + name)
        github.download(found, path, {"size": found["size"], "sha256": found["digest"].split(":")[1]})
        raw = path.read_bytes(); path.unlink()
        actual = crypto.invoke("ReadRecord", channel, keys, document=raw)
        require(all(actual[key] == expected[key] for key in expected if key != "signedAt"),
                "immutable-record-payload-mismatch")
        return raw
    return crypto.invoke("SignRecord", channel, keys, payload=expected)


def promote(directory, build, channel, alias, github, branch, crypto, shell, verify):
    require(channel in ("preview", "stable") and candidate.DEV.fullmatch(build), "invalid-promotion-input")
    core = build.split("-")[0]
    if channel == "stable":
        require(alias == core and not core.startswith("0."), "stable-requires-tested-1-plus-core")
    else:
        require(re.fullmatch(re.escape(core) + r"-(preview|rc)\.[1-9][0-9]*", alias), "preview-alias-core-mismatch")
    keys, _ = branch.read("development")
    record = crypto.invoke("ReadRecord", "development", keys,
                           document=(Path(directory) / "release-record.dsse.json").read_bytes())
    assert_assets(directory, record["assets"], ("release-record.dsse.json",))
    require(record["release"]["buildVersion"] == build, "promotion-record-build-mismatch")
    doc = verify_candidate_header(directory, candidate_context(read(Path(directory) / "candidate.json")),
                                  ("release-record.dsse.json",))
    require(doc["release"] == record["release"] and record["assets"] ==
            doc["assets"] + asset_rows(directory, ["candidate.json"]), "promotion-record-candidate-mismatch")
    validate_run(github, candidate_context(doc))
    verify(doc)
    require(ancestor(shell, doc["sourceRevision"], pair.git(shell, "rev-parse", "HEAD")), "promotion-not-main-ancestor")
    release = copy.deepcopy(doc["release"])
    release.update(displayVersion=alias, tag="v" + alias,
                   notesUrl=f"https://github.com/{REPO}/releases/tag/v{alias}")
    release["bundle"]["url"] = f"https://github.com/{REPO}/releases/download/v{alias}/" + release["bundle"]["name"]
    def decide(old):
        if old is None:
            return "advance"
        previous = old["release"]
        if previous == release:
            return "unchanged"
        require(build_key(release["buildVersion"]) > build_key(previous["buildVersion"]), "promotion-not-newer")
        if channel == "preview" and previous["displayVersion"].split("-")[0] == core:
            # rc sorts after preview; numeric identifiers compare without bounds.
            label, number = alias.split("-")[1].split(".")
            old_label, old_number = previous["displayVersion"].split("-")[1].split(".")
            require((label, decimal_key(number)) > (old_label, decimal_key(old_number)), "promotion-alias-not-newer")
        require(ancestor(shell, previous["sourceRevision"], release["sourceRevision"]), "promotion-non-descendant")
        return "advance"
    rows = record["assets"] + asset_rows(directory, ["release-record.dsse.json"])
    def prepare(current_keys):
        payload = {"type": "caelestia-alias-record", "schema": 1, "repository": REPO,
                   "channel": channel, "signedAt": stamp(utc()), "release": release, "assets": rows}
        alias_record = existing_record(github, crypto, current_keys, release["tag"], channel, payload, directory)
        ensure_release(github, directory, release, rows, alias_record, "alias-record.dsse.json")
    return publish_pointer(branch, crypto, channel, release, decide, prepare)


def refresh(channel, branch, crypto):
    # Missing means not configured yet. Never bootstrap a pointer from an
    # unsigned record or silently reset an invalid/expired pointer.
    for _ in range(3):
        keys, raw = branch.read(channel)
        if raw is None:
            return "not-configured"
        old = crypto.invoke("ReadChannel", channel, keys, document=raw)
        new = make_pointer(channel, copy.deepcopy(old["release"]), old, keys_version(keys))
        signed = crypto.invoke("SignChannel", channel, keys, payload=new)
        if branch.push(channel, signed):
            return "refreshed"
    raise ValueError("pointer-cas-exhausted")


def entry_context(env, mode):
    if mode == "development":
        return candidate.context(env)
    require(env.get("GITHUB_ACTIONS") == "true" and env.get("GITHUB_REPOSITORY") == REPO
            and env.get("GITHUB_REF") == "refs/heads/main"
            and env.get("GITHUB_EVENT_NAME") in ("workflow_dispatch", "schedule")
            and candidate.SHA.fullmatch(env.get("GITHUB_SHA", ""))
            and env.get("GITHUB_WORKFLOW_SHA") == env["GITHUB_SHA"], "owner-main-context-required")
    workflow = "nexus-promote.yml" if mode == "promote" else "nexus-refresh.yml"
    require(env.get("GITHUB_WORKFLOW_REF") == REPO + "/.github/workflows/" + workflow + "@refs/heads/main",
            "owner-workflow-mismatch")
    if mode == "promote":
        require(env["GITHUB_EVENT_NAME"] == "workflow_dispatch", "explicit-promotion-required")
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("development", "promote", "refresh-development", "refresh-promotion"))
    parser.add_argument("--shell", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--candidate")
    parser.add_argument("--build")
    parser.add_argument("--channel")
    parser.add_argument("--alias")
    args = parser.parse_args()
    secret = os.environ.pop("NEXUS_SIGNING_KEY", "")
    try:
        mode = "refresh" if args.mode.startswith("refresh-") else args.mode
        ctx = entry_context(os.environ, mode)
        gate = "NEXUS_DEVELOPMENT_PUBLISH" if args.mode in ("development", "refresh-development") else "NEXUS_PROMOTION_PUBLISH"
        require(os.environ.get(gate) == "enabled", "publisher-disabled")
        shell, work = Path(args.shell).resolve(), Path(args.work).absolute()
        trust = shell / "windows/release/update-trust.json"
        trust_value = read(trust)
        require(trust_value["status"] == "configured" and trust_value["rootKeys"]
                and secret and os.environ.get("GH_TOKEN"), "publisher-unconfigured")
        no_links(work)
        require(not work.exists() and not work.is_relative_to(shell) and not shell.is_relative_to(work),
                "fresh-external-publisher-work-required")
        require(pair.git(shell, "rev-parse", "HEAD") == os.environ["GITHUB_SHA"]
                and not pair.git(shell, "status", "--porcelain", "--untracked-files=all",
                                 "--ignore-submodules=none"), "publisher-source-not-exact-clean")
        work.mkdir(parents=True)
        github = GitHub()
        branch = ChannelBranch(work)
        crypto = Crypto(shell, work, trust, secret)
        # Trusted validator extracted as data from its unchanged pin; digest is
        # checked before import. No downloaded artifact script is executed.
        if args.mode in ("development", "promote"):
            validator = work / "candidate_contract.py"
            backend = shell / "windows/deps/quickshell"
            require(pair.git(backend, "remote", "get-url", "origin").removesuffix(".git") ==
                    "https://github.com/" + pair.REPOS["backend"], "producer-repository-mismatch")
            checked_run(["git", "-C", backend, "-c", "credential.helper=", "fetch", "--no-tags",
                         "origin", candidate.PRODUCER], timeout=120)
            validator.write_bytes(checked_run(["git", "-C", backend, "show",
                                              candidate.PRODUCER + ":.github/scripts/candidate_contract.py"]))
            require(digest(validator) == candidate.VALIDATOR, "trusted-validator-digest-mismatch")
        if args.mode == "development":
            require(args.candidate is not None, "candidate-required")
            verify = lambda doc: verify_payload(shell, args.candidate, work, ctx, validator)
            result = development(Path(args.candidate), ctx, github, branch, crypto, shell, verify)
        elif args.mode == "promote":
            require(args.build and candidate.DEV.fullmatch(args.build), "invalid-build-input")
            source = github.api(f"repos/{REPO}/releases/tags/v{args.build}")
            directory = work / "development-assets"; directory.mkdir()
            # The signed record is small; GitHub's HTTPS metadata digest bounds
            # the bootstrap fetch. All remaining bytes are then signed-bound.
            records = [row for row in source["assets"] if row["name"] == "release-record.dsse.json"]
            require(len(records) == 1 and 0 < records[0]["size"] <= 65536
                    and re.fullmatch(r"sha256:[a-f0-9]{64}", records[0].get("digest", "")), "missing-authenticated-release-record")
            github.download(records[0], directory / "release-record.dsse.json",
                            {"size": records[0]["size"], "sha256": records[0]["digest"].split(":")[1]})
            keys, _ = branch.read("development")
            record = crypto.invoke("ReadRecord", "development", keys, document=(directory / "release-record.dsse.json").read_bytes())
            require(source["draft"] is False and {row["name"] for row in source["assets"]} ==
                    {row["name"] for row in record["assets"]} | {"release-record.dsse.json"}, "development-release-incomplete")
            for row in record["assets"]:
                safe_name(row["name"])
                asset = next(item for item in source["assets"] if item["name"] == row["name"])
                github.download(asset, directory / row["name"], row)
            verify = lambda doc: verify_payload(shell, directory, work, candidate_context(doc), validator, historical=True)
            result = promote(directory, args.build, args.channel, args.alias, github, branch, crypto, shell, verify)
        else:
            channels = ("development",) if args.mode == "refresh-development" else ("preview", "stable")
            result = ",".join(channel + ":" + refresh(channel, branch, crypto) for channel in channels)
        print("NEXUS_PUBLICATION " + result)
        return 0
    except PermissionError:
        print("Nexus authorization denied; owner intervention required. No retry.", file=sys.stderr)
        return 1
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError, StopIteration, zipfile.BadZipFile) as error:
        print("Nexus publication refused: " + candidate.failure_reason(error) +
              ". Inspect non-secret setup and exact-run gates.", file=sys.stderr)
        return 1
    finally:
        secret = ""
        os.environ.pop("NEXUS_SIGNING_KEY", None)


if __name__ == "__main__":
    raise SystemExit(main())
