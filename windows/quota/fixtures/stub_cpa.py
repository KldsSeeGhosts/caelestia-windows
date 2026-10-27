#!/usr/bin/env python3
"""Synthetic read-only CPA management server for the Windows quota smoke.

Test fixture only. It serves the small subset of /v0/management endpoints that
cpa_usage.py reads, with fixed synthetic accounts and usage. It never contacts
a real CPA server and contains no credentials.

Usage:
    py -I stub_cpa.py --port 0 --port-file <path>

The selected port is written to --port-file so the test can point the smoke
profile at it.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

NOW = dt.datetime.now(dt.timezone.utc)
TODAY = NOW.date().isoformat()
RESET_5H = (NOW + dt.timedelta(hours=3)).isoformat()
RESET_WEEK = (NOW + dt.timedelta(days=5)).isoformat()

AUTH_FILES = [
    {
        "provider": "codex",
        "account": "codex@example.test",
        "file_name": "codex.json",
        "auth_index": "codex-0",
        "id_token": {"chatgpt_account_id": "fixture-account"},
        "status": "active",
        "tier": "Pro",
    },
    {
        "provider": "claude",
        "account": "claude@example.test",
        "file_name": "claude.json",
        "auth_index": "claude-0",
        "status": "active",
        "tier": "Max",
    },
]

USAGE = {
    "details": [
        {
            "timestamp": NOW.isoformat(),
            "auth_index": "codex-0",
            "auth_file_snapshot": "codex.json",
            "account_snapshot": "codex@example.test",
            "tokens": {"input_tokens": 1000, "output_tokens": 234},
            "failed": False,
            "resolved_model": "gpt-5.6-luna",
        },
        {
            "timestamp": NOW.isoformat(),
            "auth_index": "claude-0",
            "auth_file_snapshot": "claude.json",
            "account_snapshot": "claude@example.test",
            "tokens": {"input_tokens": 2000, "output_tokens": 468},
            "failed": False,
            "resolved_model": "claude-sonnet-4-6",
        },
    ]
}


def provider_of(account: dict[str, Any]) -> str:
    return str(account.get("auth_provider_snapshot") or account.get("provider") or "").lower()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        # Keep the smoke output free of request noise.
        pass

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            value = json.loads(self.rfile.read(length))
        except Exception:
            return {}
        return value if isinstance(value, dict) else {}

    def _send(self, status: int, value: Any) -> None:
        data = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path
        if path == "/v0/management/auth-files":
            self._send(200, {"files": AUTH_FILES})
        elif path == "/v0/management/usage":
            self._send(200, USAGE)
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path
        body = self._body()

        if path == "/v0/management/monitoring/account-history":
            rows = []
            for account in body.get("accounts") or []:
                provider = provider_of(account)
                rows.append({
                    "row_key": account.get("row_key"),
                    "total_tokens": 987654,
                    "total_requests": 300,
                    "success_rate": 0.99,
                    "plan_type": "pro" if provider == "codex" else "max",
                })
            self._send(200, {"items": rows})
            return

        if path == "/v0/management/quota-snapshots/query":
            rows = []
            for account in body.get("accounts") or []:
                provider = provider_of(account) or str(account.get("provider") or "").lower()
                codex = provider == "codex"
                rows.append({
                    "row_key": account.get("row_key"),
                    "provider": provider,
                    "windows": [
                        {"label": "5-hour", "used_percent": 42 if codex else 71, "resets_at": RESET_5H},
                        {"label": "Weekly", "used_percent": 18 if codex else 35, "resets_at": RESET_WEEK},
                    ],
                })
            self._send(200, {"items": rows})
            return

        if path == "/v0/management/monitoring/account-window-usage":
            rows = []
            for window in body.get("windows") or []:
                rows.append({
                    "request_key": window.get("request_key"),
                    "total_tokens": 1234,
                    "total_requests": 5,
                    "model": "gpt-5.6-luna",
                })
            self._send(200, {"items": rows})
            return

        if path == "/v0/management/api-call":
            url = str(body.get("url") or "")
            if "anthropic.com" in url:
                self._send(200, {
                    "status_code": 200,
                    "body": {
                        "five_hour": {"utilization": 71, "resets_at": RESET_5H},
                        "seven_day": {"utilization": 35, "resets_at": RESET_WEEK},
                    },
                })
            elif "chatgpt.com" in url:
                self._send(200, {
                    "status_code": 200,
                    "body": {
                        "rate_limit": {
                            "primary_window": {
                                "used_percent": 42,
                                "limit_window_seconds": 18000,
                                "reset_at": RESET_5H,
                            },
                            "secondary_window": {
                                "used_percent": 18,
                                "limit_window_seconds": 604800,
                                "reset_at": RESET_WEEK,
                            },
                        },
                        "plan_type": "pro",
                    },
                })
            else:
                self._send(404, {"error": "no upstream"})
            return

        # OpenCode Go has no scrape on this fixture; cpa_usage.py falls back to
        # /v0/management/config, which is absent, then keeps no record.
        self._send(404, {"error": "not found"})


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    args, _ = parser.parse_known_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    print(f"STUB_READY {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
