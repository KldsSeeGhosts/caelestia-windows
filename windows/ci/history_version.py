"""Allocate plain SemVer from immutable first-parent Git history. No network."""
import argparse
import json
from pathlib import Path
import re
import subprocess

VERSION_FILE = "windows/release/version.json"
PLAIN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
TITLE = re.compile(
    r"(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)"
    r"(?:\([^()\r\n]+\))?(!)?: [^\s][^\r\n]*")
COMMIT_TITLE = re.compile(r"([a-z][a-z0-9-]*)(?:\([^()\r\n]+\))?(!)?: [^\s][^\r\n]*")
MERGE = re.compile(r"Merge pull request #[1-9][0-9]* from [^\r\n]+")


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                            encoding="utf-8", errors="strict", timeout=120)
    if result.returncode:
        raise ValueError("version-history-unavailable")
    return result.stdout.rstrip("\n")


def native_version(value):
    if not isinstance(value, str) or not PLAIN.fullmatch(value):
        raise ValueError("invalid-base-version")
    parts = tuple(int(part) for part in value.split("."))
    if any(part > 65535 for part in parts):
        raise ValueError("native-version-overflow")
    return parts


def check_title(title):
    return isinstance(title, str) and TITLE.fullmatch(title) is not None


def merge_bump(message, parent_count):
    # Only a real GitHub merge's first body line is its recorded PR title.
    # Direct commits, including squash commits, always consume a patch.
    lines = message.splitlines()
    if parent_count < 2 or not lines or not MERGE.fullmatch(lines[0]):
        return "patch"
    title = next((line for line in lines[1:] if line.strip()), "")
    match = COMMIT_TITLE.fullmatch(title)
    if (match and match[2]) or any(line.startswith("BREAKING CHANGE:") for line in lines[1:]):
        return "breaking"
    return "minor" if match and match[1] == "feat" else "patch"


def bump(version, kind):
    major, minor, patch = native_version(version)
    if kind == "breaking" and major:
        major, minor, patch = major + 1, 0, 0
    elif kind in ("minor", "breaking"):
        minor, patch = minor + 1, 0
    else:
        patch += 1
    result = f"{major}.{minor}.{patch}"
    native_version(result)  # Never roll over a Windows VERSIONINFO component.
    return result


def base_at(root, revision):
    document = json.loads(git(root, "show", f"{revision}:{VERSION_FILE}"))
    if document["schema"] != 1 or document["profileSchema"] != 1:
        raise ValueError("invalid-authoritative-version-file")
    return document["version"]


def resolve(root, revision="HEAD"):
    revision = git(root, "rev-parse", "--verify", revision + "^{commit}")
    if git(root, "rev-parse", "--is-shallow-repository") != "false":
        raise ValueError("version-history-shallow")
    base = base_at(root, revision)
    native_version(base)
    # File edits to profile/schema fields must not reset the anchor. Compare
    # the base value to each candidate's first parent, not its topic parent.
    changes = git(root, "log", "--first-parent", "--full-history", "--format=%H",
                  revision, "--", VERSION_FILE).splitlines()
    anchor = None
    for commit in changes:
        parents = git(root, "show", "-s", "--format=%P", commit).split()
        if not parents:
            anchor = commit
            break
        try:
            previous = base_at(root, parents[0])
        except ValueError:
            # The file's introduction is an anchor too.
            if git(root, "ls-tree", parents[0], "--", VERSION_FILE):
                raise
            previous = None
        if base_at(root, commit) != previous:
            anchor = commit
            break
    if anchor is None or base_at(root, anchor) != base:
        raise ValueError("version-anchor-unavailable")
    version = base
    # NUL cannot occur in a Git commit message. Read all fold inputs in one
    # process so allocation does not launch two Git processes per main commit.
    records = git(root, "log", "--first-parent", "--reverse", "--format=%P%x00%B%x00",
                  anchor + ".." + revision).split("\0")
    for index in range(0, len(records) - 1, 2):
        version = bump(version, merge_bump(records[index + 1], len(records[index].split())))
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--check-title", action="store_true")
    args = parser.parse_args()
    try:
        if args.check_title:
            import os
            if not check_title(os.environ.get("PR_TITLE", "")):
                raise ValueError("PR title must use type: description or type(scope): description; "
                                 "types: feat, fix, perf, refactor, docs, test, build, ci, chore, style, revert; "
                                 "add ! before : for breaking changes")
        else:
            print(resolve(args.root, args.revision))
        return 0
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
