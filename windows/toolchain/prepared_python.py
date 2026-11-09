"""Verify a prepared Python tool environment before running any cached code."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import sys


MARKER = ".caelestia-prepared-python.json"
ROOT = Path(__file__).resolve().parents[2]
INPUTS = (
    "windows/toolchain.json",
    "windows/toolchain/python-bootstrap.lock.txt",
    "windows/toolchain/python-tools.lock.txt",
    "windows/toolchain/prepared_python.py",
    "windows/scripts/Prepare-Toolchain.ps1",
)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def contract_digest():
    result = hashlib.sha256()
    for name in INPUTS:
        result.update(name.encode("utf-8") + b"\0")
        result.update((ROOT / name).read_bytes())
    return result.hexdigest()


def python_identity():
    executable = Path(sys.executable).resolve()
    return {
        "version": sys.version,
        "architecture": struct.calcsize("P") * 8,
        "executable": str(executable),
        "executableSha256": digest(executable),
        "basePrefix": sys.base_prefix,
    }


def identity_digest():
    return hashlib.sha256(json.dumps(python_identity(), sort_keys=True).encode("utf-8")).hexdigest()


def reject_link(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError("prepared Python environment contains a filesystem link")


def inventory(environment):
    reject_link(environment)
    files = []
    for current, directories, names in os.walk(environment, followlinks=False):
        for name in directories:
            reject_link(Path(current) / name)
        for name in names:
            path = Path(current) / name
            reject_link(path)
            relative = path.relative_to(environment).as_posix()
            if relative == MARKER:
                continue
            if not path.is_file():
                raise ValueError("prepared Python environment contains a non-file")
            files.append({"path": relative, "sha256": digest(path)})
    return sorted(files, key=lambda row: row["path"])


def expected(environment):
    return {
        "schemaVersion": 1,
        "inputsSha256": contract_digest(),
        "python": python_identity(),
        "environment": str(environment.absolute()),
    }


def record(environment):
    for name in ("pyvenv.cfg", "Scripts/python.exe", "Scripts/cmake.exe", "Scripts/ninja.exe"):
        if not (environment / name).is_file():
            raise ValueError("prepared Python environment is incomplete")
    value = {**expected(environment), "files": inventory(environment)}
    temporary = environment / (MARKER + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(environment / MARKER)


def verify(environment):
    try:
        environment.lstat()
    except FileNotFoundError:
        return "miss"
    # A restored but incomplete or modified environment must not execute pip
    # or any other cached program. Fail rather than accepting a version string.
    reject_link(environment)
    marker = environment / MARKER
    reject_link(marker)
    value = json.loads(marker.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or set(value) != {*expected(environment), "files"}:
        raise ValueError("prepared Python manifest is invalid")
    if value != {**expected(environment), "files": inventory(environment)}:
        raise ValueError("prepared Python input, interpreter or file inventory mismatch")
    return "hit"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("identity", "record", "verify"))
    parser.add_argument("--environment", type=Path)
    args = parser.parse_args()
    if args.action != "identity" and args.environment is None:
        parser.error("--environment is required for record and verify")
    try:
        if args.action == "identity":
            print(identity_digest())
        elif args.action == "record":
            record(args.environment)
        else:
            print(verify(args.environment))
    except (OSError, ValueError, TypeError):
        print("Prepared Python verification failed. Use a fresh tool environment; do not bypass verification.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
