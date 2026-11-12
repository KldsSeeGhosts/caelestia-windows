"""Dependency inventory, receipt-bound CycloneDX and RustSec result policy.

Only inventory refresh and cargo-audit acquisition need network access. SBOM
generation reads ZIP members without extracting or executing the package.
"""

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[2]
INVENTORY = "windows/release/component-inventory.json"
EXCEPTIONS = "windows/release/advisory-exceptions.json"
BUILD_CRATES = {
    "proc-macro2", "quote", "syn", "unicode-ident", "serde_derive",
    "windows-implement", "windows-interface",
}
LICENSES = {
    "shell": "GPL-3.0-only", "backend": "LGPL-3.0-only",
    "m3shapes": "Apache-2.0", "capture": "MIT", "qt": "LGPL-3.0-only",
    "cli11": "BSD-3-Clause", "rust": "MIT OR Apache-2.0",
    "schemeCli": "GPL-3.0-only", "materialyoucolor": "MIT", "pillow": "HPND",
    "python": "PSF-2.0", "microsoft-vc-runtime": "LicenseRef-Microsoft-Visual-Studio",
    "llvm": "Apache-2.0 WITH LLVM-exception", "cmake": "BSD-3-Clause",
    "ninja": "Apache-2.0", "cargo": "MIT OR Apache-2.0", "aqt": "MIT",
    "msvc": "LicenseRef-Microsoft-Visual-Studio",
    "windows-sdk": "LicenseRef-Microsoft-Windows-SDK",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def crate_id(package):
    return f"crate-{package['name']}-{package['version']}"


def generate_inventory(root=ROOT, previous=None, supplier=None):
    """Recompute pins from their owners; retain reviewed crate licence metadata."""
    root = Path(root)
    lock = tomllib.loads((root / "windows/capture/Cargo.lock").read_text())
    pins = read(root / "windows/sources.lock.json")
    tools = read(root / "windows/toolchain.json")
    qt = read(root / "windows/release/qt-source-notices.json")
    require(qt["qtVersion"] == tools["qtVersion"], "Qt review/toolchain mismatch")
    prior = {c["id"]: c for c in (previous or {}).get("components", [])}
    suppliers = {s["component"]: s for s in (supplier or {}).get("suppliers", [])}
    components = {}

    def add(identity, version, source, license_text=None, classification="runtime payload", **extra):
        components[identity] = dict(
            id=identity, version=version, source=source,
            license=license_text or LICENSES[identity], classification=classification, **extra)

    add("shell", read(root / "windows/release/version.json")["version"],
        "https://github.com/KldsSeeGhosts/caelestia-windows.git",
        upstreamSource=pins["caelestia"]["repository"], upstreamRevision=pins["caelestia"]["revision"])
    for identity, key in (("backend", "quickshell"), ("m3shapes", "m3shapes")):
        add(identity, pins[key]["revision"], pins[key]["repository"])
    capture = tomllib.loads((root / "windows/capture/Cargo.toml").read_text())["package"]
    add("capture", capture["version"], "https://github.com/KldsSeeGhosts/caelestia-windows.git",
        origin=pins["glazier"]["repository"], originRevision=pins["glazier"]["originRevision"])
    add("qt", tools["qtVersion"], "https://download.qt.io/",
        noticeReview="windows/release/qt-source-notices.json")
    for archive in qt["archives"]:
        module = Path(archive["path"]).name.split("-everywhere")[0]
        add("qt-" + module, tools["qtVersion"], archive["url"],
            " AND ".join(f"({v})" for v in archive["licenses"]),
            "build-only" if module in {"qttools", "qtshadertools"} else "runtime payload",
            sourceSha256=archive["sha256"], applicability="conservative source module, not linkage evidence")
    for file in qt["payloadFiles"]:
        if file["path"].lower().endswith(".dll"):
            add("qt-file:" + file["path"], tools["qtVersion"], "https://download.qt.io/",
                LICENSES["qt"], payloadPath=file["path"], payloadSha256=file["sha256"])
    for package in lock["package"]:
        if "source" not in package:
            continue
        identity = crate_id(package)
        reviewed = suppliers.get(identity)
        if reviewed:
            require(reviewed["sha256"] == package["checksum"], f"Supplier checksum mismatch: {identity}")
            license_text = " AND ".join(reviewed["recordedLicenses"])
        else:
            old = prior.get(identity, {})
            require(old.get("sourceSha256") == package["checksum"], f"Review new crate licence: {identity}")
            license_text = old["license"]
        require(bool(license_text), f"Missing crate licence: {identity}")
        add(identity, package["version"],
            f"https://static.crates.io/crates/{package['name']}/{package['name']}-{package['version']}.crate",
            license_text, "build-only" if package["name"] in BUILD_CRATES else "runtime payload",
            sourceSha256=package["checksum"], dependencies=package.get("dependencies", []),
            applicability="resolved Cargo graph, static binary linkage not inferred")
    for font in pins["fonts"]:
        folder = Path(font["files"][0]["path"]).parent.name
        add("font-" + folder, font.get("release", font.get("revision")), font["repository"], font["license"])
    add("schemeCli", pins["schemeCli"]["revision"], pins["schemeCli"]["repository"],
        classification="optional")
    for name, origin in (("materialyoucolor", "https://github.com/T-Dynamos/materialyoucolor-python"),
                         ("pillow", "https://github.com/python-pillow/Pillow")):
        add(name, pins["schemeCli"]["pythonPackages"][name], origin, classification="optional")
    for identity, version_key, origin, classification in (
        ("python", "pythonVersion", "https://www.python.org/", "optional"),
        ("microsoft-vc-runtime", "runtimeMinimum", "https://aka.ms/vc14/vc_redist.x64.exe", "optional"),
        ("rust", "rustVersion", "https://www.rust-lang.org/", "build-only"),
        ("cargo", "cargoVersion", "https://www.rust-lang.org/", "build-only"),
        ("cmake", "cmakeVersion", "https://cmake.org/", "build-only"),
        ("ninja", "ninjaVersion", "https://ninja-build.org/", "build-only"),
        ("msvc", "vcToolsVersion", "https://visualstudio.microsoft.com/", "build-only"),
        ("windows-sdk", "windowsSdkVersion", "https://developer.microsoft.com/windows/downloads/windows-sdk/", "build-only"),
    ):
        add(identity, tools[version_key], origin, classification=classification)
    # CLI11 headers become compiled backend code; compiler executables do not.
    for identity, key in (("llvm", "clangVersion"), ("cli11", "cli11Version"), ("aqt", None)):
        download = tools["downloads"][identity]
        add(identity, tools[key] if key else download["file"], download["url"],
            classification="runtime payload" if identity == "cli11" else "build-only",
            sourceSha256=download["sha256"])
    sccache = (root / "windows/ci/Prepare-Sccache.ps1").read_text()
    sccache_version = re.search(r"\$version = '([^']+)'", sccache)[1]
    add("sccache", sccache_version,
        f"https://github.com/mozilla/sccache/releases/tag/v{sccache_version}",
        "Apache-2.0", "build-only", sourceSha256=re.search(r"\$sha256 = '([a-f0-9]{64})'", sccache)[1])
    advisory_workflow = (root / ".github/workflows/dependency-advisories.yml").read_text()
    audit_version = re.search(r"cargo-audit-([\d.]+)\.crate", advisory_workflow)[1]
    add("cargo-audit", audit_version, f"https://crates.io/crates/cargo-audit/{audit_version}",
        "Apache-2.0 OR MIT", "build-only",
        sourceSha256=re.search(r'echo "([a-f0-9]{64}) ', advisory_workflow)[1])
    workflow = (root / ".github/workflows/windows-build.yml").read_text()
    add("node", re.search(r"node-version: '([^']+)'", workflow)[1],
        "https://nodejs.org/", "MIT", "build-only")
    for workflow in sorted((root / ".github/workflows").glob("*.yml")):
        for action, revision in re.findall(r"uses:\s*([\w./-]+)@([^\s#]+)", workflow.read_text()):
            require(re.fullmatch("[0-9a-f]{40}", revision), f"Unpinned action: {action}")
            require(action.startswith("actions/"), f"Review action licence: {action}")
            add(f"action:{action}@{revision}", revision, f"https://github.com/{'/'.join(action.split('/')[:2])}",
                "MIT", "build-only")
    inputs = ["windows/capture/Cargo.lock", "windows/capture/Cargo.toml", "windows/toolchain.json",
              "windows/sources.lock.json", "windows/release/source-assets.json",
              "windows/release/qt-source-notices.json", "windows/release/vendor-privacy-review.json",
              "windows/release/version.json", "windows/ci/Prepare-Sccache.ps1"]
    return {
        "schema": "caelestia-dependency-inventory", "version": 1,
        "inputs": {p: sha((root / p).read_bytes().replace(b"\r\n", b"\n")) for p in inputs},
        "limitations": "Cargo graph and conservative source modules are not proof of binary linkage. "
                        "Optional components and external prerequisites are not installed payload.",
        "components": [components[k] for k in sorted(components)],
    }


def validate_exceptions(document, inventory, today=None):
    today = today or dt.date.today()
    require(document.get("schema") == "caelestia-advisory-exceptions" and document.get("version") == 1,
            "Invalid advisory exceptions schema")
    components = {c["id"]: c for c in inventory["components"]}
    seen = set()
    for entry in document["exceptions"]:
        key = (entry["id"], entry["component"])
        require(key not in seen, f"Duplicate exception: {key}")
        seen.add(key)
        require(entry["owner"].strip() and entry["reason"].strip() and entry["source"].startswith("https://"),
                f"Missing exception review information: {key}")
        require(dt.date.fromisoformat(entry["revisitDate"]) >= today, f"Expired exception: {entry['id']}")
        require(entry["component"] in components, f"Unknown exception component: {key}")
        require(entry["reviewedVersion"] == components[entry["component"]]["version"],
                f"Exception requires version review: {key}")
        require(entry["applicability"] in {
            "patched", "not-affected", "accepted-temporary", "accepted-mitigated", "absent"},
                f"Unknown exception applicability: {key}")
        if entry["applicability"] == "absent":
            require(components[entry["component"]]["classification"] == "optional",
                    f"Installed component cannot use absent exception: {key}")
        if entry["applicability"] == "patched":
            require(bool(entry["patchedVersions"]), f"Missing patched versions: {key}")
        if entry["applicability"] == "accepted-mitigated":
            require(bool(entry.get("mitigation", "").strip()), f"Missing exception mitigation: {key}")
            require("patchedVersions" not in entry, f"Mitigated exception must not claim patched versions: {key}")
    return document["exceptions"]


def check_audit(report, exceptions, inventory, exit_code=0):
    entries = validate_exceptions(exceptions, inventory)
    require(exit_code in {0, 1} and not report.get("error"), "cargo audit unavailable or failed")
    require(isinstance(report.get("database", {}).get("last-commit"), str) and
            bool(report["database"]["last-commit"]), "Advisory database unavailable")
    updated = report["database"].get("last-updated")
    require(isinstance(updated, str), "Advisory database timestamp unavailable")
    database_date = dt.date.fromisoformat(updated[:10])
    require(-dt.timedelta(days=1) <= dt.date.today() - database_date <= dt.timedelta(days=14),
            "Advisory database is stale or future-dated")
    settings = report.get("settings", {})
    require(not settings.get("ignore") and not settings.get("severity") and
            not settings.get("target_arch") and not settings.get("target_os"),
            "cargo audit result must not silently filter findings")
    vulnerabilities = report.get("vulnerabilities")
    require(isinstance(vulnerabilities, dict) and isinstance(vulnerabilities.get("list"), list),
            "Missing cargo audit vulnerability results")
    findings = list(vulnerabilities["list"])
    require(vulnerabilities.get("count") == len(findings), "Inconsistent cargo audit result count")
    for warning_list in report.get("warnings", {}).values():
        findings.extend(warning_list)
    outstanding = []
    known = {c["id"] for c in inventory["components"]}
    for finding in findings:
        advisory = (finding.get("advisory") or {}).get("id", finding.get("kind", "unknown-warning"))
        identity = crate_id(finding["package"])
        require(identity in known, f"Advisory result does not match inventory: {identity}")
        # Patched and absent reviews never suppress an actual Cargo finding.
        accepted = any(e["id"] == advisory and e["component"] == identity and
                       e["applicability"] in {"not-affected", "accepted-temporary"} for e in entries)
        if not accepted:
            outstanding.append(f"{advisory} ({identity})")
    require(not outstanding, "Unresolved advisories: " + ", ".join(outstanding))
    require(exit_code == 0 or findings, "cargo audit failed without advisory findings")


def safe_path(value):
    path = PurePosixPath(value)
    require(value and "\\" not in value and ":" not in value and not path.is_absolute() and
            all(p not in {"", ".", ".."} for p in value.split("/")), f"Unsafe package path: {value}")
    return value


ADVISORY_FRESHNESS_DAYS = 7


def inventory_digest(inventory):
    return sha(json.dumps(inventory, sort_keys=True).encode("utf-8"))


def advisory_receipt(report, exceptions, inventory, cargo_lock_sha256, checked_at=None):
    checked_at = checked_at or dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    if checked_at.tzinfo is None:
        checked_at = checked_at.replace(tzinfo=dt.timezone.utc)
    else:
        checked_at = checked_at.astimezone(dt.timezone.utc)
    check_audit(report, exceptions, inventory, 0)
    db = report["database"]
    return {
        "schema": "caelestia-advisory-result",
        "version": 1,
        "result": "pass",
        "checkedAt": checked_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "freshnessDays": ADVISORY_FRESHNESS_DAYS,
        "inventorySha256": inventory_digest(inventory),
        "cargoLockSha256": cargo_lock_sha256,
        "exceptionsSha256": sha(json.dumps(exceptions, sort_keys=True).encode("utf-8")),
        "databaseCommit": db["last-commit"],
        "databaseUpdated": db["last-updated"],
    }


def verify_advisory_result(result, inventory, exceptions, cargo_lock_sha256, now=None):
    now = now or dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    if now.tzinfo is None:
        now = now.replace(tzinfo=dt.timezone.utc)
    else:
        now = now.astimezone(dt.timezone.utc)
    require(isinstance(result, dict), "Advisory result is missing or malformed")
    require(result.get("schema") == "caelestia-advisory-result" and result.get("version") == 1,
            "Unsupported advisory result schema")
    require(result.get("result") == "pass", "Advisory check did not pass")
    checked_raw = result.get("checkedAt")
    require(isinstance(checked_raw, str) and checked_raw.endswith("Z"),
            "Advisory result timestamp is missing or not UTC")
    checked_at = dt.datetime.fromisoformat(checked_raw[:-1] + "+00:00")
    age = now - checked_at
    require(age >= -dt.timedelta(minutes=5), "Advisory result timestamp is future-dated")
    require(age <= dt.timedelta(days=ADVISORY_FRESHNESS_DAYS),
            f"Advisory result is stale (older than {ADVISORY_FRESHNESS_DAYS} days)")
    require(result.get("inventorySha256") == inventory_digest(inventory),
            "Advisory result inventory hash does not match candidate dependency inventory")
    require(result.get("cargoLockSha256") == cargo_lock_sha256,
            "Advisory result Cargo.lock hash does not match candidate lockfile")
    require(result.get("exceptionsSha256") == sha(json.dumps(exceptions, sort_keys=True).encode("utf-8")),
            "Advisory result exceptions hash does not match reviewed exceptions")
    validate_exceptions(exceptions, inventory, today=now.date())
    return result



def release_sbom(package, coverage_path, inventory, historical=False):
    """Use the assembler's existing exact-path coverage, never prefix guesses."""
    coverage = read(coverage_path)
    require(coverage["schema"] == "caelestia-component-inventory" and coverage["version"] == 1,
            "Invalid source coverage inventory")
    known = {c["id"]: c for c in inventory["components"]}
    suppliers = {c["id"]: c for c in coverage["components"]}
    application = coverage["application"]
    owners = {safe_path(f["path"]): f for f in application["files"]}
    require(len(owners) == len(application["files"]), "Duplicate coverage path")
    with zipfile.ZipFile(package) as archive:
        names = [e.filename for e in archive.infolist() if not e.is_dir()]
        require(len({n.casefold() for n in names}) == len(names), "Duplicate ZIP member")
        require(all(not e.flag_bits & 1 for e in archive.infolist()), "Encrypted ZIP member")
        manifests = [n for n in names if n.endswith("/release.json")]
        require(len(manifests) == 1, "Expected exactly one release.json")
        manifest_name = manifests[0]
        prefix = manifest_name[:-len("release.json")]
        manifest_bytes = archive.read(manifest_name)
        require(sha(manifest_bytes) == application["manifestSha256"], "Coverage receipt hash mismatch")
        manifest = json.loads(manifest_bytes.decode("utf-8-sig"))
        require(manifest["sourceRevision"] == coverage["sourceRevision"], "Coverage source mismatch")
        files = {safe_path(f["path"]): f for f in manifest["files"]}
        require(len(files) == len(manifest["files"]), "Duplicate receipt path")
        require(set(files) == set(owners), "Unknown packaged file or stale coverage")
        require(set(names) == {prefix + p for p in files} | {manifest_name},
                "Unknown packaged file outside receipt")
        for path, file in files.items():
            safe_path(prefix + path)
            actual = archive.read(prefix + path)
            require(len(actual) == file["size"] and sha(actual) == file["sha256"], f"Payload hash mismatch: {path}")
            require(all(file[k] == owners[path][k] for k in ("sha256", "size")), f"Coverage file mismatch: {path}")
    if not historical:
        require(manifest["qtVersion"] == known["qt"]["version"], "Package Qt differs from current inventory")
        for identity, key in (("backend", "quickshell"), ("m3shapes", "m3shapes")):
            require(manifest["dependencies"][key]["revision"] == known[identity]["version"],
                    f"Package pin differs from current inventory: {identity}")
    selected = {}
    mapping = {}
    for path in files:
        owner = owners[path]["component"]
        require(owner in known and owner in suppliers, f"Unknown inventory component: {owner}")
        require(known[owner]["classification"] != "optional", f"Optional component unexpectedly installed: {owner}")
        if not historical and owner not in {"shell", "capture"}:
            require(suppliers[owner]["version"] == known[owner]["version"],
                    f"Package component differs from current inventory: {owner}")
        identity = "qt-file:" + path if owner == "qt" and path.lower().endswith(".dll") else owner
        require(identity in known, f"Unreviewed Qt module/plugin: {path}")
        if identity.startswith("qt-file:") and not historical:
            require(files[path]["sha256"] == known[identity]["payloadSha256"], f"Unreviewed Qt bytes: {path}")
        mapping[path] = identity
        selected[identity] = dict(known[identity], version=suppliers[owner]["version"],
                                  source=suppliers[owner]["source"])
        if historical and suppliers[owner].get("recordedLicenses"):
            selected[identity]["license"] = " AND ".join(suppliers[owner]["recordedLicenses"])
    # Conservatively include the package's resolved source graph, explicitly
    # separate from file evidence. A shipped notice alone proves no linkage.
    for identity, supplier in suppliers.items():
        if identity.startswith("crate-") or identity == "cli11":
            require(identity in known and supplier["version"] == known[identity]["version"],
                    f"Unreviewed package dependency: {identity}")
            selected[identity] = known[identity]
    components = []
    dependencies = []
    for identity, entry in sorted(selected.items()):
        source = entry["source"] if isinstance(entry["source"], str) else entry["source"][0]
        properties = [{"name": "caelestia:classification", "value": entry["classification"]}]
        if "applicability" in entry:
            properties.append({"name": "caelestia:applicability", "value": entry["applicability"]})
        components.append({
            "type": "library", "bom-ref": identity, "name": identity,
            "version": entry["version"], "scope": "excluded" if entry["classification"] == "build-only" else "required",
            "licenses": [{"expression": entry["license"]}],
            "externalReferences": [{"type": "vcs" if source.endswith(".git") else "distribution", "url": source}],
            "properties": properties,
        })
        children = []
        for dependency in entry.get("dependencies", []):
            bits = dependency.split()
            matches = [k for k in selected if k.startswith("crate-" + bits[0] + "-") and
                       (len(bits) == 1 or selected[k]["version"] == bits[1])]
            require(len(matches) == 1, f"Ambiguous Cargo dependency: {dependency}")
            children.extend(matches)
        if identity == "capture":
            children.extend(k for k in selected if k.startswith("crate-"))
        dependencies.append({"ref": identity, "dependsOn": sorted(set(children))})
    # Model every receipt member as a CycloneDX file, with an explicit owner edge.
    for path, file in sorted(files.items()):
        identity = "file:" + path
        components.append({"type": "file", "bom-ref": identity, "name": path,
                           "hashes": [{"alg": "SHA-256", "content": file["sha256"]}]})
        dependencies.append({"ref": identity, "dependsOn": [mapping[path]]})
    components.append({"type": "file", "bom-ref": "release.json", "name": "release.json",
                       "hashes": [{"alg": "SHA-256", "content": sha(manifest_bytes)}]})
    return {
        "bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1,
        "metadata": {
            "component": {"type": "application", "bom-ref": "release", "name": "caelestia-windows",
                          "version": manifest["releaseId"],
                          "hashes": [{"alg": "SHA-256", "content": sha(Path(package).read_bytes())}]},
            "properties": [
                {"name": "caelestia:sourceRevision", "value": manifest["sourceRevision"]},
                {"name": "caelestia:release.json:sha256", "value": sha(manifest_bytes)},
                {"name": "caelestia:coverage:sha256", "value": sha(Path(coverage_path).read_bytes())},
                {"name": "caelestia:inventory:sha256", "value": inventory_digest(inventory)},
                {"name": "caelestia:limitations", "value": inventory["limitations"]},
            ],
        },
        "components": components,
        "dependencies": [{"ref": "release", "dependsOn":
                          sorted(selected) + ["release.json"] + ["file:" + p for p in sorted(files)]}] + dependencies,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    refresh = sub.add_parser("inventory")
    refresh.add_argument("--supplier-inventory", type=Path)
    refresh.add_argument("--check", action="store_true")
    sbom = sub.add_parser("sbom")
    sbom.add_argument("--package", type=Path, required=True)
    sbom.add_argument("--coverage", type=Path, required=True)
    sbom.add_argument("--output", type=Path, required=True)
    sbom.add_argument("--receipt-output", type=Path, help="Retain the verified release.json beside the SBOM")
    sbom.add_argument("--allow-historical", action="store_true",
                      help="Use supplied historical receipt versions, never relabel them as current")
    audit = sub.add_parser("audit")
    audit.add_argument("--cargo-audit", default="cargo-audit")
    audit.add_argument("--output", type=Path, required=True)
    audit.add_argument("--receipt-output", type=Path, help="Write inventory-bound advisory receipt JSON")
    fixture = sub.add_parser("scanner-fixture", help="Prove the real scanner detects the controlled vulnerable lock")
    fixture.add_argument("--cargo-audit", default="cargo-audit")
    fixture.add_argument("--output", type=Path, required=True)
    verify_adv = sub.add_parser("verify-advisory", help="Verify a retained advisory receipt against current inventory")
    verify_adv.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    inventory_path = ROOT / INVENTORY
    inventory = read(inventory_path) if inventory_path.exists() else None
    if args.command == "inventory":
        generated = generate_inventory(previous=inventory,
                                       supplier=read(args.supplier_inventory) if args.supplier_inventory else None)
        if args.check:
            require(inventory == generated, "Inventory drift. Review and regenerate the inventory.")
            validate_exceptions(read(ROOT / EXCEPTIONS), inventory)
        else:
            write(inventory_path, generated)
    elif args.command == "sbom":
        require(inventory == generate_inventory(previous=inventory), "Inventory drift")
        write(args.output, release_sbom(args.package, args.coverage, inventory, args.allow_historical))
        if args.receipt_output:
            with zipfile.ZipFile(args.package) as archive:
                receipt = next(n for n in archive.namelist() if n.endswith("/release.json"))
                args.receipt_output.write_bytes(archive.read(receipt))
    elif args.command == "verify-advisory":
        require(inventory == generate_inventory(previous=inventory), "Inventory drift")
        exceptions = read(ROOT / EXCEPTIONS)
        cargo_lock_sha = sha((ROOT / "windows/capture/Cargo.lock").read_bytes())
        verify_advisory_result(read(args.input), inventory, exceptions, cargo_lock_sha)
    else:
        require(inventory == generate_inventory(previous=inventory), "Inventory drift")
        exceptions = read(ROOT / EXCEPTIONS)
        validate_exceptions(exceptions, inventory)
        lock = ROOT / "windows/capture/Cargo.lock"
        if args.command == "scanner-fixture":
            lock = ROOT / "windows/tests/fixtures/dependencies/vulnerable.Cargo.lock"
            package = tomllib.loads(lock.read_text())["package"][0]
            inventory = dict(inventory, components=inventory["components"] + [
                dict(id=crate_id(package), version=package["version"], classification="runtime payload")])
        result = subprocess.run([args.cargo_audit, "audit", "--json", "--file", str(lock)],
                                capture_output=True, text=True)
        require(result.stdout.strip(), "cargo audit unavailable: " + result.stderr[-2000:])
        report = json.loads(result.stdout)
        write(args.output, report)
        if args.command == "scanner-fixture":
            try:
                check_audit(report, exceptions, inventory, result.returncode)
            except ValueError as error:
                require(str(error).startswith("Unresolved advisories:") and "RUSTSEC-2022-0008" in str(error),
                        f"Controlled scanner fixture failed for the wrong reason: {error}")
            else:
                raise ValueError("Controlled vulnerable-version fixture did not trigger the advisory check")
        else:
            check_audit(report, exceptions, inventory, result.returncode)
            if args.receipt_output:
                cargo_lock_sha = sha(lock.read_bytes())
                write(args.receipt_output, advisory_receipt(report, exceptions, inventory, cargo_lock_sha))
    print(f"PASS dependency {args.command}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        print(f"Dependency check refused: {error}", file=sys.stderr)
        sys.exit(1)
