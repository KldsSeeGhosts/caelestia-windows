#!/usr/bin/env python3
"""Synthetic CLIProxyAPI hub for the quota helper tests and the hub smoke.

Test fixture only. It binds loopback, never contacts a real CPA server or
provider, and holds no real credentials or account data. It serves:

  GET  /v0/management/auth-files   a fixed login list
  POST /v0/management/api-call     answers the provider URLs of codex, claude and
                                   antigravity with synthetic JSON shaped like the
                                   real endpoints, as {status_code, header, body}
  GET  /v0/management/quota/summary  404 for stock CPA, or a CPA Manager summary
  GET  /__stats                    call counts and the most api-calls seen at once

Usage:
    py -I stub_cpa_hub.py --port-file <path> [--admin-key K] [--scenario stock|manager]
                          [--refuse none|401|api-401|ban] [--host 127.0.0.1|127.0.0.2]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlsplit

# A value a leak check looks for. The listing carries it the way a careless hub
# build might; the helper must never repeat it.
SENTINEL_TOKEN = "SENTINEL-TOKEN-91c2e7"
SENTINEL_LOGIN_ID = "SENTINEL-LOGIN-ID-4f8a21"
DEFAULT_KEY = "smoke-placeholder"


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _iso(when: dt.datetime) -> str:
    return when.isoformat().replace("+00:00", "Z")


AUTH_FILES = {
    "files": [
        {"id": "codex-main.json", "auth_index": "a1", "provider": "codex", "account_type": "oauth",
         "email": "codex.hub@example.test", "id_token": {"chatgpt_account_id": "acct-synthetic-1"},
         "access_token": SENTINEL_TOKEN},
        {"id": "claude-main.json", "auth_index": "a2", "type": "claude", "account_type": "oauth",
         "email": "claude.hub@example.test", "access_token": SENTINEL_TOKEN},
        # The same Claude login listed twice: one usage read per identity.
        {"id": "claude-copy.json", "auth_index": "a3", "type": "claude", "account_type": "oauth",
         "email": "Claude.Hub@example.test"},
        # No email or name: the drawer must get a neutral label, never this id.
        {"id": SENTINEL_LOGIN_ID, "auth_index": "a4", "provider": "antigravity", "account_type": "oauth"},
        {"id": "gemini-cli.json", "auth_index": "a5", "provider": "gemini-cli", "account_type": "oauth",
         "email": "unsupported@example.test"},
        {"id": "codex-off.json", "auth_index": "a6", "provider": "codex", "account_type": "oauth",
         "email": "off@example.test", "disabled": True},
        {"id": "codex-key.json", "auth_index": "a7", "provider": "codex", "account_type": "api_key",
         "label": "api key login"},
    ]
}


def codex_usage() -> dict:
    now = time.time()
    return {
        "plan_type": "pro",
        "rate_limit": {
            "primary_window": {"used_percent": 34, "limit_window_seconds": 18000, "reset_after_seconds": 7200},
            "secondary_window": {"used_percent": 72, "limit_window_seconds": 604800, "reset_at": int(now + 3 * 86400)},
        },
        "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
            "rate_limit": {"primary_window": {"used_percent": 8, "limit_window_seconds": 18000, "reset_after_seconds": 9000}},
        }],
        "rate_limit_reset_credits": {"available_count": 2},
        "credits": {"has_credits": False, "balance": None},
    }


def codex_credits() -> dict:
    now = _now()
    return {"available_count": 2, "credits": [
        {"id": "cr-1", "status": "available", "expires_at": _iso(now + dt.timedelta(hours=30))},
        {"id": "cr-2", "status": "available", "expires_at": _iso(now + dt.timedelta(days=5))},
        {"id": "cr-0", "status": "redeemed", "expires_at": _iso(now + dt.timedelta(days=9))},
    ]}


MODELS = (("gpt-5.3-codex", 0.62), ("gpt-5.3-codex-spark", 0.23), ("gpt-5.2", 0.15))


def codex_history(start: str, end: str) -> dict:
    first = dt.date.fromisoformat(start)
    last = dt.date.fromisoformat(end)
    data = []
    day = first
    index = 0
    while day <= last:
        total = 4_000_000 + (index * 1_370_000) % 21_000_000
        cached = int(total * 0.81)
        output = int(total * 0.04)
        data.append({
            "date": day.isoformat(),
            "totals": {"turns": 40 + index, "text_total_tokens": total, "cached_text_input_tokens": cached,
                       "uncached_text_input_tokens": total - cached - output, "text_output_tokens": output},
            "models": [{"model": name, "turns": 10, "text_total_tokens": int(total * share)} for name, share in MODELS],
        })
        day += dt.timedelta(days=1)
        index += 1
    return {"data": data}


def claude_usage() -> dict:
    now = _now()
    return {
        "five_hour": {"utilization": 58.0, "resets_at": _iso(now + dt.timedelta(hours=2, minutes=10))},
        "seven_day": {"utilization": 77.0, "resets_at": _iso(now + dt.timedelta(days=4))},
        "seven_day_sonnet": {"utilization": 12.0, "resets_at": _iso(now + dt.timedelta(days=4))},
        "seven_day_opus": None,
        "limits": [{"kind": "weekly_scoped", "percent": 91, "resets_at": _iso(now + dt.timedelta(days=4)),
                    "scope": {"model": {"display_name": "Fable"}}}],
        "extra_usage": {"is_enabled": False},
    }


def claude_grants() -> dict:
    now = _now()
    return {"cedar_ember": {"eligible": True, "next_grant_id": "g-1", "grants": [
        {"id": "g-1", "resets_left": 1, "ends_at": _iso(now + dt.timedelta(days=2, hours=6)), "clears": ["five_hour"]},
        {"id": "g-0", "resets_left": 0, "ends_at": _iso(now + dt.timedelta(days=9))},
    ]}}


def claude_profile() -> dict:
    return {"account": {"uuid": "00000000-0000-4000-8000-000000000001"},
            "organization": {"uuid": "00000000-0000-4000-8000-000000000002",
                             "organization_type": "claude_max", "rate_limit_tier": "default_claude_max_5x"}}


def antigravity_load() -> dict:
    return {"cloudaicompanionProject": "synthetic-project-1", "currentTier": {"id": "standard-tier", "name": "Standard"},
            "paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"}}


def antigravity_summary() -> dict:
    now = _now()
    reset = _iso(now + dt.timedelta(hours=3))
    week = _iso(now + dt.timedelta(days=6))
    return {"response": {"groups": [
        {"displayName": "Gemini", "buckets": [
            {"bucketId": "gemini-5h", "remainingFraction": 0.81, "resetTime": reset, "window": "5h"},
            {"bucketId": "gemini-weekly", "remainingFraction": 0.64, "resetTime": week, "window": "weekly"}]},
        {"displayName": "Gemini 4 Argon", "buckets": [
            {"bucketId": "argon-weekly", "remainingFraction": 0.95, "resetTime": week, "window": "weekly"}]},
        {"displayName": "Third party", "buckets": [
            {"bucketId": "3p-5h", "remainingFraction": 0.27, "resetTime": reset, "window": "5h"},
            {"bucketId": "3p-weekly", "remainingFraction": 0.55, "resetTime": week, "window": "weekly"}]},
    ]}}


def manager_summary() -> dict:
    """A CPA Manager summary naming the same Codex login, so the drawer must dedupe it."""
    now = _now()
    return {
        "schemaVersion": 1, "generatedAt": _iso(now), "refreshedAt": _iso(now), "ttlMs": 60000,
        "status": "ok", "error": None, "todayCostUsd": 1.25,
        "providers": [{"id": "codex", "label": "Codex", "status": "ok", "error": None, "accounts": [{
            "id": "codex-hub-row", "label": "codex.hub@example.test", "plan": "Pro", "status": "ok", "error": None,
            "windows": [{"id": "five-hour", "label": "5-hour", "usedPercent": 30, "resetAt": _iso(now + dt.timedelta(hours=2))},
                        {"id": "weekly", "label": "Weekly", "usedPercent": 70, "resetAt": _iso(now + dt.timedelta(days=3))}],
        }]}],
    }


class Stats:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.calls: dict[str, int] = {}
        self.in_flight = 0
        self.max_in_flight = 0
        self.bad_token_headers = 0

    def count(self, name: str) -> None:
        with self.lock:
            self.calls[name] = self.calls.get(name, 0) + 1

    def snapshot(self) -> dict:
        with self.lock:
            return {"calls": dict(self.calls), "total": sum(self.calls.values()),
                    "maxInFlight": self.max_in_flight, "badTokenHeaders": self.bad_token_headers}


def upstream(method: str, url: str, header: dict) -> tuple[int, Any]:
    parts = urlsplit(url)
    path = parts.path
    query = parse_qs(parts.query)
    if parts.netloc == "chatgpt.com":
        if path.endswith("/wham/usage"):
            return 200, codex_usage()
        if path.endswith("/wham/rate-limit-reset-credits"):
            return 200, codex_credits()
        if path.endswith("/wham/analytics/daily-workspace-usage-counts"):
            return 200, codex_history(query["start_date"][0], query["end_date"][0])
    if parts.netloc == "api.anthropic.com":
        if path == "/api/oauth/usage" and query.get("cedar_ember"):
            return 200, claude_grants()
        if path == "/api/oauth/usage":
            return 200, claude_usage()
        if path == "/api/oauth/profile":
            return 200, claude_profile()
    if parts.netloc in ("cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com"):
        if path.endswith(":loadCodeAssist"):
            return 200, antigravity_load()
        if path.endswith(":retrieveUserQuotaSummary"):
            return 200, antigravity_summary()
    return 404, {"error": "not found"}


def make_handler(admin_key: str, scenario: str, refuse: str, stats: Stats, delay: float):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            pass

        def _send(self, status: int, value: Any) -> None:
            data = json.dumps(value, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _gate(self, name: str) -> bool:
            stats.count(name)
            # api-401: the listing is accepted, then the first api-call is refused.
            if (refuse == "401" or (refuse == "api-401" and name == "api-call")
                    or self.headers.get("Authorization") != "Bearer " + admin_key):
                self._send(401, {"error": "invalid management key"})
                return False
            if refuse == "ban":
                self._send(403, {"error": "IP banned due to too many failed attempts. Try again in 29m"})
                return False
            return True

        def do_GET(self) -> None:  # noqa: N802
            path = urlsplit(self.path).path
            if path == "/__stats":
                self._send(200, stats.snapshot())
            elif path == "/v0/management/auth-files":
                if self._gate("auth-files"):
                    self._send(200, AUTH_FILES)
            elif path == "/v0/management/quota/summary":
                if self._gate("summary"):
                    if scenario == "manager":
                        self._send(200, manager_summary())
                    else:
                        self._send(404, {"error": "not found"})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            path = urlsplit(self.path).path
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if path != "/v0/management/api-call":
                stats.count("other")
                self._send(404, {"error": "not found"})
                return
            if not self._gate("api-call"):
                return
            with stats.lock:
                stats.in_flight += 1
                stats.max_in_flight = max(stats.max_in_flight, stats.in_flight)
            try:
                time.sleep(delay)
                payload = json.loads(raw or b"{}")
                header = payload.get("header") or {}
                if header.get("Authorization") != "Bearer $TOKEN$":
                    with stats.lock:
                        stats.bad_token_headers += 1
                url = str(payload.get("url") or "")
                stats.count("api:" + str(payload.get("auth_index")) + ":" + urlsplit(url).netloc + urlsplit(url).path)
                status, body = upstream(str(payload.get("method") or "GET"), url, header)
                self._send(200, {"status_code": status, "header": {"Content-Type": ["application/json"]},
                                 "body": json.dumps(body)})
            finally:
                with stats.lock:
                    stats.in_flight -= 1

    return Handler


def start(admin_key: str = DEFAULT_KEY, scenario: str = "stock", refuse: str = "none", delay: float = 0.02):
    """Start the stub on a loopback port in this process: (server, stats, base_url)."""
    stats = Stats()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(admin_key, scenario, refuse, stats, delay))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, stats, "http://127.0.0.1:%d" % server.server_address[1]


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--admin-key", default=DEFAULT_KEY)
    parser.add_argument("--scenario", choices=("stock", "manager"), default="stock")
    parser.add_argument("--refuse", choices=("none", "401", "api-401", "ban"), default="none")
    # Another loopback address (127.0.0.2) stands in for a hub on the local network.
    parser.add_argument("--host", choices=("127.0.0.1", "127.0.0.2"), default="127.0.0.1")
    args, _ = parser.parse_known_args()
    stats = Stats()
    server = ThreadingHTTPServer((args.host, 0), make_handler(args.admin_key, args.scenario, args.refuse, stats, 0.02))
    server.daemon_threads = True
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
