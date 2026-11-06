"""Hub mode behaviour against the loopback stub hub (fixtures/stub_cpa_hub.py)."""
from __future__ import annotations

import ipaddress
import json
import os
import socket
import sys
import threading
import time
import unittest
from unittest import mock

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "quota"))
sys.path.insert(0, os.path.join(ROOT, "providers"))
sys.path.insert(0, os.path.join(ROOT, "fixtures"))

import core  # noqa: E402
import hub as hubmod  # noqa: E402
import quota_providers  # noqa: E402
import stub_cpa_hub  # noqa: E402
from scheduler import Scheduler  # noqa: E402

KEY = "test-admin-key-0001"


def resolving(table):
    """Stand-in DNS for the hub's getaddrinfo: a {name: [addresses]} table or a
    function of the name. Address literals resolve to themselves; other names fail."""
    def fake(host, port, *args, **kwargs):
        try:
            ipaddress.ip_address(host)
            addresses = [host]
        except ValueError:
            addresses = table(host) if callable(table) else table.get(host)
        if not addresses:
            raise socket.gaierror("no such name")
        return [(socket.AF_INET6 if ":" in a else socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, port))
                for a in addresses]
    return mock.patch.object(socket, "getaddrinfo", fake)


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
        self.assertEqual(gravity["label"], "Antigravity account 1")
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

    def test_masked_manager_rows_match_all_three_providers(self):
        svc, out = service(self.base)
        # Manager-shaped IDs derived independently from the stub's inventory.
        # No raw identity or unmasked display label is present in the summary.
        ids = {"codex": "acct_f7c3469ea9f91cc5", "claude": "acct_4aead524716ece00",
               "antigravity": "acct_18fcd715b3d54c22"}
        svc.set_summary([{"provider": kind, "ref": kind + ":" + account_id,
                          "keys": [account_id, "**masked**"]} for kind, account_id in ids.items()])
        svc.run_pass()
        accounts = out[-1]["accounts"]
        self.assertEqual([a["summaryRef"] for a in accounts],
                         [kind + ":" + account_id for kind, account_id in ids.items()])
        self.assertTrue(accounts[0]["history"]["days"])
        self.assertEqual(accounts[0]["resetCredits"]["count"], 2)


class SummaryIdentities(unittest.TestCase):
    def test_manager_opaque_account_id_matches_without_unmasking(self):
        # Golden vector from CPA Manager's opaqueAccountID(authIndex, name,
        # accountSnapshot): SHA-256 of the exact, case-sensitive joined fields.
        login = hubmod.Login({"id": "runtime-login", "auth_index": "codex-1",
                              "name": "codex.json", "email": "user@example.com",
                              "provider": "codex"})
        svc, _ = service("http://127.0.0.1")
        svc.set_summary([{"provider": "codex", "ref": "codex:acct_4ff74428cd08290a",
                          "keys": ["acct_4ff74428cd08290a", "us************om"]}])
        self.assertEqual(svc.summary_ref(login), "codex:acct_4ff74428cd08290a")

    def test_manager_metadata_aliases_and_field_precedence(self):
        cases = [
            {"auth_index": " codex-1 ", "name": " codex.json ",
             "account": " user@example.com ", "email": "ignored@example.test"},
            {"authIndex": "codex-1", "file_name": "codex.json", "display_account": "user@example.com"},
            {"auth-index": "codex-1", "fileName": "codex.json", "displayAccount": "user@example.com"},
            {"auth_index": "codex-1", "id": "codex.json", "email": "user@example.com"},
        ]
        for metadata in cases:
            with self.subTest(fields=sorted(metadata)):
                login = hubmod.Login(dict({"id": "runtime-login", "provider": "codex"}, **metadata))
                svc, _ = service("http://127.0.0.1")
                svc.set_summary([{"provider": "codex", "ref": "matched",
                                  "keys": ["acct_4ff74428cd08290a"]}])
                self.assertEqual(svc.summary_ref(login), "matched")

    def test_exact_manager_id_beats_shared_email_for_separate_workspaces(self):
        svc, _ = service("http://127.0.0.1")
        # The other workspace's summary comes first and shares the email.
        svc.set_summary([
            {"provider": "codex", "ref": "other-workspace", "keys": ["user@example.com"]},
            {"provider": "codex", "ref": "this-workspace",
             "keys": ["acct_4ff74428cd08290a", "user@example.com"]},
        ])
        login = hubmod.Login({"id": "codex.json", "auth_index": "codex-1",
                              "email": "user@example.com", "provider": "codex",
                              "id_token": {"chatgpt_account_id": "workspace-1"}})
        self.assertEqual(svc.summary_ref(login), "this-workspace")

    def test_ambiguous_legacy_identity_is_not_first_writer_wins(self):
        svc, _ = service("http://127.0.0.1")
        svc.set_summary([
            {"provider": "claude", "ref": "first", "keys": ["same@example.test"]},
            {"provider": "claude", "ref": "second", "keys": ["same@example.test"]},
        ])
        login = hubmod.Login({"id": "login", "auth_index": "a1", "provider": "claude",
                              "email": "same@example.test"})
        self.assertIsNone(svc.summary_ref(login))

    def test_opaque_match_is_provider_scoped_and_case_sensitive(self):
        login = hubmod.Login({"id": "codex.json", "auth_index": "codex-1",
                              "email": "User@example.com", "provider": "codex"})
        svc, _ = service("http://127.0.0.1")
        svc.set_summary([{"provider": "codex", "ref": "lowercase-email",
                          "keys": ["acct_4ff74428cd08290a"]}])
        self.assertIsNone(svc.summary_ref(login))
        svc.set_summary([{"provider": "claude", "ref": "other-provider",
                          "keys": [login.manager_id]}])
        self.assertIsNone(svc.summary_ref(login))

    def test_numeric_inventory_index_matches_the_manager(self):
        login = hubmod.Login({"id": "codex.json", "auth_index": 7,
                              "email": "user@example.com", "provider": "codex"})
        self.assertEqual(login.manager_id, "acct_8ac8fbd15e23dc8b")
        self.assertEqual(login.auth_index, "7")


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

        def http(method, url, headers, data, timeout, **_):
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
        with resolving({"hub.example.com": ["93.184.216.34"]}):
            svc, out = service("http://hub.example.com:8317", http=lambda *a, **k: calls.append(a))
            svc.run_pass()
        self.assertEqual(calls, [])
        self.assertEqual(out[-1]["hub"]["state"], "insecure")
        self.assertEqual(hubmod.normalize_base("https://hub.example.com/v0/management/"), "https://hub.example.com")

    def test_plain_http_needs_every_resolved_address_inside_the_ranges(self):
        names = {"hub.lan": ["192.168.1.5"], "localhost": ["::1", "127.0.0.1"],
                 # Names are not trusted: a .local or .ts.net name answering a
                 # public address, even once, is refused.
                 "nas.local": ["8.8.8.8"], "box.tailnet.ts.net": ["100.100.1.1", "203.0.113.9"]}
        allowed = ["https://hub.example.com", "http://127.0.0.1:8317", "http://localhost:8317", "http://[::1]:8317",
                   "http://10.1.2.3", "http://172.20.0.1", "http://192.168.1.20:8317", "http://hub.lan",
                   "http://100.101.102.103:8317", "http://[fd7a:115c:a1e0::1]"]
        refused = ["http://nas.local", "http://box.tailnet.ts.net", "http://169.254.0.9", "http://[fe80::1]",
                   "http://[fd00::1]", "http://8.8.8.8", "http://172.32.0.1", "http://100.128.0.1",
                   "http://unknown.invalid", "ftp://127.0.0.1", "http://[2001:db8::1]"]
        with resolving(names):
            self.assertEqual([u for u in allowed if not hubmod.allows_key(u)], [])
            self.assertEqual([u for u in refused if hubmod.allows_key(u)], [])

    def test_the_key_goes_to_the_address_that_was_validated(self):
        calls = []

        def http(method, url, headers, data, timeout, **kw):
            calls.append(kw.get("addresses"))
            return core.Response(200, {}, '{"files":[]}')

        answers = [["192.168.1.5"], ["8.8.8.8"]]
        with resolving(lambda host: answers.pop(0) if answers else ["8.8.8.8"]):
            svc, out = service("http://hub.lan:8317", http=http)
            svc.run_pass()
            self.assertEqual(calls, [["192.168.1.5"]])
            # The name now answers a public address: nothing is sent.
            svc.run_pass(force=True)
        self.assertEqual(calls, [["192.168.1.5"]])
        self.assertEqual(out[-1]["hub"]["state"], "insecure")

    def test_pinned_transport_connects_to_the_given_address(self):
        server, stats, base = stub_cpa_hub.start(KEY, "stock")
        try:
            port = base.rsplit(":", 1)[1]
            # The name does not resolve anywhere; only the pinned address is used.
            response = core.http_request("GET", "http://pinned.invalid:%s/v0/management/auth-files" % port,
                                         {"Authorization": "Bearer " + KEY}, None, 5, addresses=["127.0.0.1"])
            self.assertEqual(response.status, 200)
        finally:
            server.shutdown()
            server.server_close()

    def test_an_ipv4_hub_behind_a_name_answering_ipv6_first(self):
        # Windows' localhost answers ::1, then 127.0.0.1; the stub listens on IPv4 only.
        server, stats, base = stub_cpa_hub.start(KEY, "stock")
        tried = []
        connect = socket.create_connection

        def recording(address, *args, **kwargs):
            tried.append(address[0])
            return connect(address, *args, **kwargs)

        try:
            port = base.rsplit(":", 1)[1]
            with resolving({"dual.test": ["::1", "127.0.0.1"]}), \
                    mock.patch.object(socket, "create_connection", recording):
                logins = hubmod.Hub("http://dual.test:%s" % port, KEY).logins()
            self.assertEqual(len(logins), 4)
            self.assertEqual(stats.snapshot()["calls"].get("auth-files"), 1)
            # Only the checked answers are ever tried, the first one first.
            self.assertEqual(set(tried), {"::1", "127.0.0.1"})
            self.assertEqual(tried[0], "::1")
        finally:
            server.shutdown()
            server.server_close()

    def test_a_refusal_outlives_the_helper(self):
        server, stats, base = stub_cpa_hub.start(KEY, "stock", "401")
        try:
            first, out = service(base)
            first.run_pass()
            state = out[-1]["state"]
            self.assertEqual(stats.snapshot()["total"], 1)
            self.assertEqual(state["refusal"]["code"], "key_rejected")
            self.assertNotIn(KEY, json.dumps(state))
            # A new helper (panel toggle, reload, restart) given the saved state sends nothing.
            second, out2 = service(base, state=state)
            second.run_pass(force=True)
            second.run_pass(force=True)
            self.assertEqual(stats.snapshot()["total"], 1)
            self.assertEqual(out2[-1]["hub"]["state"], "key_rejected")
            # A replaced key is tried again.
            third, _ = service(base, key=KEY + "-replaced", state=state)
            third.run_pass()
            self.assertEqual(stats.snapshot()["total"], 2)
        finally:
            server.shutdown()
            server.server_close()

    def test_a_login_without_a_name_gets_a_neutral_label(self):
        def http(method, url, headers, data, timeout, **_):
            if url.endswith("auth-files"):
                return core.Response(200, {}, json.dumps({"files": [
                    {"id": "zz-raw-login-2", "auth_index": "1", "provider": "codex"},
                    {"id": "aa-raw-login-1", "auth_index": "2", "provider": "codex"},
                    {"id": "mm-raw-login-3", "auth_index": "3", "provider": "claude"}]}))
            return core.Response(200, {}, '{"status_code":500,"header":{},"body":""}')

        svc, out = service("http://127.0.0.1:1", http=http)
        svc.run_pass()
        self.assertEqual([a["label"] for a in out[-1]["accounts"]],
                         ["Codex account 2", "Codex account 1", "Claude account 1"])
        self.assertNotIn("raw-login", json.dumps(out))


class Reconciliation(unittest.TestCase):
    def test_login_removed_only_after_two_listings_lack_it(self):
        listings = [
            [{"id": "a", "auth_index": "1", "provider": "codex", "email": "a@x"},
             {"id": "b", "auth_index": "2", "provider": "codex", "email": "b@x"}],
            [{"id": "a", "auth_index": "1", "provider": "codex", "email": "a@x"}],
            [{"id": "a", "auth_index": "1", "provider": "codex", "email": "a@x"}],
        ]
        svc, _ = service("http://127.0.0.1:1", http=lambda *a, **k: None)
        for index, files in enumerate(listings):
            svc.hub.logins = lambda files=files: hubmod.listing({"files": files})
            svc.list_logins(0)
            labels = [svc.accounts[k].login.label for k in svc.order]
            self.assertEqual(labels, [["a@x", "b@x"], ["a@x", "b@x"], ["a@x"]][index])


class ClaudeWindow(unittest.TestCase):
    def test_429_window_is_honoured_and_persisted(self):
        calls = []

        def http(method, url, headers, data, timeout, **_):
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
