"""Keepalive's management calls: the quota helper's transport and refusal gate."""
from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "quota"))
sys.path.insert(0, os.path.join(ROOT, "providers"))
sys.path.insert(0, os.path.join(ROOT, "fixtures"))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import cpa_keepalive  # noqa: E402
import hub as hubmod  # noqa: E402
import stub_cpa_hub  # noqa: E402
from test_hub import KEY  # noqa: E402


class Recorder:
    """A loopback stand-in for an environment proxy: counts what reaches it."""

    def __init__(self) -> None:
        self.requests = 0
        recorder = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:
                pass

            def _any(self) -> None:
                recorder.requests += 1
                self.send_response(502)
                self.send_header("Content-Length", "0")
                self.end_headers()

            do_GET = do_POST = do_CONNECT = _any

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def write_config(folder: str, base: str) -> str:
    config = os.path.join(folder, "cpa-agents.json")
    with open(config, "w", encoding="utf-8") as handle:
        # No inference key, so no inference call: only management calls go out.
        json.dump({"baseUrl": base, "adminKey": KEY, "inferenceUrl": "https://inference.invalid/v1"}, handle)
    return config


def run_keepalive(base: str) -> list:
    folder = tempfile.mkdtemp(prefix="keepalive-test-")
    try:
        out = io.StringIO()
        argv = ["cpa_keepalive.py", "--cpa-config", write_config(folder, base)]
        with mock.patch.object(cpa_keepalive, "_inference_key", lambda: ""), \
                mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(out):
            cpa_keepalive.main()
        return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]
    finally:
        shutil.rmtree(folder, ignore_errors=True)


class Transport(unittest.TestCase):
    """Keepalive as the drawer runs it: its own process, with an environment proxy set."""

    def setUp(self):
        self.proxy = Recorder()
        self.folder = tempfile.mkdtemp(prefix="keepalive-test-")

    def tearDown(self):
        self.proxy.close()
        shutil.rmtree(self.folder, ignore_errors=True)

    def run_process(self, base: str) -> list:
        env = {k: v for k, v in os.environ.items()
               if k.lower() not in ("no_proxy", "http_proxy", "https_proxy", "all_proxy", "cpa_api_key")}
        # A home with no cpa.conf, so there is no inference key either.
        env.update({"HOME": self.folder, "USERPROFILE": self.folder, "PYTHONDONTWRITEBYTECODE": "1",
                    "HTTP_PROXY": self.proxy.url, "HTTPS_PROXY": self.proxy.url})
        result = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts", "cpa_keepalive.py"),
                                 "--cpa-config", write_config(self.folder, base)],
                                env=env, capture_output=True, text=True, timeout=60)
        return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]

    def test_an_environment_proxy_never_sees_the_key(self):
        server, stats, base = stub_cpa_hub.start(KEY, "stock")
        try:
            lines = self.run_process(base)
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual(self.proxy.requests, 0)
        self.assertEqual(stats.snapshot()["calls"].get("auth-files"), 1)
        self.assertTrue(lines[-1]["ok"], lines[-1])

    def test_plain_http_needs_a_checked_address(self):
        # A public address (TEST-NET-3, never routed): refused before anything is sent.
        lines = self.run_process("http://203.0.113.9:8317")
        self.assertEqual(self.proxy.requests, 0)
        self.assertEqual(lines, [{"ok": False, "error": "auth-files failed: insecure"}])

    def test_an_environment_proxy_never_sees_the_inference_key(self):
        # The inference key is a separate secret from the management key, and it
        # must not follow HTTPS_PROXY either.
        with mock.patch.dict(os.environ, {"HTTP_PROXY": self.proxy.url, "HTTPS_PROXY": self.proxy.url,
                                          "http_proxy": self.proxy.url, "https_proxy": self.proxy.url,
                                          "NO_PROXY": ""}, clear=False):
            ok, error = cpa_keepalive._chat_completion(
                "https://inference.invalid/v1/chat/completions", "SENTINEL-INFERENCE-KEY", "gpt-5.6-luna")
        self.assertFalse(ok)
        self.assertEqual(self.proxy.requests, 0, "the inference key reached the environment proxy")
        self.assertNotIn("SENTINEL-INFERENCE-KEY", json.dumps({"error": error}))


class Refusal(unittest.TestCase):
    def check(self, refuse, code, requests):
        server, stats, base = stub_cpa_hub.start(KEY, "stock", refuse)
        try:
            lines = run_keepalive(base)
        finally:
            server.shutdown()
            server.server_close()
        # The refusal is the last request sent with that key.
        self.assertEqual(stats.snapshot()["total"], requests)
        refused = [line for line in lines if line.get("type") == "refused"]
        self.assertEqual(len(refused), 1, lines)
        record = refused[0]["refusal"]
        self.assertEqual(record["code"], code)
        # The quota helper's own record, so the drawer and helper honour it.
        self.assertTrue(hubmod.refusal_matches(record, KEY))
        self.assertNotIn(KEY, json.dumps(lines))
        self.assertFalse(lines[-1]["ok"])

    def test_a_401_to_api_call_stops_keepalive(self):
        self.check("api-401", "key_rejected", 2)

    def test_a_ban_stops_keepalive(self):
        self.check("ban", "banned", 1)


if __name__ == "__main__":
    unittest.main()
