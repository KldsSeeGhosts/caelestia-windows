#!/usr/bin/env python3
"""Classify clang-cl diagnostics and maintain the reviewed warning baseline.

The build writes one log per component under ``<BuildRoot>/logs``.  This tool
accepts one or more log files, or a logs directory, and normalizes every
reported location before grouping it.  Repeated output stays visible as a raw
line count; the baseline stores unique (file, line, flag) diagnostics.

Generate the baseline from a full native build:

    python windows/tools/warning_baseline.py --log <build>/logs --build-root <build>

Check a build log without changing the baseline:

    python windows/tools/warning_baseline.py --check <build>/logs --build-root <build>

Only the shell plugin is owned code.  The other groups are imported or
generated inputs; their diagnostics are recorded as counts, not as a list of
allowed warnings, so a new owned warning cannot hide in them.
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import sys
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path

SCHEMA_VERSION = 1
DEFAULT_BASELINE = Path("windows/ci/warning-baseline.json")
COMPONENTS = ("shell-plugin", "m3shapes", "backend", "qt-headers", "other-third-party")
OWNED_COMPONENT = "shell-plugin"
NO_FLAG = "(no flag)"

# Clang-cl normally emits ``path(line,column): warning: message [-Wflag]``.
# GCC-style locations appear in a few third-party build rules; accept both.
MSVC_WARNING_RE = re.compile(
    r"^(?P<file>.+)\((?P<line>[0-9]+)(?:,(?P<column>[0-9]+))?\)\s*:\s*"
    r"warning\s*:\s*(?P<message>.*)$"
)
GCC_WARNING_RE = re.compile(
    r"^(?P<file>.+?):(?P<line>[0-9]+)(?::(?P<column>[0-9]+))?:\s*"
    r"warning\s*:\s*(?P<message>.*)$"
)
FLAG_RE = re.compile(r"\[(-W[^\]]*)\]\s*$")

# Stable order for a logs directory; the compiler output for these components
# is what the baseline describes.  Unknown logs follow in name order.
LOG_ORDER = (
    "configure-m3shapes",
    "build-m3shapes",
    "install-m3shapes",
    "configure-plugins",
    "build-plugins",
    "install-plugins",
    "configure-backend",
    "build-backend",
    "build-brightness-probe",
    "configure-backend-tests",
    "build-backend-tests",
    "build-capture",
)


@dataclass(frozen=True)
class Diagnostic:
    file: str
    line: int
    column: int | None
    flag: str
    message: str
    component: str

    @property
    def key(self) -> tuple[str, int, str]:
        return (self.file, self.line, self.flag)


def _posix(value: object) -> str:
    return posixpath.normpath(str(value).replace("\\", "/"))


def _relative(value: str) -> str:
    value = posixpath.normpath(value)
    return value[2:] if value.startswith("./") else value


def _strip_root(path: str, root: object) -> str | None:
    root_path = _posix(root).rstrip("/")
    if not root_path:
        return None
    if path.casefold() == root_path.casefold():
        return "."
    prefix = root_path.casefold() + "/"
    if path.casefold().startswith(prefix):
        return path[len(root_path) + 1:]
    return None


def normalize_location(raw: str, repo_root: Path, build_root: Path | None) -> str:
    """Return a stable, private location for one compiler path.

    Repository files become repository-relative POSIX paths.  Generated files
    below the build root become ``<build>/...``.  Known dependency roots get a
    short component prefix, and unknown absolute paths keep only their base
    name so personal directories never enter the committed baseline.
    """
    path = _posix(raw)
    if path in ("", "."):
        return "."

    # Resolve ``..`` before stripping roots.  M3Shapes' AUTOMOC files live
    # below the build root but refer back into the repository with long
    # relative prefixes; normalizing first collapses both spellings.
    relative = _strip_root(path, repo_root)
    if relative is not None:
        return _relative(relative)

    if build_root is not None:
        relative = _strip_root(path, build_root)
        if relative is not None:
            return "<build>/" + _relative(relative)

    if not re.match(r"^[A-Za-z]:/", path) and not path.startswith("/"):
        return _relative(path)

    folded = path.casefold()
    for marker in (
        "windows/deps/m3shapes/",
        "windows/deps/quickshell/",
        "plugin/",
    ):
        index = folded.find("/" + marker)
        if index >= 0:
            return _relative(path[index + 1:])

    match = re.search(r"(?:^|/)Qt/([^/]+)/([^/]+)/(.+)$", path, re.IGNORECASE)
    if match:
        return "qt/" + _relative(match.group(3))

    match = re.search(r"(?:^|/)(clang\+llvm-[^/]+)/(.+)$", path, re.IGNORECASE)
    if match:
        return "llvm/" + _relative(match.group(2))

    match = re.search(r"(?:^|/)CLI11-[^/]+/include/(.+)$", path, re.IGNORECASE)
    if match:
        return "cli11/" + _relative(match.group(1))

    match = re.search(r"(?:^|/)VC/Tools/MSVC/[^/]+/(.+)$", path, re.IGNORECASE)
    if match:
        return "msvc/" + _relative(match.group(1))

    match = re.search(r"(?:^|/)Windows Kits/[0-9.]+/Include/[^/]+/(.+)$", path, re.IGNORECASE)
    if match:
        return "winsdk/" + _relative(match.group(1))

    name = posixpath.basename(path)
    return "external/" + (name or "unknown")


def classify(location: str) -> str:
    path = location.casefold()
    if path.startswith("plugin/") and not path.startswith("plugin/3rdparty/"):
        return OWNED_COMPONENT
    if path.startswith("windows/deps/m3shapes/"):
        return "m3shapes"
    if path.startswith("windows/deps/quickshell/"):
        return "backend"
    if path.startswith("qt/"):
        return "qt-headers"
    # Build-tree outputs are generated from the component that owns that tree.
    if path.startswith("<build>/m3shapes"):
        return "m3shapes"
    if path.startswith("<build>/quickshell"):
        return "backend"
    if path.startswith("<build>/caelestia"):
        return OWNED_COMPONENT
    return "other-third-party"


def parse_line(line: str, repo_root: Path, build_root: Path | None) -> Diagnostic | None:
    match = MSVC_WARNING_RE.match(line)
    if match is None:
        match = GCC_WARNING_RE.match(line)
    if match is None:
        return None

    message = match.group("message").strip()
    flag = NO_FLAG
    flag_match = FLAG_RE.search(message)
    if flag_match:
        raw_flag = flag_match.group(1).split(",")[-1]
        flag = raw_flag
        message = message[:flag_match.start()].rstrip()

    location = normalize_location(match.group("file"), repo_root, build_root)
    return Diagnostic(
        file=location,
        line=int(match.group("line")),
        column=int(match.group("column")) if match.group("column") else None,
        flag=flag,
        message=message,
        component=classify(location),
    )


def read_log(path: Path) -> str:
    data = path.read_bytes()
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16")
    if data.startswith(b"\xef\xbb\xbf"):
        return data.decode("utf-8-sig")
    return data.decode("utf-8", errors="replace")


def log_paths(inputs: list[str]) -> list[Path]:
    paths: list[Path] = []
    for item in inputs:
        path = Path(item)
        if path.is_dir():
            ordered = [path / f"{name}.log" for name in LOG_ORDER]
            ordered = [candidate for candidate in ordered if candidate.is_file()]
            known = {candidate.name for candidate in ordered}
            extras = sorted(
                candidate for candidate in path.glob("*.log")
                if candidate.is_file() and candidate.name not in known
            )
            paths.extend(ordered + extras)
        elif path.is_file():
            paths.append(path)
        else:
            raise SystemExit(f"warning-baseline: build log not found: {item}")
    return paths


def parse_logs(inputs: list[str], repo_root: Path, build_root: Path | None) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    for path in log_paths(inputs):
        for line in read_log(path).splitlines():
            diagnostic = parse_line(line, repo_root, build_root)
            if diagnostic is not None:
                diagnostics.append(diagnostic)
    return diagnostics


def unique_diagnostics(diagnostics: list[Diagnostic]) -> OrderedDict[tuple[str, int, str], Diagnostic]:
    unique: OrderedDict[tuple[str, int, str], Diagnostic] = OrderedDict()
    for diagnostic in diagnostics:
        unique.setdefault(diagnostic.key, diagnostic)
    return unique


def read_toolchain(path: Path) -> OrderedDict[str, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except OSError as error:
        raise SystemExit(f"warning-baseline: cannot read toolchain file {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"warning-baseline: invalid toolchain JSON {path}: {error}") from error
    required = ("id", "clangVersion", "clangTarget", "qtVersion")
    missing = [key for key in required if not data.get(key)]
    if missing:
        raise SystemExit(
            f"warning-baseline: {path} is missing toolchain fields: {', '.join(missing)}"
        )
    return OrderedDict([
        ("id", str(data["id"])),
        ("compiler", f"clang-cl {data['clangVersion']} ({data['clangTarget']})"),
        ("qtVersion", str(data["qtVersion"])),
        ("windowsSdkVersion", str(data.get("windowsSdkVersion", ""))),
        ("vcToolsVersion", str(data.get("vcToolsVersion", ""))),
    ])


def build_report(
    diagnostics: list[Diagnostic], toolchain: OrderedDict[str, str]
) -> OrderedDict[str, object]:
    unique = unique_diagnostics(diagnostics)

    components: OrderedDict[str, OrderedDict[str, int]] = OrderedDict(
        (component, OrderedDict([("rawWarningLines", 0), ("uniqueDiagnostics", 0)]))
        for component in COMPONENTS
    )
    flags: dict[str, list[int]] = {}
    for diagnostic in diagnostics:
        components[diagnostic.component]["rawWarningLines"] += 1
        counts = flags.setdefault(diagnostic.flag, [0, 0])
        counts[0] += 1

    for diagnostic in unique.values():
        components[diagnostic.component]["uniqueDiagnostics"] += 1
        flags[diagnostic.flag][1] += 1

    ordered_flags: OrderedDict[str, OrderedDict[str, int]] = OrderedDict()
    for flag, (raw, unique_count) in sorted(
        flags.items(), key=lambda item: (-item[1][0], item[0])
    ):
        ordered_flags[flag] = OrderedDict([
            ("rawWarningLines", raw),
            ("uniqueDiagnostics", unique_count),
        ])

    owned = [
        diagnostic for diagnostic in unique.values()
        if diagnostic.component == OWNED_COMPONENT and diagnostic.file.startswith("plugin/")
    ]
    owned.sort(key=lambda diagnostic: (diagnostic.file, diagnostic.line, diagnostic.flag))

    owned_entries = [
        OrderedDict([
            ("file", diagnostic.file),
            ("line", diagnostic.line),
            ("column", diagnostic.column),
            ("flag", diagnostic.flag),
            ("message", diagnostic.message),
        ])
        for diagnostic in owned
    ]

    return OrderedDict([
        ("schemaVersion", SCHEMA_VERSION),
        ("toolchain", toolchain),
        ("counts", OrderedDict([
            ("rawWarningLines", len(diagnostics)),
            ("uniqueDiagnostics", len(unique)),
            ("ownedUniqueDiagnostics", len(owned)),
            ("components", components),
            ("flags", ordered_flags),
        ])),
        ("ownedDiagnostics", owned_entries),
    ])


def load_baseline(path: Path) -> dict[str, object]:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except OSError as error:
        raise SystemExit(f"warning-baseline: cannot read baseline {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"warning-baseline: invalid baseline JSON {path}: {error}") from error
    if data.get("schemaVersion") != SCHEMA_VERSION:
        raise SystemExit(
            f"warning-baseline: {path} has schema {data.get('schemaVersion')!r}; "
            f"expected {SCHEMA_VERSION}"
        )
    if not isinstance(data.get("ownedDiagnostics"), list):
        raise SystemExit(f"warning-baseline: {path} has no ownedDiagnostics list")
    return data


def baseline_keys(data: dict[str, object]) -> set[tuple[str, int, str]]:
    keys: set[tuple[str, int, str]] = set()
    for entry in data["ownedDiagnostics"]:  # type: ignore[index]
        try:
            keys.add((str(entry["file"]), int(entry["line"]), str(entry["flag"])))
        except (KeyError, TypeError, ValueError) as error:
            raise SystemExit(f"warning-baseline: malformed owned diagnostic: {entry!r}") from error
    return keys


def format_diagnostic(diagnostic: Diagnostic) -> str:
    column = f",{diagnostic.column}" if diagnostic.column is not None else ""
    flag = "" if diagnostic.flag == NO_FLAG else f" [{diagnostic.flag}]"
    return f"{diagnostic.file}({diagnostic.line}{column}): warning: {diagnostic.message}{flag}"


def summary(report: dict[str, object]) -> str:
    counts = report["counts"]
    parts = [f"{counts['rawWarningLines']} raw lines", f"{counts['uniqueDiagnostics']} unique"]
    for component in COMPONENTS:
        row = counts["components"][component]
        parts.append(
            f"{component}: {row['uniqueDiagnostics']} unique/{row['rawWarningLines']} raw"
        )
    return "; ".join(parts)


def check(args: argparse.Namespace, repo_root: Path, baseline_path: Path) -> int:
    data = load_baseline(baseline_path)
    toolchain = read_toolchain(args.toolchain or repo_root / "windows/toolchain.json")
    if data.get("toolchain") != toolchain:
        print(
            "warning-baseline: baseline toolchain does not match windows/toolchain.json; "
            "regenerate it from a full native build",
            file=sys.stderr,
        )
        return 2

    diagnostics = parse_logs(args.check, repo_root, args.build_root)
    owned = [
        diagnostic for diagnostic in unique_diagnostics(diagnostics).values()
        if diagnostic.component == OWNED_COMPONENT and diagnostic.file.startswith("plugin/")
    ]
    known = baseline_keys(data)
    new = sorted(
        (diagnostic for diagnostic in owned if diagnostic.key not in known),
        key=lambda diagnostic: (diagnostic.file, diagnostic.line, diagnostic.flag),
    )
    if new:
        for diagnostic in new:
            print(f"new owned warning: {format_diagnostic(diagnostic)}")
        print(
            f"warning-baseline: {len(new)} owned diagnostic(s) absent from "
            f"{baseline_path}"
        )
        return 1

    print(
        f"warning-baseline: {len(owned)} owned diagnostic(s), all present in "
        f"{baseline_path}"
    )
    return 0


def generate(args: argparse.Namespace, repo_root: Path, baseline_path: Path) -> int:
    toolchain_path = args.toolchain or repo_root / "windows/toolchain.json"
    toolchain = read_toolchain(toolchain_path)
    diagnostics = parse_logs(args.log, repo_root, args.build_root)
    if not diagnostics:
        raise SystemExit(
            "warning-baseline: no clang-cl warnings matched in the supplied log; "
            "refusing to write an empty baseline"
        )
    report = build_report(diagnostics, toolchain)
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    baseline_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(f"warning-baseline: {summary(report)}")
    print(f"warning-baseline: wrote {baseline_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--log", nargs="+", metavar="LOG",
        help="build log file(s) or a build logs directory to write the baseline from",
    )
    mode.add_argument(
        "--check", nargs="+", metavar="LOG",
        help="build log file(s) or a build logs directory to compare with the baseline",
    )
    parser.add_argument(
        "--baseline", type=Path,
        help=f"baseline JSON path (default: <repo>/{DEFAULT_BASELINE.as_posix()})",
    )
    parser.add_argument(
        "--repo-root", type=Path,
        help="repository root used to normalize paths (default: this checkout)",
    )
    parser.add_argument(
        "--build-root", type=Path,
        help="build root to strip from generated-file locations",
    )
    parser.add_argument(
        "--toolchain", type=Path,
        help="toolchain specification (default: <repo>/windows/toolchain.json)",
    )
    args = parser.parse_args(argv)

    repo_root = (args.repo_root or Path(__file__).resolve().parents[2]).resolve()
    baseline_path = (args.baseline or repo_root / DEFAULT_BASELINE).resolve()
    if args.build_root is not None:
        args.build_root = args.build_root.resolve()
    if args.toolchain is not None:
        args.toolchain = args.toolchain.resolve()

    if args.check:
        return check(args, repo_root, baseline_path)
    return generate(args, repo_root, baseline_path)


if __name__ == "__main__":
    raise SystemExit(main())
