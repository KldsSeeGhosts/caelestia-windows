"""Refresh the bounded Qt source/notice data from verified supplier archives.

No Qt program is executed. Inputs are the two hash-pinned public reference ZIPs,
six official source tarballs and the SDK prepared by Prepare-Toolchain.ps1.
The output is review data, not permission to publish or live-desktop evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_zip(archive, suffix):
    matches = [n for n in archive.namelist()
               if n.replace("\\", "/").endswith("/" + suffix)]
    if len(matches) != 1:
        raise ValueError(f"Expected one reference member: {suffix}")
    return archive.read(matches[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-directory", type=Path, required=True)
    parser.add_argument("--qt-prefix", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    recipe = json.loads((root / "windows/release/source-assets.json").read_text())
    spec = json.loads((root / "windows/toolchain.json").read_text())
    version = spec["qtVersion"]
    old_version = recipe["qtServicing"]["referenceVersion"]
    pins = recipe["qtServicing"]["archives"]
    for name, key in (("supplier.zip", "supplier"), ("application.zip", "application")):
        if digest((args.reference_directory / name).read_bytes()) != recipe["referenceAssets"][key]["sha256"]:
            raise ValueError(f"Unverified public reference: {name}")
    with zipfile.ZipFile(args.reference_directory / "supplier.zip") as supplier, \
            zipfile.ZipFile(args.reference_directory / "application.zip") as application:
        reference = json.loads(read_zip(supplier, "SOURCE-MANIFEST.json"))
        app = json.loads(read_zip(application, "release.json"))
        records, notices, archives = [], [], []
        for pin in pins:
            archive = args.reference_directory / Path(pin["path"]).name
            if digest(archive.read_bytes()) != pin["sha256"]:
                raise ValueError(f"Unverified Qt source: {archive.name}")
            previous = pin["path"].replace(version, old_version)
            old = next(a for a in reference["archives"] if a["path"] == previous)
            archives.append({**old, **pin, "bytes": archive.stat().st_size})
            entries = [e for e in reference["noticeProvenance"] if e.get("sourceArchive") == previous]
            needed = {e["sourceMember"].replace(old_version, version) for e in entries}
            # Read only recorded notice members, never extract arbitrary tar paths.
            with tarfile.open(archive, "r|xz") as tar:
                members = {e.name: tar.extractfile(e).read() for e in tar
                           if e.isfile() and e.name in needed}
            if members.keys() != needed:
                raise ValueError("Qt notice member set changed and requires review")
            for entry in entries:
                member = entry["sourceMember"].replace(old_version, version)
                data = members[member]
                notice_path = entry["originalNotice"][8:].replace(old_version, version)
                text = None
                if entry["derivation"] == "literal supplier Name, LicenseId and Copyright fields; labeled index":
                    # Qt's attribution scanner accepts literal newlines in
                    # some Copyright fields. Preserve those supplier bytes.
                    attribution = json.loads(data, strict=False)
                    items = attribution if isinstance(attribution, list) else [attribution]
                    identifier = Path(notice_path).stem
                    matching = [a for a in items if a["Id"] == identifier]
                    if len(matching) != 1:
                        raise ValueError(f"Unknown attribution: {notice_path}")
                    item = matching[0]
                    copyright_text = item.get("Copyright", "[No Copyright field in supplier attribution]")
                    text = (f'{item["Name"]}\nLicense identifier: {item["LicenseId"]}\n'
                            f'Copyright (verbatim supplier field when present):\n{copyright_text}\n'
                            f'Supplier attribution: {member.split("/", 1)[1]}\n')
                    data = text.encode()
                elif entry["derivation"] != "verbatim bytes from supplier archive":
                    raise ValueError("Unknown notice derivation")
                elif notice_path.endswith(("/sqlite3.c", "/sqlite3.h")):
                    # Preserve the supplier's complete opening blessing comment.
                    source = data.decode("utf-8")
                    comments = [s for s in re.findall(r"/\*.*?\*/", source, re.S)
                                if "May you do good and not evil." in s]
                    if not comments:
                        raise ValueError("SQLite blessing requires review")
                    comment = comments[0]
                    text = (f"SQLite, bundled with Qt {version}\n\n"
                            f"Verbatim opening notice from {member}.\n"
                            "The complete source archive is supplied alongside the release.\n\n"
                            f"{comment}\n")
                    notice_path += ".LICENSE.txt"
                    data = text.encode()
                record = {**entry, "originalNotice": "notices/" + notice_path,
                          "sourceArchive": pin["path"], "sourceUrl": pin["url"],
                          "sourceMember": member, "sourceMemberSha256": digest(members[member]),
                          "sha256": digest(data)}
                if text is not None:
                    record["derivation"] = ("verbatim opening SQLite blessing" if "sqlite3." in notice_path
                                            else entry["derivation"])
                records.append(record)
                notice = {"path": notice_path, "sha256": digest(data)}
                if text is not None:
                    notice["text"] = text
                notices.append(notice)
        # These two explanatory notices are first-party prose, not supplier text.
        for name in ("README.txt", "NOTICE-PROVENANCE.md"):
            text = read_zip(application, "payload/licenses/supplemental/" + name).decode()
            text = text.replace(old_version, version)
            notices.append({"path": name, "sha256": digest(text.encode()), "text": text})
        payload = []
        for item in app["files"]:
            path = item["path"]
            # Preserve the original exact file allowlist, refreshed against the new SDK.
            is_qt = (path.startswith(("payload/Qt6", "payload/plugins/", "payload/licenses/Qt/",
                                     "payload/licenses/Qt-sbom/"))
                     or (path.startswith("payload/qml/") and
                         not path.startswith(("payload/qml/Caelestia/", "payload/qml/Quickshell/",
                                              "payload/qml/M3Shapes/"))))
            if not is_qt:
                continue
            new_path = path.replace(old_version, version)
            relative = new_path.removeprefix("payload/")
            if relative.startswith("licenses/Qt-sbom/"):
                source = args.qt_prefix / "sbom" / Path(relative).name
            elif relative.startswith("licenses/Qt/"):
                # Standard GPL/LGPL texts come from the pinned backend.
                name = Path(relative).name
                if relative in ("licenses/Qt/LGPL-3.0.txt", "licenses/Qt/GPL-3.0.txt"):
                    source = root / "windows/deps/quickshell" / {
                        "LGPL-3.0.txt": "LICENSE", "GPL-3.0.txt": "LICENSE-GPL"}[name]
                else:
                    source = args.qt_prefix / relative.removeprefix("licenses/Qt/")
            else:
                source = args.qt_prefix / relative
                if not source.is_file():
                    source = args.qt_prefix / "bin" / Path(relative).name
            data = source.read_bytes()
            payload.append({**item, "path": new_path, "sha256": digest(data), "size": len(data)})
        result = {"schema": "caelestia-qt-source-review", "version": 1,
                  "qtVersion": version, "archives": archives,
                  "noticeProvenance": records, "supplementalNotices": notices,
                  "payloadFiles": payload}
        args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                               encoding="utf-8", newline="\n")
        print(f"Reviewed Qt data: {len(archives)} archives, {len(notices)} notices, {len(payload)} payload files")


if __name__ == "__main__":
    main()
