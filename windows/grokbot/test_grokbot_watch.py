import base64
import builtins
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("grokbot_watch", os.path.join(os.path.dirname(__file__), "grokbot_watch.py"))
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


def blob(directory, key, value):
    name = base64.b32encode(key.encode()).decode().rstrip("=").lower() + ".blob"
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as stream:
        json.dump({"value": value}, stream)
    return path


def fixture(appdata):
    directory = os.path.join(appdata, "Grok Bot", "sand-client-persistence")
    os.makedirs(directory, exist_ok=True)
    now = int(time.time() * 1000)
    blob(directory, "client-meta.account-slot", "active|account")
    blob(directory, "account.active%7Caccount.roster.last-roster", {"rows": [
        {"id": "a", "name": "Waiting", "title": "Planning", "avatarShape": "squircle",
         "avatarColor": "red", "awaitingUserResponse": True, "lastActivityAt": now - 2040000,
         "lastEntry": {"text": "Synthetic question"}},
        {"id": "b", "name": "Unread", "avatarShape": "gem", "unreadCount": 3, "lastActivityAt": now - 720000,
         "lastEntry": {"text": "Synthetic update"}},
        {"id": "c", "name": "Research", "avatarShape": "hex", "lastActivityAt": now - 120000},
    ]})
    blob(directory, "account.active%7Caccount.transcript.replicas.c", {"entries": [
        {"kind": "message", "role": "user", "timestampMs": now - 60000,
         "text": "TRANSCRIPT_PRIVATE_CANARY"}
    ]})
    # These must never be opened, despite matching the .blob filename format.
    blob(directory, "account.active%7Caccount.roster.agent-avatars", {"secret": "AVATAR_PRIVATE_CANARY"})
    blob(directory, "account.active%7Caccount.credentials", {"secret": "SECRET_PRIVATE_CANARY"})
    return directory


class ProducerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = fixture(self.temp.name)

    def test_projection_and_cache(self):
        allowed = []
        real_open = builtins.open

        def audited(path, *args, **kwargs):
            allowed.append(os.fspath(path))
            return real_open(path, *args, **kwargs)

        watcher = watch.Watcher(self.directory)
        with mock.patch("builtins.open", side_effect=audited):
            first = watcher.snapshot()
            initial_reads = len(allowed)
            second = watcher.snapshot()
        self.assertEqual(initial_reads, 3)
        self.assertEqual(len(allowed), initial_reads)
        self.assertEqual(first["counts"], {"bots": 3, "awaiting": 1, "working": 1, "unread": 1})
        self.assertTrue(first["bots"][2]["working"])
        self.assertEqual(first["bots"], second["bots"])
        encoded = json.dumps(first)
        for secret in ("TRANSCRIPT_PRIVATE_CANARY", "AVATAR_PRIVATE_CANARY", "SECRET_PRIVATE_CANARY"):
            self.assertNotIn(secret, encoded)

    def test_working_heuristic_and_roster_limits(self):
        now = int(time.time() * 1000)
        rows = [{"id": str(i), "name": "x" * 500, "lastEntry": {"text": "p" * 500}}
                for i in range(50)]
        blob(self.directory, "account.active%7Caccount.roster.last-roster", {"rows": rows})
        blob(self.directory, "account.active%7Caccount.transcript.replicas.0", {"entries": [
            {"kind": "message", "role": "user", "timestampMs": now - 1000},
            {"kind": "send-message", "timestampMs": now}
        ]})
        blob(self.directory, "account.active%7Caccount.transcript.replicas.1", {"entries": [
            {"kind": "message", "role": "user", "timestampMs": now - 901000}
        ]})
        snapshot = watch.Watcher(self.directory).snapshot()
        self.assertEqual(len(snapshot["bots"]), 32)
        self.assertEqual(len(snapshot["bots"][0]["name"]), 128)
        self.assertEqual(len(snapshot["bots"][0]["last_text"]), 160)
        self.assertFalse(snapshot["bots"][0]["working"])
        self.assertFalse(snapshot["bots"][1]["working"])

    def test_cache_invalidation_and_account_isolation(self):
        watcher = watch.Watcher(self.directory)
        self.assertTrue(watcher.snapshot()["bots"][2]["working"])
        now = int(time.time() * 1000)
        blob(self.directory, "account.active%7Caccount.transcript.replicas.c", {"entries": [
            {"kind": "message", "role": "user", "timestampMs": now - 1000},
            {"kind": "send-message"},
        ]})
        self.assertFalse(watcher.snapshot()["bots"][2]["working"])
        blob(self.directory, "account.other.roster.last-roster", {"rows": [{"id": "other", "name": "other"}]})
        blob(self.directory, "client-meta.account-slot", "missing-account")
        with self.assertRaises(ValueError):
            watcher.snapshot()

    def test_atomic_publish_and_bounded_read(self):
        path = os.path.join(self.temp.name, "snapshot.json")
        watch.publish(path, watch.Watcher(self.directory).snapshot())
        self.assertLessEqual(os.path.getsize(path), watch.SNAPSHOT_LIMIT)
        self.assertEqual(json.loads(watch.bounded_read(path, watch.SNAPSHOT_LIMIT))["counts"]["bots"], 3)
        self.assertFalse(any(name.endswith(".tmp") for name in os.listdir(self.temp.name)))
        with open(path, "wb") as stream:
            stream.write(b"x" * (watch.SNAPSHOT_LIMIT + 1))
        with self.assertRaises(ValueError):
            watch.bounded_read(path, watch.SNAPSHOT_LIMIT)

    def test_missing_and_malformed_roster(self):
        with self.assertRaises((ValueError, OSError)):
            watch.Watcher(os.path.join(self.temp.name, "missing")).snapshot()
        blob(self.directory, "account.active%7Caccount.roster.last-roster", {"rows": "bad"})
        with self.assertRaises(ValueError):
            watch.Watcher(self.directory).snapshot()

    def test_oversized_source_blob(self):
        path = blob(self.directory, "account.active%7Caccount.roster.last-roster", {"rows": []})
        with open(path, "wb") as stream:
            stream.truncate(watch.BLOB_LIMIT + 1)
        with self.assertRaises(ValueError):
            watch.Watcher(self.directory).snapshot()

    def test_failing_transcript_does_not_grow_cache(self):
        path = blob(self.directory, "account.active%7Caccount.transcript.replicas.c", {"entries": []})
        with open(path, "wb") as stream:
            stream.truncate(watch.BLOB_LIMIT + 1)
        watcher = watch.Watcher(self.directory)
        for version in range(20):
            # Each version differs in size, so it is a new cache signature.
            blob(self.directory, "account.active%7Caccount.roster.last-roster", {"rows": [
                {"id": "c", "name": "Research" + "x" * version}]})
            with self.assertRaises(ValueError):
                watcher.snapshot()
        # Only the current roster projection may survive pruning.
        self.assertLessEqual(len(watcher.cache), 2)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--fixture":
        fixture(sys.argv[2])
    else:
        unittest.main()
