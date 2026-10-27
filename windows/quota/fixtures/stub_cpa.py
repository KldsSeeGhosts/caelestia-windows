#!/usr/bin/env python3
"""Synthetic read-only CPA management server for the Windows quota smoke.

Test fixture only. It serves CPA Manager's pre-aggregated quota summary with
fixed synthetic providers, accounts and windows, and checks the Bearer header.
It never contacts a real CPA server and contains no credentials or real account
data.

Usage:
    py -I stub_cpa.py --port 0 --port-file <path> [--admin-key <key>]

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
RESET_5H = (NOW + dt.timedelta(hours=3)).isoformat()
RESET_WEEK = (NOW + dt.timedelta(days=5)).isoformat()

AUTH_FILES = {
    "files": [
        {
            "account": "codex@example.test",
            "account_type": "oauth",
            "auth_index": "codex-0",
            "email": "codex@example.test",
            "label": "Codex fixture",
            "name": "codex.json",
            "provider": "codex",
            "status": "active",
            "disabled": False,
            "unavailable": False,
        },
        {
            "account": "claude@example.test",
            "account_type": "oauth",
            "auth_index": "claude-0",
            "email": "claude@example.test",
            "label": "Claude fixture",
            "name": "claude.json",
            "provider": "claude",
            "status": "active",
            "disabled": False,
            "unavailable": False,
        },
    ],
    "observed_at": NOW.isoformat(),
}


def window(
    window_id: str,
    label: str,
    used: int,
    resets_at: str,
    source: str = "provider",
) -> dict[str, Any]:
    return {
        "id": window_id,
        "label": label,
        "usedPercent": used,
        "remainingPercent": 100 - used,
        "resetAt": resets_at,
        "source": source,
    }


# Two Codex accounts, two Claude accounts (one with a model-scoped window) and
# one Z.ai account. Keys mirror CPA Manager's schema; values are synthetic.
SUMMARY = {
    "schemaVersion": 1,
    "generatedAt": NOW.isoformat(),
    "refreshedAt": NOW.isoformat(),
    "ttlMs": 60000,
    "status": "ok",
    "error": None,
    "providers": [
        {
            "id": "codex",
            "label": "Codex",
            "status": "ok",
            "error": None,
            "accounts": [
                {
                    "id": "codex-primary",
                    "label": "codex@example.test",
                    "synthetic": False,
                    "plan": "Pro",
                    "status": "ok",
                    "error": None,
                    "windows": [
                        window("five-hour", "5-hour", 42, RESET_5H),
                        window("weekly", "Weekly", 18, RESET_WEEK),
                    ],
                },
                {
                    "id": "codex-secondary",
                    "label": "codex2@example.test",
                    "synthetic": False,
                    "plan": "Plus",
                    "status": "ok",
                    "error": None,
                    "windows": [
                        window("five-hour", "5-hour", 68, RESET_5H),
                        window("weekly", "Weekly", 55, RESET_WEEK),
                    ],
                },
            ],
        },
        {
            "id": "claude",
            "label": "Claude",
            "status": "ok",
            "error": None,
            "accounts": [
                {
                    "id": "claude-primary",
                    "label": "claude@example.test",
                    "synthetic": False,
                    "plan": "Max",
                    "status": "ok",
                    "error": None,
                    "windows": [
                        window("five-hour", "5-hour", 71, RESET_5H),
                        window("weekly", "Weekly", 35, RESET_WEEK),
                        # Model-scoped: the drawer moves this to "Model limits".
                        window("seven-day-opus", "Weekly", 88, RESET_WEEK),
                    ],
                },
                {
                    "id": "claude-secondary",
                    "label": "claude2@example.test",
                    "synthetic": False,
                    "plan": "Pro",
                    "status": "ok",
                    "error": None,
                    "windows": [
                        window("five-hour", "5-hour", 22, RESET_5H),
                        window("weekly", "Weekly", 61, RESET_WEEK),
                    ],
                },
            ],
        },
        {
            "id": "zai",
            "label": "Z.ai",
            "status": "ok",
            "error": None,
            "accounts": [
                {
                    "id": "zai-primary",
                    "label": "zai@example.test",
                    "synthetic": False,
                    "plan": "GLM Coding",
                    "status": "ok",
                    "error": None,
                    "windows": [
                        window("five-hour", "5-hour", 12, RESET_5H),
                        window("weekly", "Weekly", 8, RESET_WEEK),
                    ],
                }
            ],
        },
    ],
    "todayCostUsd": 3.71,
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    admin_key = "smoke-placeholder"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        # Keep the smoke output free of request noise.
        pass

    def _authorized(self) -> bool:
        header = str(self.headers.get("Authorization") or "")
        return header == "Bearer " + self.admin_key

    def _send(self, status: int, value: Any) -> None:
        data = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {"error": "unauthorized"})
            return
        path = urlsplit(self.path).path
        if path == "/v0/management/quota/summary":
            self._send(200, SUMMARY)
        elif path == "/v0/management/auth-files":
            self._send(200, AUTH_FILES)
        else:
            self._send(404, {"error": "not found"})


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--admin-key", default="smoke-placeholder")
    args, _ = parser.parse_known_args()

    Handler.admin_key = args.admin_key
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
