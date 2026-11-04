"""Hub mode behaviour against the loopback stub hub (fixtures/stub_cpa_hub.py)."""
from __future__ import annotations

import os
import sys
import threading
import time
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "quota"))
sys.path.insert(0, os.path.join(ROOT, "providers"))
sys.path.insert(0, os.path.join(ROOT, "fixtures"))

import core  # noqa: E402
import hub as hubmod  # noqa: E402
import quota_providers  # noqa: E402
import stub_cpa_hub  # noqa: E402
from scheduler import Scheduler  # noqa: E402

KEY = "test-admin-key-0001"


class Clock:
    # Starts at the real time: the stub's resets and grants are relative to it.
    def __init__(self) -> None:
        self.now = time.time()

    def __call__(self) -> float:
        return self.now


def service(base, key=KEY, clock=None, http=core.http_request, interval_ms=60000, state=None):
    out = []
    svc = quota_providers.Service(out.append, clock or Clock(), http)
    svc.configure({"baseUrl": base, "adminKey": key, "refreshIntervalMs": interval_ms, "state": state or {}})
    return svc, out


class Stub(unittest.TestCase):
    scenario = "stock"
    refuse = "none"

    def setUp(self):
        self.server, self.stats, self.base = stub_cpa_hub.start(KEY, self.scenario, self.refuse)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def api_calls(self, needle=""):
        return sum(n for name, n in self.stats.snapshot()["calls"].items() if name.startswith("api:") and needle in name)


class HubReads(Stub):
    def test_supported_logins_mapped_and_served(self):
        svc, out = service(self.base)
        svc.run_pass()
        snap = out[-1]
        self.assertEqual(snap["hub"]["state"], "ok")
        # codex, claude (listed twice, one identity) and antigravity; unsupported,
        # disabled and API-key logins are skipped.
        self.assertEqual([a["provider"] for a in snap["accounts"]], ["codex", "claude", "antigravity"])
        codex, claude, gravity = snap["accounts"]
        self.assertEqual(codex["label"], "codex.hub")
        self.assertEqual(codex["plan"], "Pro 200")
        self.assertEqual([w["id"] for w in codex["windows"]], ["five-hour", "weekly", "five-hour-spark"])
        self.assertEqual(codex["resetCredits"]["count"], 2)
        self.assertEqual(len(codex["resetCredits"]["expiries"]), 2)
        self.assertEqual(len(codex["history"]["days"]), 30)
        self.assertEqual(claude["plan"], "Max")
        self.assertEqual([w["id"] for w in claude["windows"]], ["five-hour", "weekly", "seven-day-sonnet", "seven-day-fable"])
        self.assertEqual(gravity["plan"], "Google AI Pro")
        self.assertEqual(len(gravity["windows"]), 5)
        self.assertEqual(self.stats.snapshot()["badTokenHeaders"], 0)

    def test_one_claude_usage_read_per_identity_per_pass(self):
        svc, _ = service(self.base)
        svc.run_pass()
        usage = self.api_calls("api.anthropic.com/api/oauth/usage")
        self.assertEqual(usage, 1)

    def test_claude_grants_never_follow_a_usage_read_in_one_pass(self):
        clock = Clock()
        svc, out = service(self.base, clock=clock)
        svc.run_pass()
        self.assertNotIn("resetCredits", out[-1]["accounts"][1])
        clock.now += 300
        svc.run_pass()
        claude = out[-1]["accounts"][1]
        self.assertEqual(claude["resetCredits"]["count"], 1)
        # The second pass read the grants in place of usage.
        self.assertEqual(self.api_calls("a2:api.anthropic.com/api/oauth/usage"), 2)
        self.assertEqual(self.stats.snapshot()["calls"].get("api:a2:api.anthropic.com/api/oauth/profile"), 2)

    def test_calls_are_serialized(self):
        svc, _ = service(self.base)
        svc.run_pass()
        login = svc.accounts[svc.order[0]].login
        threads = [threading.Thread(target=svc.hub.call, args=(login, "GET", "https://chatgpt.com/backend-api/wham/usage", {}))
                   for _ in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(self.stats.snapshot()["maxInFlight"], 1)

    def test_dedupe_marks_the_summary_row(self):
        svc, out = service(self.base)
        svc.set_summary([{"ref": "codex:codex-hub-row", "provider": "codex", "keys": ["CODEX.hub@example.test", "codex-hub-row"]},
                         {"ref": "claude:other", "provider": "claude", "keys": ["someone@example.test"]}])
        svc.run_pass()
        refs = [a["summaryRef"] for a in out[-1]["accounts"]]
        self.assertEqual(refs, ["codex:codex-hub-row", None, None])


class Scheduling(Stub):
    def test_never_reads_an_account_under_300_s(self):
        clock = Clock()
        svc, out = service(self.base, clock=clock, interval_ms=10000)
        reads = {}
        original = svc.scheduler.read_ok

        def record(key, now):
            reads.setdefault(key, []).append(now)
            original(key, now)

        svc.scheduler.read_ok = record
        start = clock.now
        # Wake whenever the helper asks, and also at every odd moment a caller might.
        while clock.now < start + 3 * 3600:
            svc.run_pass()
            deadline = out[-1]["nextDueAt"] / 1000
            self.assertGreaterEqual(deadline, clock.now + 1)
            clock.now = min(deadline, clock.now + 97)
        for times in reads.values():
            gaps = [b - a for a, b in zip(times, times[1:])]
            self.assertTrue(gaps and min(gaps) >= 300, gaps)

    def test_interval_floor_and_backoff(self):
        s = Scheduler(5)
        self.assertEqual(s.interval, 300)
        s.read_failed("a", 0)
        self.assertEqual(s.entry("a").next_due, 300)
        s.read_failed("a", 300)
        self.assertEqual(s.entry("a").next_due, 900)
        for _ in range(8):
            s.read_failed("a", 1000)
        self.assertEqual(s.entry("a").next_due, 1000 + 3600)
        s.read_failed("b", 0, retry_after=1800)
        self.assertEqual(s.entry("b").next_due, 1800)

    def test_refresh_now_skips_accounts_read_in_the_last_60_s(self):
        clock = Clock()
        svc, _ = service(self.base, clock=clock)
        svc.run_pass()
        before = self.api_calls()
        clock.now += 30
        svc.run_pass(force=True)
        self.assertEqual(self.api_calls(), before)
        clock.now += 31
        svc.run_pass(force=True)
        self.assertGreater(self.api_calls(), before)


class Refusals(unittest.TestCase):
    def run_refused(self, refuse, expected):
        server, stats, base = stub_cpa_hub.start(KEY, "stock", refuse)
        try:
            svc, out = service(base)
            for _ in range(4):
                svc.run_pass(force=True)
            self.assertEqual(out[-1]["hub"]["state"], expected)
            self.assertIsNone(out[-1]["nextDueAt"])
            # One strike, then nothing more with that key.
            self.assertEqual(stats.snapshot()["total"], 1)
            svc.configure({"baseUrl": base, "adminKey": KEY + "-replaced"})
            svc.run_pass()
            self.assertEqual(stats.snapshot()["total"], 2)
        finally:
            server.shutdown()
            server.server_close()

    def test_401_stops_all_calls_with_that_key(self):
        self.run_refused("401", "key_rejected")

    def test_ban_stops_all_calls_with_that_key(self):
        self.run_refused("ban", "banned")

    def test_401_during_api_call_stops_the_rest_of_the_pass(self):
        calls = []

        def http(method, url, headers, data, timeout):
            calls.append(url)
            if url.endswith("auth-files"):
                return core.Response(200, {}, '{"files":[{"id":"a","auth_index":"1","provider":"codex"},'
                                              '{"id":"b","auth_index":"2","provider":"claude"}]}')
            return core.Response(401, {}, '{"error":"invalid management key"}')

        svc, out = service("http://127.0.0.1:1", http=http)
        svc.run_pass()
        svc.run_pass(force=True)
        self.assertEqual(len(calls), 2)
        self.assertEqual(out[-1]["hub"]["state"], "key_rejected")

    def test_plain_http_only_to_local_or_tailscale(self):
        calls = []
        svc, out = service("http://hub.example.com:8317", http=lambda *a: calls.append(a))
        svc.run_pass()
        self.assertEqual(calls, [])
        self.assertEqual(out[-1]["hub"]["state"], "insecure")
        allowed = ["https://hub.example.com", "http://127.0.0.1:8317", "http://localhost:8317", "http://[::1]:8317",
                   "http://10.1.2.3", "http://172.20.0.1", "http://192.168.1.20:8317", "http://169.254.0.9",
                   "http://100.101.102.103:8317", "http://box.tailnet.ts.net", "http://nas.local", "http://[fd7a:115c:a1e0::1]"]
        refused = ["http://hub.example.com", "http://8.8.8.8", "http://172.32.0.1", "http://100.128.0.1",
                   "http://myserver", "ftp://127.0.0.1", "http://[2001:db8::1]"]
        self.assertEqual([u for u in allowed if not hubmod.allows_key(u)], [])
        self.assertEqual([u for u in refused if hubmod.allows_key(u)], [])
        self.assertEqual(hubmod.normalize_base("https://hub.example.com/v0/management/"), "https://hub.example.com")


class Reconciliation(unittest.TestCase):
    def test_login_removed_only_after_two_listings_lack_it(self):
        listings = [
            [{"id": "a", "auth_index": "1", "provider": "codex", "email": "a@x"},
             {"id": "b", "auth_index": "2", "provider": "codex", "email": "b@x"}],
            [{"id": "a", "auth_index": "1", "provider": "codex", "email": "a@x"}],
            [{"id": "a", "auth_index": "1", "provider": "codex", "email": "a@x"}],
        ]
        svc, _ = service("http://127.0.0.1:1", http=lambda *a: None)
        for index, files in enumerate(listings):
            svc.hub.logins = lambda files=files: hubmod.listing({"files": files})
            svc.list_logins(0)
            labels = [svc.accounts[k].login.label for k in svc.order]
            self.assertEqual(labels, [["a@x", "b@x"], ["a@x", "b@x"], ["a@x"]][index])


class ClaudeWindow(unittest.TestCase):
    def test_429_window_is_honoured_and_persisted(self):
        calls = []

        def http(method, url, headers, data, timeout):
            calls.append(url)
            if url.endswith("auth-files"):
                return core.Response(200, {}, '{"files":[{"id":"c","auth_index":"9","provider":"claude","email":"c@x"}]}')
            return core.Response(200, {}, '{"status_code":429,"header":{"Retry-After":["1200"]},"body":""}')

        clock = Clock()
        svc, out = service("http://127.0.0.1:1", http=http, clock=clock)
        svc.run_pass()
        state = out[-1]["state"]
        self.assertEqual(len(state["claudeWindows"]), 1)
        window = next(iter(state["claudeWindows"].values()))
        self.assertEqual(window["until"], int((clock.now + 1200) * 1000))
        self.assertEqual(out[-1]["accounts"][0]["error"], {"code": "rate_limited"})
        # A restarted helper given the cached state sends nothing inside the window.
        calls.clear()
        clock.now += 600
        fresh, _ = service("http://127.0.0.1:1", http=http, clock=clock, state=state)
        fresh.run_pass(force=True)
        self.assertEqual([c for c in calls if "api-call" in c], [])


if __name__ == "__main__":
    unittest.main()
