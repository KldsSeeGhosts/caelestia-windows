"""Stream verified LLVM tools/resources without Windows' inbox tar.exe."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import stat
import tarfile
import time

NATIVE_PROFILE = "windows-native-v1"
NATIVE_BINARIES = (
    "clang-cl.exe", "clang-scan-deps.exe", "lld-link.exe",
    "llvm-ar.exe", "llvm-lib.exe", "llvm-ranlib.exe", "llvm-nm.exe",
    "llvm-rc.exe", "llvm-mt.exe",
)
PROFILES = ("full", NATIVE_PROFILE)


def safe_name(name):
    name = name.rstrip("/")
    if (not name or name.startswith("/") or "\\" in name or ":" in name
            or any(p in ("", ".", "..") for p in name.split("/"))
            or any(p.endswith((".", " ")) or re.fullmatch(
                r"(?i)(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\..*)?", p)
                   for p in name.split("/"))
            or any(ord(c) < 32 or c in '*?"<>|' for c in name)):
        raise ValueError("unsafe-archive-path")
    return name


def local_path(root, name):
    path = root.joinpath(*safe_name(name).split("/"))
    for parent in (path, *path.parents):
        if parent.exists() or parent.is_symlink():
            attributes = parent.lstat()
            if (stat.S_ISLNK(attributes.st_mode)
                    or getattr(attributes, "st_file_attributes", 0)
                    & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)):
                raise ValueError("linked-destination")
        if parent == root:
            break
    return path


def contract(directory, expected_hash, major, profile):
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+._-]+", directory)
            or not re.fullmatch(r"[a-f0-9]{64}", expected_hash)
            or not re.fullmatch(r"[0-9]+", major) or profile not in PROFILES):
        raise ValueError("invalid-extraction-contract")
    safe_name(directory)


def selected(name, prefix, profile):
    if name.startswith(prefix + "lib/clang/"):
        return True
    return (name.startswith(prefix + "bin/") if profile == "full"
            else name.casefold() in {(prefix + "bin/" + leaf).casefold() for leaf in NATIVE_BINARIES})


def required(major, profile):
    names = NATIVE_BINARIES if profile == NATIVE_PROFILE else ("clang-cl.exe", "lld-link.exe", "llvm-rc.exe")
    return tuple("bin/" + name for name in names) + (f"lib/clang/{major}/include/stddef.h",)


def marker_data(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def native_tree(destination, directory):
    """Never prune an existing SDK or treat non-profile files as a small tree."""
    root = local_path(destination, directory)
    marker = local_path(destination, directory + "/.caelestia-extraction.json")
    record = marker_data(marker)
    if marker.exists() and (record.get("schemaVersion") != 2 or record.get("profile") != NATIVE_PROFILE):
        raise ValueError("llvm-profile-mismatch-use-fresh-root")
    if root.exists():
        for path in root.rglob("*"):
            relative = path.relative_to(destination).as_posix()
            local_path(destination, relative)
            if path.is_file() and relative not in (
                    directory + "/.caelestia-extraction.json", directory + "/.caelestia-extraction.tmp"
            ) and not selected(relative, directory + "/", NATIVE_PROFILE):
                raise ValueError("non-profile-file-use-fresh-root")


def verify_tree(destination, directory, expected_hash, major, profile="full"):
    """Readiness only. The caller must separately verify the pinned archive."""
    contract(directory, expected_hash, major, profile)
    destination = Path(destination).absolute()
    marker = local_path(destination, directory + "/.caelestia-extraction.json")
    if profile == NATIVE_PROFILE:
        native_tree(destination, directory)
    record = marker_data(marker)
    valid_profile = (record.get("schemaVersion") == 1 and profile == "full"
                     or record.get("schemaVersion") == 2 and record.get("profile") == profile)
    return (valid_profile and record.get("archiveSha256") == expected_hash
            and record.get("directory") == directory
            and all(local_path(destination, directory + "/" + name).is_file()
                    for name in required(major, profile)))


def extract(archive, destination, directory, expected_hash, major, timeout=900, profile="full"):
    contract(directory, expected_hash, major, profile)
    destination = Path(destination).absolute()
    destination.mkdir(parents=True, exist_ok=True)
    prefix = directory + "/"
    marker = local_path(destination, prefix + ".caelestia-extraction.json")
    if profile == NATIVE_PROFILE:
        native_tree(destination, directory)
    # A failed retry must never retain an earlier success marker.
    if marker.exists():
        marker.unlink()
    started = time.monotonic()
    with open(archive, "rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != expected_hash:
            raise ValueError("archive-checksum-mismatch")
    print("LLVM archive reverified; streaming tools and compiler resources.", flush=True)
    seen = set()
    links = {}
    files = 0
    total_bytes = 0
    last_progress = started

    def check_time():
        if time.monotonic() - started > timeout:
            raise TimeoutError("extraction-deadline")

    # Streaming avoids backwards XZ seeks and skips unneeded SDK payloads.
    with tarfile.open(archive, "r|*", bufsize=1024 * 1024) as bundle:
        for member in bundle:
            check_time()
            name = safe_name(member.name)
            if not (selected(name, prefix, profile)
                    or name in (prefix + "bin", prefix + "lib/clang")):
                continue
            path = local_path(destination, name)
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
                continue
            key = name.casefold()
            if key in seen:
                raise ValueError("duplicate-selected-member")
            seen.add(key)
            path.parent.mkdir(parents=True, exist_ok=True)
            if member.islnk() or member.issym():
                target = (posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
                          if member.issym() else member.linkname)
                target = safe_name(target)
                if not selected(target, prefix, profile):
                    raise ValueError("link-outside-selected-tree")
                links[name] = target
                continue
            if not member.isfile() or member.size < 0:
                raise ValueError("unsupported-selected-member")
            source = bundle.extractfile(member)
            if source is None:
                raise ValueError("missing-member-data")
            with source, open(path, "wb") as output:
                while chunk := source.read(1024 * 1024):
                    check_time()
                    output.write(chunk)
                    total_bytes += len(chunk)
            if path.stat().st_size != member.size:
                raise ValueError("truncated-member")
            files += 1
            if time.monotonic() - last_progress >= 15:
                print(f"LLVM extraction: {files} files, {total_bytes} bytes.", flush=True)
                last_progress = time.monotonic()
    while links:
        check_time()
        progressed = False
        for name, target in list(links.items()):
            # Never resolve a link from stale files left by an earlier attempt.
            if target.casefold() not in seen or target.casefold() in {n.casefold() for n in links}:
                continue
            source = local_path(destination, target)
            path = local_path(destination, name)
            if not source.is_file():
                continue
            if path.exists():
                path.unlink()
            try:
                os.link(source, path)
            except OSError:
                shutil.copyfile(source, path)
            del links[name]
            files += 1
            progressed = True
        if not progressed:
            raise ValueError("unresolved-selected-link")
    # A stale on-disk file cannot stand in for an omitted archive member.
    if any((prefix + name).casefold() not in seen
           or not local_path(destination, prefix + name).is_file() for name in required(major, profile)):
        raise ValueError("incomplete-compiler-tree")
    result = {"schemaVersion": 2, "profile": profile, "archiveSha256": expected_hash,
              "directory": directory, "files": files, "bytes": total_bytes,
              "seconds": round(time.monotonic() - started, 3)}
    temporary = local_path(destination, prefix + ".caelestia-extraction.tmp")
    temporary.write_text(json.dumps(result) + "\n", encoding="utf-8")
    os.replace(temporary, marker)
    print(f"LLVM extraction complete: {files} files in {result['seconds']}s.", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("archive", "destination", "directory", "sha256", "clang-major"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--profile", choices=PROFILES, default="full")
    parser.add_argument("--verify-tree", action="store_true")
    args = parser.parse_args()
    try:
        if args.verify_tree:
            return 0 if verify_tree(args.destination, args.directory, args.sha256,
                                    args.clang_major, args.profile) else 2
        extract(args.archive, args.destination, args.directory, args.sha256,
                args.clang_major, profile=args.profile)
    except (OSError, ValueError, tarfile.TarError, TimeoutError):
        print("Verified LLVM extraction failed; no completion marker was written.", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
