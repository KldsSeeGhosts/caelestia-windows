"""Leak check: the real helper process, run against the stub hub with sentinel secrets.

The management key reaches the helper over stdin only. Neither it nor the token
the stub's listing carries may appear in the helper's stdout or stderr, in the
success path or in the refused-key path that writes a diagnostic line.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "quota"))
sys.path.insert(0, os.path.join(ROOT, "fixtures"))

import stub_cpa_hub  # noqa: E402

HELPER = os.path.join(ROOT, "providers", "quota_providers.py")
SENTINEL_KEY = "SENTINEL-ADMIN-KEY-5d0b3e"
SENTINELS = (SENTINEL_KEY, stub_cpa_hub.SENTINEL_TOKEN, stub_cpa_hub.SENTINEL_LOGIN_ID)


def find_leaks(texts, sentinels=SENTINELS):
    return [s for s in sentinels for t in texts if s in t]


def run_helper(base: str, key: str, wait_for_accounts: bool):
    with tempfile.TemporaryDirectory() as cwd:
        process = subprocess.Popen([sys.executable, "-I", HELPER, "serve"], cwd=cwd, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                   env={"SYSTEMROOT": os.environ.get("SYSTEMROOT", ""), "PYTHONUTF8": "1"})
        process.stdin.write(json.dumps({"type": "configure", "baseUrl": base, "adminKey": key,
                                        "refreshIntervalMs": 60000}) + "\n")
        process.stdin.write(json.dumps({"type": "refresh", "force": True}) + "\n")
        process.stdin.flush()
        lines = []
        deadline = time.time() + 20
        while time.time() < deadline:
            line = process.stdout.readline()
            if not line:
                break
            lines.append(line)
            message = json.loads(line)
            if not wait_for_accounts or message.get("accounts"):
                break
        process.stdin.close()
        rest, err = process.communicate(timeout=10)
        return "".join(lines) + rest, err


class LeakCheck(unittest.TestCase):
    def test_the_checker_catches_a_planted_leak(self):
        # The check has to be able to fail: a line carrying either sentinel is caught.
        self.assertEqual(find_leaks(['{"note":"Bearer %s"}' % SENTINEL_KEY]), [SENTINEL_KEY])
        self.assertEqual(find_leaks(["x" + stub_cpa_hub.SENTINEL_TOKEN]), [stub_cpa_hub.SENTINEL_TOKEN])
        self.assertEqual(find_leaks(['"label":"%s"' % stub_cpa_hub.SENTINEL_LOGIN_ID]), [stub_cpa_hub.SENTINEL_LOGIN_ID])

    def test_no_secret_in_helper_output(self):
        server, stats, base = stub_cpa_hub.start(SENTINEL_KEY, "stock")
        try:
            out, err = run_helper(base, SENTINEL_KEY, True)
        finally:
            server.shutdown()
            server.server_close()
        snapshot = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(len(snapshot["accounts"]), 3)
        self.assertGreater(stats.snapshot()["total"], 3)
        self.assertEqual(find_leaks([out, err]), [])
        self.assertNotIn("@", out)

    def test_no_secret_when_the_key_is_refused(self):
        server, stats, base = stub_cpa_hub.start("the-real-key", "stock")
        try:
            out, err = run_helper(base, SENTINEL_KEY, False)
        finally:
            server.shutdown()
            server.server_close()
        self.assertIn("key_rejected", out)
        self.assertIn("refused the management key", err)
        self.assertEqual(find_leaks([out, err]), [])


if __name__ == "__main__":
    unittest.main()
