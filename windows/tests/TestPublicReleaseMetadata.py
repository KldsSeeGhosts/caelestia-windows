"""Offline release/docs contract and opt-in anonymous post-publication checks.

No credentials, installation, extraction or native binaries. Online mode reads
the GitHub API, HEADs every asset and downloads the application ZIP and sidecars.
The ZIP's qualified release.json is checked without executing its contents.
"""

import argparse
import copy
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REPO = "https://github.com/KldsSeeGhosts/caelestia-windows"
DOCS = (
    "README.md", "windows/README.md", "windows/docs/INSTALL-RELEASE.md",
    "windows/docs/RELEASE-CHECKLIST.md", "windows/docs/RELEASE-RECIPE.md",
    "windows/docs/KNOWN-LIMITATIONS.md", "UPDATES.md",
    "windows/docs/SIGNING-ROADMAP.md",
)
START = "<!-- public-release:start -->"
END = "<!-- public-release:end -->"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def asset_url(metadata, asset):
    return f"{REPO}/releases/download/{metadata['tag']}/{asset['name']}"


def validate_schema(m):
    require(set(m) == {
        "schemaVersion", "version", "channel", "tag", "releaseUrl",
        "signatureStatus", "runtime", "supportedScope", "limitationsUrl",
        "installationUrl", "updateCapability", "manifest", "assets",
    }, "Unknown or missing metadata fields")
    require(type(m["schemaVersion"]) is int and m["schemaVersion"] == 1, "Schema version")
    require(isinstance(m["version"], str) and re.fullmatch(
        r"\d+\.\d+\.\d+(?:-(?:preview|rc)\.\d+)?", m["version"]), "Public version")
    require(m["channel"] in ("preview", "stable"), "Public channel")
    require((m["channel"] == "stable") == ("-" not in m["version"]), "Version/channel mismatch")
    require(m["tag"] == "v" + m["version"], "Stale version/tag")
    require(m["releaseUrl"] == f"{REPO}/releases/tag/{m['tag']}", "Exact release URL")
    # Signed stable publication needs a separate reviewed schema/policy change.
    require(m["signatureStatus"] == "unsigned", "No signed public release is implemented")
    require(m["manifest"]["signing"] == "unsigned-" + m["channel"], "Manifest signing")
    require(set(m["manifest"]) == {"path", "sha256", "sourceRevision", "signing"}, "Manifest fields")
    require(m["manifest"]["path"] == "release.json", "Manifest path")
    require(re.fullmatch(r"[0-9a-f]{40}", m["manifest"]["sourceRevision"]), "Source revision")
    require(set(m["runtime"]) == {
        "name", "architecture", "minimumVersion", "downloadUrl"}, "Runtime fields")
    require(m["runtime"]["name"] == "Microsoft Visual C++ x64 Redistributable", "Runtime name")
    require(m["runtime"]["architecture"] == "x64", "Runtime architecture")
    require(re.fullmatch(r"\d+\.\d+\.\d+\.\d+", m["runtime"]["minimumVersion"]), "Runtime version")
    require(m["runtime"]["downloadUrl"] == "https://aka.ms/vc14/vc_redist.x64.exe", "Runtime URL")
    for field in ("limitationsUrl", "installationUrl"):
        name = "KNOWN-LIMITATIONS.md" if field == "limitationsUrl" else "INSTALL-RELEASE.md"
        require(m[field] == f"{REPO}/blob/{m['tag']}/windows/docs/{name}", field)
    for field in ("supportedScope", "updateCapability"):
        require(isinstance(m[field], str) and len(m[field]) > 30, field)
    require("Windows 11 x64" in m["supportedScope"], "Supported platform")
    require(m["updateCapability"].startswith("Manual installation only."), "Manual install scope")
    expected = {
        "application": (f"caelestia-windows-{m['version']}-windows-x64.zip", "x64"),
        "project-source": (f"caelestia-windows-{m['version']}-project-source.zip", "source"),
        "supplier-source": (f"caelestia-windows-{m['version']}-supplier-source.zip", "source"),
        "manifest-digest": (f"caelestia-windows-{m['version']}.manifest.sha256", "metadata"),
        "checksums": ("SHA256SUMS.txt", "metadata"),
    }
    require(isinstance(m["assets"], list) and len(m["assets"]) == len(expected), "Missing asset")
    require({a["kind"] for a in m["assets"]} == set(expected), "Missing/duplicate asset kind")
    for a in m["assets"]:
        require(set(a) == {"kind", "architecture", "name", "sha256"}, "Asset fields")
        require((a["name"], a["architecture"]) == expected[a["kind"]], "Asset name/architecture")
    for entry in [m["manifest"], *m["assets"]]:
        require(isinstance(entry["sha256"], str) and re.fullmatch(
            r"[0-9a-f]{64}", entry["sha256"]), "SHA256 format")


def markdown(m):
    lines = [
        START,
        f"Recommended public release: [{m['version']}]({m['releaseUrl']}).",
        f"Channel: {m['channel']}. Signature status: {m['signatureStatus']}.",
        "",
        m["supportedScope"],
        f"[Known limitations]({m['limitationsUrl']}).",
        "",
        f"Runtime: [{m['runtime']['name']}]({m['runtime']['downloadUrl']}), "
        f"{m['runtime']['minimumVersion']} or newer. Install separately if needed.",
        "",
        "| Asset | Architecture | SHA256 |",
        "| --- | --- | --- |",
    ]
    for a in m["assets"]:
        lines.append(f"| [{a['name']}]({asset_url(m, a)}) | {a['architecture']} | `{a['sha256']}` |")
    lines.extend([
        "",
        f"Qualified `release.json` SHA256: `{m['manifest']['sha256']}`.",
        f"Qualified source revision: `{m['manifest']['sourceRevision']}`.",
        "Checksums detect changes, not publisher identity. No release is signed today.",
        m["updateCapability"],
        END,
    ])
    return "\n".join(lines)


def check_docs(m, root):
    doc = (root / "windows/release/PUBLIC-RELEASE.md").read_text(encoding="utf-8")
    require(doc.count(START) == doc.count(END) == 1, "Release summary markers")
    require(doc.split(START)[1].split(END)[0] == markdown(m).split(START)[1].split(END)[0],
            "Release summary is stale or has a wrong digest")
    # Other guides refer to the single checked table instead of duplicating hashes.
    for name in DOCS:
        text = (root / name).read_text(encoding="utf-8")
        require("release/PUBLIC-RELEASE.md" in text, f"{name}: missing release summary")
        for version in re.findall(r"v?(\d+\.\d+\.\d+-(?:preview|rc)\.\d+)", text):
            require(version == m["version"], f"{name}: stale public version {version}")
        for tag in re.findall(r"/releases/(?:tag|download)/(v[^/\s)]+)", text):
            require(tag == m["tag"], f"{name}: stale download tag {tag}")
        for runtime in re.findall(r"\b14\.\d+\.\d+\.\d+\b", text):
            require(runtime == m["runtime"]["minimumVersion"], f"{name}: stale runtime")
        require("/releases/latest" not in text, f"{name}: latest excludes intended prerelease")
    install = (root / "windows/docs/INSTALL-RELEASE.md").read_text(encoding="utf-8")
    require("Preview 2 has no automatic updater" in install, "Installation/update distinction")


def site_fragment(m):
    """Static HTML generated before deployment, not a runtime fetch or updater."""
    app = next(a for a in m["assets"] if a["kind"] == "application")
    sums = next(a for a in m["assets"] if a["kind"] == "checksums")
    e = html.escape
    return (
        f'<a class="btn pri" href="{e(asset_url(m, app))}">Download Windows x64 {e(m["version"])}</a>'
        f'<p data-public-release="{e(m["version"])}" style="overflow-wrap:anywhere">Channel: {e(m["channel"])}. '
        f'Signature status: {e(m["signatureStatus"])}. {e(m["supportedScope"])} '
        f'Runtime: <a href="{e(m["runtime"]["downloadUrl"])}">{e(m["runtime"]["name"])}</a>, '
        f'{e(m["runtime"]["minimumVersion"])} or newer. Install separately if needed. '
        f'<a href="{e(asset_url(m, sums))}">SHA256SUMS.txt</a>. '
        f'ZIP SHA256: <code>{app["sha256"]}</code>. '
        f'Manifest SHA256: <code>{m["manifest"]["sha256"]}</code>. '
        f'<a href="{e(m["limitationsUrl"])}">Known limitations</a>. '
        f'<a href="{e(m["installationUrl"])}">Installation guide</a>. '
        f'{e(m["updateCapability"])}</p>'
    )


def site_patch(m):
    fragment = site_fragment(m).replace("`", "\\`").replace("${", "\\${")
    # Context comes from origin/gh-pages:index.html. git apply --check fails
    # on drift instead of replacing an unrelated page or publishing partial data.
    return (
        "diff --git a/index.html b/index.html\n"
        "--- a/index.html\n+++ b/index.html\n"
        "@@ -1292,3 +1292,3 @@\n"
        '     const ext = (href, text) => `<a href="${href}" target="_blank" rel="noopener">${text}<span class="sr"> (opens in a new tab)</span></a>`;\n'
        '-    const download = RELEASED ? `<a class="btn pri" href="${REPO}/releases">Download Windows preview</a>` : `<span class="btn pri off">First release coming soon</span>`;\n'
        f"+    const download = `{fragment}`;\n"
        '     const edge = (k, cls) => { const [, , name, text] = EDGES[k]; return `<button class="el el-${cls}" data-k="${k}" aria-pressed="false"><b>${name}</b><span>${text}</span></button>`; };\n'
        "@@ -1352,5 +1352,5 @@\n"
        '           <li class="step"><div class="sn" data-in="350" style="--i:0;--rot:140s">${shapeSvg("cookie9")}<span aria-hidden="true">1</span></div>\n'
        '-            <h3><span class="sr">Step 1: </span>Download</h3><p>Get the latest release from GitHub and unzip it.</p>${download}</li>\n'
        '+            <h3><span class="sr">Step 1: </span>Download</h3><p>Download the recommended x64 preview, check its SHA256, then extract the whole ZIP.</p>${download}</li>\n'
        '           <li class="step"><div class="sn" data-in="500" style="--i:1;--rot:120s">${shapeSvg("flower")}<span aria-hidden="true">2</span></div>\n'
        '-            <h3><span class="sr">Step 2: </span>Run the installer</h3><p>Open PowerShell in that folder and run:</p>\n'
        '+            <h3><span class="sr">Step 2: </span>Run the installer</h3><p>Install the Microsoft runtime prerequisite if needed. Then open PowerShell in the extracted folder and run:</p>\n'
        '             <div class="cmd"><code>${INSTALL_CMD.split(" ").map(w => `<span>${esc(w)}</span>`).join(" ")}</code><button class="cpy" aria-live="polite">Copy</button></div></li>\n'
    )


def check_site(m, text):
    fragment = site_fragment(m).replace("`", "\\`").replace("${", "\\${")
    require(fragment in text, "Site release block differs from reviewed metadata")
    require("Get the latest release" not in text and "${REPO}/releases\"" not in text,
            "Site has an unqualified download action")


def check_site_patch(m, ref):
    """Apply only to a disposable copy of the fetched Pages HTML."""
    page = subprocess.run(["git", "show", f"{ref}:index.html"], cwd=ROOT,
                          check=True, capture_output=True).stdout
    scratch = Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir()))
    if os.name == "nt":
        scratch /= "Temp"
    patch = ROOT / "windows/release/gh-pages-release.patch"
    with tempfile.TemporaryDirectory(prefix="caelestia-pages-fixture-", dir=scratch) as temporary:
        directory = Path(temporary)
        index = directory / "index.html"
        index.write_bytes(page)
        for arguments in (["--check"], []):
            subprocess.run(["git", "apply", *arguments, str(patch)],
                           cwd=directory, check=True)
        check_site(m, index.read_text(encoding="utf-8"))
    print(f"PASS site patch applies cleanly to {ref}, HTML values agree")


def request(url, method="GET"):
    # Deliberately no gh token, Authorization header or authenticated opener.
    req = urllib.request.Request(url, method=method, headers={"User-Agent": "caelestia-release-verifier"})
    return urllib.request.urlopen(req, timeout=60)


def read_url(url):
    with request(url) as response:
        require(response.status == 200, f"Anonymous GET failed: {url}")
        return response.read()


def check_manifest(m, raw):
    require(hashlib.sha256(raw).hexdigest() == m["manifest"]["sha256"], "Qualified manifest digest")
    receipt = json.loads(raw)
    require(receipt["schema"] == "caelestia-windows-release" and receipt["version"] == 1, "Receipt schema")
    for key, expected in {
        "releaseId": m["version"], "platform": "windows-x64",
        "sourceRevision": m["manifest"]["sourceRevision"], "signing": m["manifest"]["signing"],
    }.items():
        require(receipt[key] == expected, f"Qualified receipt mismatch: {key}")
    runtime = receipt["prerequisites"]["visualCppRuntime"]
    for key in ("architecture", "minimumVersion", "downloadUrl"):
        require(runtime[key] == m["runtime"][key], f"Qualified runtime mismatch: {key}")
    require(runtime["deployment"] == "system", "Runtime must not be bundled")


def check_online(m):
    api = "https://api.github.com/repos/KldsSeeGhosts/caelestia-windows/releases/tags/" + m["tag"]
    release = json.loads(read_url(api))
    require(not release["draft"] and release["tag_name"] == m["tag"], "Public release identity")
    require(release["html_url"] == m["releaseUrl"], "Release URL mismatch")
    require(release["prerelease"] == (m["channel"] == "preview"), "Live release channel")
    live = {a["name"]: a for a in release["assets"]}
    for a in m["assets"]:
        require(a["name"] in live, f"Live missing asset: {a['name']}")
        require(live[a["name"]]["digest"] == "sha256:" + a["sha256"], f"Live wrong digest: {a['name']}")
        require(live[a["name"]]["browser_download_url"] == asset_url(m, a), "Live asset URL")
        with request(asset_url(m, a), "HEAD") as response:
            require(response.status == 200, f"Asset is not anonymously available: {a['name']}")
    downloaded = {}
    for a in m["assets"]:
        if a["kind"] not in ("checksums", "manifest-digest"):
            continue
        raw = read_url(asset_url(m, a))
        require(hashlib.sha256(raw).hexdigest() == a["sha256"], "Sidecar digest")
        downloaded[a["kind"]] = raw.decode("ascii").strip()
    sums = dict((name, digest) for digest, name in
                (line.split() for line in downloaded["checksums"].splitlines()))
    for a in m["assets"]:
        if a["kind"] in ("application", "project-source", "supplier-source"):
            require(sums.get(a["name"]) == a["sha256"], f"SHA256SUMS mismatch: {a['name']}")
    require(downloaded["manifest-digest"].split() == [m["manifest"]["sha256"], "release.json"],
            "Manifest sidecar mismatch")
    app = next(a for a in m["assets"] if a["kind"] == "application")
    scratch = Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir()))
    if os.name == "nt":
        scratch /= "Temp"
    with tempfile.TemporaryDirectory(prefix="caelestia-public-release-", dir=scratch) as temporary:
        bundle = Path(temporary) / "application.zip"
        digest = hashlib.sha256()
        with request(asset_url(m, app)) as source, bundle.open("wb") as target:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
                target.write(chunk)
        require(digest.hexdigest() == app["sha256"], "Downloaded ZIP digest")
        with zipfile.ZipFile(bundle) as archive:
            names = [n for n in archive.namelist() if n.replace("\\", "/").endswith("/release.json")]
            require(len(names) == 1, "Exactly one bundle manifest required")
            check_manifest(m, archive.read(names[0]))
    for url in (m["releaseUrl"], m["limitationsUrl"], m["installationUrl"], m["runtime"]["downloadUrl"]):
        with request(url, "HEAD") as response:
            require(response.status == 200, f"Broken public link: {url}")
    print("PASS anonymous release links, asset availability/digests, sidecars and downloaded qualified manifest")


class Fixtures(unittest.TestCase):
    def setUp(self):
        self.metadata = json.loads((ROOT / "windows/release/public-release.json").read_text())

    def test_missing_asset(self):
        self.metadata["assets"].pop(0)
        with self.assertRaisesRegex(ValueError, "Missing asset"):
            validate_schema(self.metadata)

    def test_stale_version(self):
        self.metadata["version"] = "0.1.0-preview.1"
        with self.assertRaisesRegex(ValueError, "Stale version"):
            validate_schema(self.metadata)

    def test_wrong_digest(self):
        self.metadata["assets"][0]["sha256"] = "0" * 64
        validate_schema(self.metadata)  # Well-formed but wrong must still fail.
        with self.assertRaisesRegex(ValueError, "wrong digest"):
            check_docs(self.metadata, ROOT)

    def test_wrong_manifest_digest(self):
        self.metadata["manifest"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "wrong digest"):
            check_docs(self.metadata, ROOT)

    def test_stale_site(self):
        with self.assertRaisesRegex(ValueError, "Site release block"):
            check_site(self.metadata, site_fragment(self.metadata).replace("preview.2", "preview.1"))

    def test_qualified_receipt_mismatch(self):
        m = self.metadata
        receipt = {
            "schema": "caelestia-windows-release", "version": 1,
            "releaseId": m["version"], "platform": "windows-x64",
            "sourceRevision": m["manifest"]["sourceRevision"], "signing": m["manifest"]["signing"],
            "prerequisites": {"visualCppRuntime": {**m["runtime"], "deployment": "system"}},
        }
        raw = json.dumps(receipt).encode()
        m["manifest"]["sha256"] = hashlib.sha256(raw).hexdigest()
        check_manifest(m, raw)
        wrong = copy.deepcopy(m)
        wrong["runtime"]["minimumVersion"] = "14.99.99999.0"
        with self.assertRaisesRegex(ValueError, "Qualified runtime mismatch"):
            check_manifest(wrong, raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, default=ROOT / "windows/release/public-release.json")
    parser.add_argument("--online", action="store_true", help="Anonymous read-only post-publication verification")
    parser.add_argument("--site-root", type=Path, help="Check patched gh-pages staging directory")
    parser.add_argument("--site-ref", help="Test patch against an already fetched Pages Git ref in scratch")
    parser.add_argument("--site-url", help="Check deployed HTML and its metadata copy anonymously")
    args = parser.parse_args()
    m = json.loads(args.metadata.read_text(encoding="utf-8"))
    validate_schema(m)
    check_docs(m, ROOT)
    require((ROOT / "windows/release/gh-pages-release.patch").read_text(encoding="utf-8") == site_patch(m),
            "Site patch differs from metadata")
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Fixtures)
    require(unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful(), "Negative fixtures failed")
    if args.site_root:
        check_site(m, (args.site_root / "index.html").read_text(encoding="utf-8"))
        require(json.loads((args.site_root / "public-release.json").read_text()) == m, "Site metadata copy")
    if args.site_ref:
        check_site_patch(m, args.site_ref)
    if args.site_url:
        require(args.online, "--site-url requires --online")
        base = args.site_url.rstrip("/") + "/"
        require(base.startswith("https://"), "Site must use HTTPS")
        check_site(m, read_url(urllib.parse.urljoin(base, "index.html")).decode("utf-8"))
        require(json.loads(read_url(urllib.parse.urljoin(base, "public-release.json"))) == m,
                "Deployed site metadata mismatch")
    if args.online:
        check_online(m)
    print("PASS public release metadata, documentation, site patch and negative fixtures")


if __name__ == "__main__":
    main()
