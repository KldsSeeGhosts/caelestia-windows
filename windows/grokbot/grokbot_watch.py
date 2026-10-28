"""Bounded, status-only reader for Grok Bot's Windows persistence.

Only the account slot, roster and selected transcript replica blobs are opened.
The helper emits no diagnostics or private data except its bounded snapshot on
stdout, which is an attached pipe to the shell.
"""

import argparse
import base64
import json
import os
import sys
import tempfile
import time

SNAPSHOT_LIMIT = 256 * 1024
BLOB_LIMIT = 16 * 1024 * 1024
MAX_BOTS = 32
COLORS = {
    "red": "#FF263C", "orange": "#FF6700", "yellow": "#FF9800",
    "green": "#00C972", "cyan": "#00BCA6", "blue": "#1084FE",
    "violet": "#9159FE", "magenta": "#FF309B", "brown": "#936439",
    "gray": "#777777",
}
SHAPES = {
    "circle", "egg", "capsule", "cylinder", "tablet", "squircle", "hex",
    "gem", "crystal", "wedge", "shield", "dome", "arch", "bean", "pebble",
    "cloud", "teardrop", "leaf", "group", "blob",
}


def bounded_read(path, limit):
    # The limit applies to the read itself, not a racy pre-read stat check.
    with open(path, "rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("oversized")
    return data


def text(value, limit):
    return value[:limit] if isinstance(value, str) else ""


def seconds(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        return 0
    value = value / 1000
    return value if 0 <= value <= time.time() + 60 else 0


def index_blobs(directory):
    result = {}
    with os.scandir(directory) as entries:
        for entry in entries:
            if not entry.name.endswith(".blob") or not entry.is_file(follow_symlinks=False):
                continue
            try:
                name = entry.name[:-5].upper()
                key = base64.b32decode(name + "=" * ((8 - len(name) % 8) % 8)).decode("utf-8")
                if not (key.endswith(("client-meta.account-slot", "roster.last-roster"))
                        or ".transcript.replicas." in key):
                    continue
                stat = entry.stat(follow_symlinks=False)
                result[key] = (entry.path, stat.st_mtime_ns, stat.st_size)
            except (OSError, ValueError, UnicodeError):
                continue
    return result


class Watcher:
    def __init__(self, directory):
        self.directory = directory
        # Values are already projected. Transcript message bodies are never cached.
        self.cache = {}

    def read(self, entry, parser):
        signature = (entry[0], entry[1], entry[2], parser.__name__)
        if signature not in self.cache:
            data = json.loads(bounded_read(entry[0], BLOB_LIMIT))
            if not isinstance(data, dict):
                raise ValueError("invalid blob")
            self.cache[signature] = parser(data.get("value"))
        return self.cache[signature]

    @staticmethod
    def slot(value):
        return value.replace("|", "%7C") if isinstance(value, str) and len(value) <= 256 else ""

    @staticmethod
    def roster(value):
        if not isinstance(value, dict) or not isinstance(value.get("rows"), list):
            raise ValueError("invalid roster")
        result = []
        for row in value["rows"]:
            if len(result) == MAX_BOTS:
                break
            if not isinstance(row, dict) or row.get("isHiddenFromSidebar"):
                continue
            bot_id = row.get("id")
            if not isinstance(bot_id, str) or not bot_id or len(bot_id) > 256:
                continue
            last = row.get("lastEntry")
            last = last if isinstance(last, dict) else {}
            color = row.get("avatarColor")
            shape = row.get("avatarShape")
            unread = row.get("unreadCount")
            unread = min(unread, 9999) if isinstance(unread, int) and not isinstance(unread, bool) and unread >= 0 else 0
            result.append((bot_id, {
                "name": text(row.get("name"), 128) or "(unnamed)",
                "title": text(row.get("title"), 128),
                "description": text(row.get("description"), 256),
                "shape": shape if isinstance(shape, str) and shape in SHAPES else ("group" if row.get("isGroup") is True else "squircle"),
                "hex": COLORS.get(color, "") if isinstance(color, str) else "",
                "unread": unread,
                "awaiting": row.get("awaitingUserResponse") is True,
                "working": False,
                "last_text": text(last.get("text"), 160),
                "last_activity_ts": seconds(row.get("lastActivityAt")),
            }))
        return result

    @staticmethod
    def transcript(value):
        if not isinstance(value, dict) or not isinstance(value.get("entries"), list):
            return 0
        for entry in reversed(value["entries"]):
            if not isinstance(entry, dict):
                continue
            if entry.get("kind") == "send-message":
                break
            if entry.get("kind") == "message" and entry.get("role") == "user":
                return seconds(entry.get("timestampMs"))
        return 0

    def snapshot(self):
        index = index_blobs(self.directory)
        slot_entries = [v for k, v in index.items() if k.endswith("client-meta.account-slot")]
        account = self.read(max(slot_entries, key=lambda e: e[1]), self.slot) if slot_entries else ""
        rosters = [(k, v) for k, v in index.items() if k.endswith("roster.last-roster")]
        if account:
            selected = [(k, v) for k, v in rosters if ("account." + account + ".roster.last-roster") in k]
            rosters = selected
        if not rosters:
            raise ValueError("roster unavailable")
        roster_key, roster_entry = max(rosters, key=lambda pair: pair[1][1])
        if "account." in roster_key:
            account = roster_key.split("account.", 1)[1].split(".roster.last-roster", 1)[0]
        rows = self.read(roster_entry, self.roster)
        bots = []
        for bot_id, original in rows:
            bot = dict(original)
            suffix = "transcript.replicas." + bot_id
            matches = [(k, v) for k, v in index.items() if k.endswith(suffix)]
            if account:
                matches = [(k, v) for k, v in matches if ("account." + account + "." + suffix) in k]
            if matches:
                since = self.read(max(matches, key=lambda pair: pair[1][1])[1], self.transcript)
                bot["working"] = bool(since and 0 <= time.time() - since < 900)
            bots.append(bot)
        # Prune cached versions and entries that disappeared.
        signatures = {(v[0], v[1], v[2]) for v in index.values()}
        self.cache = {k: v for k, v in self.cache.items() if k[:3] in signatures}
        return {
            "generated_ts": time.time(),
            # Process enumeration is intentionally outside the allowed input set.
            "app": {"running": False},
            "counts": {
                "bots": len(bots),
                "awaiting": sum(b["awaiting"] for b in bots),
                "working": sum(b["working"] for b in bots),
                "unread": sum(b["unread"] > 0 for b in bots),
            },
            "bots": bots,
        }


def publish(path, data):
    encoded = json.dumps(data, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    if len(encoded) > SNAPSHOT_LIMIT:
        raise ValueError("oversized snapshot")
    directory = os.path.dirname(os.path.abspath(path))
    fd, temporary = tempfile.mkstemp(prefix=".grokbot-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def emit_snapshot(path):
    try:
        data = bounded_read(path, SNAPSHOT_LIMIT)
        # One line only; malformed JSON is rejected by QML.
        parsed = json.loads(data)
        encoded = json.dumps(parsed, ensure_ascii=True, separators=(",", ":")).encode("ascii")
        if len(encoded) > SNAPSHOT_LIMIT:
            raise ValueError("oversized")
        sys.stdout.buffer.write(encoded + b"\n")
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
        sys.stdout.buffer.write(b"{}\n")
    sys.stdout.buffer.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--source", choices=("producer", "snapshot"), default="producer")
    args = parser.parse_args()
    appdata = os.environ.get("APPDATA", "")
    directory = os.path.join(appdata, "Grok Bot", "sand-client-persistence") if appdata else ""
    watcher = Watcher(directory)
    while True:
        if args.source == "producer":
            try:
                publish(args.snapshot, watcher.snapshot())
            except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
                sys.stdout.buffer.write(b"{}\n")
                sys.stdout.buffer.flush()
                time.sleep(1.5)
                continue
        emit_snapshot(args.snapshot)
        time.sleep(1.5)


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt):
        # Never print paths, persistence contents, or exception text.
        pass
