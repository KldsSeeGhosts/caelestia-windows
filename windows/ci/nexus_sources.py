"""Same-run public source preparation, before eligibility; never a release PASS."""
import argparse
import hashlib
import math
import os
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nexus_candidate as candidate
import nexus_process
import nexus_publish as publication

require, read, digest = candidate.require, candidate.read, candidate.digest
FILES = ("component-inventory.json", "execution.json", "project-source.zip", "supplier-source.zip")
INDEX = "source-transfer.json"


def member(root, name):
    require(isinstance(name, str) and len(name) <= 1024, "source-transfer-path")
    for part in name.split("/"):
        publication.safe_name(part)
    path = Path(root).joinpath(*name.split("/"))
    publication.no_links(path)
    return path


def verify_inventory(shell, inventory, ctx):
    require(inventory["schema"] == "caelestia-component-inventory" and inventory["version"] == 1
            and inventory["sourceRevision"] == ctx["sha"], "source-transfer-source-mismatch")
    recipe_path = Path(shell) / "windows/release/source-assets.json"
    recipe_bytes = recipe_path.read_text(encoding="utf-8-sig").replace("\r\n", "\n").encode()
    require(inventory["recipeSha256"] == hashlib.sha256(recipe_bytes).hexdigest(),
            "source-transfer-recipe-mismatch")
    require(inventory["toolchain"] == read(Path(shell) / "windows/toolchain.json"),
            "source-transfer-toolchain-mismatch")
    recipe, lock = read(recipe_path), read(Path(shell) / "windows/sources.lock.json")
    expected = {"shell": (recipe["shellRepository"], ctx["sha"])}
    for name, identity in (("quickshell", "backend"), ("m3shapes", "m3shapes"), ("glazier", "capture")):
        if name == "glazier" and lock[name].get("representation") == "in-tree":
            continue
        expected[identity] = (lock[name]["repository"], lock[name]["revision"])
    actual = {row["id"]: (row["repository"], row["revision"]) for row in inventory["projects"]}
    require(len(actual) == len(inventory["projects"]) and actual == expected,
            "source-transfer-project-mismatch")


def rows(root):
    result, seen, total = [], set(), 0
    for path in sorted(Path(root).rglob("*")):
        publication.no_links(path)
        if path.is_dir():
            continue
        name = path.relative_to(root).as_posix()
        if name == INDEX:
            continue
        member(root, name)
        require(name in FILES or name.startswith("notices/"), "source-transfer-extra-file")
        require(not name.startswith("notices/") or path.suffix.lower() not in
                (".exe", ".dll", ".pdb", ".zip", ".7z", ".tar", ".xz"), "source-transfer-binary-notice")
        require(name.casefold() not in seen, "source-transfer-duplicate-file")
        seen.add(name.casefold())
        size = path.stat().st_size
        total += size
        require(0 <= size <= 1024**3 and total <= 2 * 1024**3 and len(result) < 50000,
                "source-transfer-size-cap")
        result.append({"path": name, "size": size, "sha256": digest(path)})
    require(set(FILES) <= {row["path"] for row in result}
            and any(row["path"].startswith("notices/") for row in result), "source-transfer-incomplete")
    return result


def export(shell, assets, output, stage, ctx):
    shell, assets, output = Path(shell), Path(assets), Path(output)
    publication.no_links(assets)
    publication.no_links(output)
    require(not output.exists(), "fresh-source-transfer-required")
    inventory = read(assets / "component-inventory.json")
    verify_inventory(shell, inventory, ctx)
    require(stage["stage"] == "sources" and stage["outcome"] == "success" and stage["exitCode"] == 0,
            "source-preparation-nonpass")
    output.mkdir()
    for name in FILES:
        shutil.copyfile(member(assets, name), output / name)
    for path in (assets / "notices").rglob("*"):
        publication.no_links(path)
        if not path.is_file():
            continue
        name = "notices/" + path.relative_to(assets / "notices").as_posix()
        target = member(output, name)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    document = {"schema": "caelestia-nexus-source-transfer", "version": 1,
                "run": ctx, "preparation": stage, "files": rows(output)}
    candidate.public_metadata(document)
    publication.write(output / INDEX, document)


def verify_transfer(shell, transfer, ctx):
    transfer = Path(transfer)
    publication.no_links(transfer)
    document = read(member(transfer, INDEX))
    require(set(document) == {"schema", "version", "run", "preparation", "files"}
            and document["schema"] == "caelestia-nexus-source-transfer" and document["version"] == 1
            and document["run"] == ctx, "source-transfer-run-mismatch")
    stage = document["preparation"]
    require(set(stage) == {"stage", "outcome", "exitCode", "seconds", "timeoutSeconds"}
            and stage["stage"] == "sources" and stage["outcome"] == "success"
            and type(stage["exitCode"]) is int and stage["exitCode"] == 0
            and type(stage["seconds"]) in (int, float) and math.isfinite(stage["seconds"])
            and stage["seconds"] >= 0 and stage["timeoutSeconds"] == 1800,
            "source-preparation-nonpass")
    require(document["files"] == rows(transfer), "source-transfer-bytes-mismatch")
    inventory = read(transfer / "component-inventory.json")
    verify_inventory(shell, inventory, ctx)
    execution = read(transfer / "execution.json")
    require(execution["schema"] == "caelestia-source-execution" and execution["version"] == 1
            and execution["sourceRevision"] == ctx["sha"], "source-transfer-execution-mismatch")
    require({row["path"] for row in document["files"] if row["path"].startswith("notices/")}
            == {"notices/" + notice["path"] for notice in inventory["notices"]},
            "source-transfer-notice-set-mismatch")
    for notice in inventory["notices"]:
        path = member(transfer / "notices", notice["path"])
        require(digest(path) == notice["sha256"], "source-transfer-notice-mismatch")
    return document


def materialize(shell, transfer, output, ctx):
    transfer, output = Path(transfer), Path(output)
    document = verify_transfer(shell, transfer, ctx)
    publication.no_links(output)
    require(not output.exists(), "fresh-source-materialization-required")
    require(not output.is_relative_to(transfer) and not transfer.is_relative_to(output)
            and not output.is_relative_to(Path(shell)), "source-transfer-overlap")
    output.mkdir()
    for row in document["files"]:
        target = member(output, row["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(member(transfer, row["path"]), target)
        require(digest(target) == row["sha256"], "source-transfer-copy-mismatch")
    inventory_hash = digest(output / "component-inventory.json")
    for name in ("project-source", "supplier-source"):
        publication.extract_source(output / (name + ".zip"), output / name)
        require(digest(output / name / "component-inventory.json") == inventory_hash,
                "source-transfer-embedded-inventory-mismatch")
        manifest = read(output / name / "SOURCE-MANIFEST.json")
        require(manifest["sourceRevision"] == ctx["sha"] and manifest["inventorySha256"] == inventory_hash,
                "source-transfer-manifest-mismatch")


def prepare(shell, work, ctx):
    shell, work = Path(shell).resolve(), Path(work).resolve()
    candidate.pair.source(shell, "shell", ctx["sha"])
    publication.no_links(work)
    require(not work.exists() and not work.is_relative_to(shell), "fresh-source-work-required")
    work.mkdir()
    private = work / "private"
    private.mkdir()
    for name, root in (("shell", shell), ("backend", shell / "windows/deps/quickshell"),
                       ("m3shapes", shell / "windows/deps/m3shapes")):
        if candidate.pair.git(root, "rev-parse", "--is-shallow-repository") == "true":
            sha = candidate.pair.git(root, "rev-parse", "HEAD")
            code = nexus_process.run_stage(
                ["git", "-c", "credential.helper=", "-c", "core.hooksPath=NUL", "-C", root,
                 "fetch", "--unshallow", "--no-tags", "--recurse-submodules=no", "origin", sha],
                private / ("history-" + name + ".log"), "history-" + name, 300)
            require(code == 0, "source-history-nonpass")
    assets = work / "prepared"
    code = nexus_process.run_stage(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
         shell / "windows/ci/Invoke-NexusSources.ps1", "-SourceRoot", shell,
         "-SourceRevision", ctx["sha"], "-OutputDirectory", assets, "-CacheDirectory", work / "cache"],
        private / "sources.log", "sources", 1800, echo=True)
    require(code == 0, "source-preparation-nonpass")
    export(shell, assets, work / "out", read(private / "sources.state.json"), ctx)
    # Public source objects are already public upstream/Git bytes. Before
    # uploading, apply the existing privacy policy to metadata and notices too.
    code = nexus_process.run_stage(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
         shell / "windows/ci/Invoke-NexusSources.ps1", "-Transfer", work / "out"],
        private / "source-privacy.log", "source-privacy", 300, echo=True)
    require(code == 0, "source-transfer-privacy-nonpass")
    verify_transfer(shell, work / "out", ctx)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "materialize"))
    parser.add_argument("--shell", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--transfer", type=Path)
    args = parser.parse_args()
    try:
        ctx = candidate.context(os.environ)
        if args.action == "prepare":
            prepare(args.shell, args.output, ctx)
        else:
            require(args.transfer is not None, "source-transfer-required")
            materialize(args.shell, args.transfer, args.output, ctx)
        print("NEXUS_SOURCE_DATA_PASS not-release-evidence")
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print("NEXUS_SOURCE_REFUSED " + candidate.failure_reason(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
