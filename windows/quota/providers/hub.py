# Ported from OpenUsage (https://github.com/robinebers/openusage) at commit
# 629f1740, MIT License, Copyright (c) 2026 Robin Ebers. Sources:
#   Sources/OpenUsage/Services/CLIProxyHubClient.swift
#   Sources/OpenUsage/Models/CLIProxyHub.swift
# See THIRD_PARTY_NOTICES.md for the license text.
"""CLIProxyAPI hub mode: the hub's logins, read through its `api-call` tunnel.

`GET /v0/management/auth-files` lists the logins. `POST /v0/management/api-call`
sends a request upstream as one login, with the hub's own token in place of
`$TOKEN$`, and answers `{status_code, header, body}`. The token never reaches
this process.

CLIProxyAPI bans an IP for 30 minutes after five wrong keys, so calls to the hub
go one at a time, and once the hub rejects the key (401) or reports a ban, no
further call is sent with that key. Only a different key reopens the gate.
"""
from __future__ import annotations

import ipaddress
import json
import threading
import urllib.parse

import core
from core import Response

SUPPORTED = {"codex": "codex", "claude": "claude", "antigravity": "antigravity"}


class HubRefused(Exception):
    """A management answer that is not a success, by what the user can do about it."""

    CLOSES_GATE = {"key_rejected", "banned"}

    def __init__(self, code: str, status: int = 0) -> None:
        super().__init__(code)
        self.code = code
        self.status = status


def classify(response: Response) -> str | None:
    if response.ok:
        return None
    body = response.json()
    message = str(body.get("error") or "").lower() if isinstance(body, dict) else ""
    status = response.status
    if status == 401:
        return "key_rejected"
    if status == 403 and message.startswith("ip banned"):
        return "banned"
    if status == 403 and "remote management disabled" in message:
        return "remote_off"
    if status == 404:
        return "management_off"
    if status == 400 and "auth credential not found" in message:
        return "login_missing"
    if status == 400 and "token" in message:
        return "no_token"
    if status == 502:
        return "upstream_unreachable"
    return "failed"


def normalize_base(url: str) -> str:
    text = (url or "").strip()
    parts = urllib.parse.urlsplit(text)
    path = parts.path
    changed = True
    while changed:
        changed = False
        for suffix in ("/", "/management.html", "/v0/management", "/v1"):
            if path.lower().endswith(suffix):
                path = path[: -len(suffix)]
                changed = True
    return urllib.parse.urlunsplit((parts.scheme.lower(), parts.netloc, path, "", ""))


def allows_key(url: str) -> bool:
    """https anywhere; plain http only to this PC, the local network or a Tailscale peer."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https":
        return bool(parts.hostname)
    if parts.scheme != "http" or not parts.hostname:
        return False
    host = parts.hostname.lower()
    if host == "localhost" or host.endswith(".local") or host.endswith(".ts.net"):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    if address.version == 6:
        return address.is_loopback or address.is_link_local or address in ipaddress.ip_network("fc00::/7")
    return (address.is_loopback or address.is_link_local or address in ipaddress.ip_network("10.0.0.0/8")
            or address in ipaddress.ip_network("172.16.0.0/12") or address in ipaddress.ip_network("192.168.0.0/16")
            or address in ipaddress.ip_network("100.64.0.0/10"))


class Login:
    __slots__ = ("id", "auth_index", "provider", "label", "identity", "keys", "chatgpt_account_id")

    def __init__(self, entry: dict) -> None:
        self.id = str(entry.get("id") or "")
        index = entry.get("auth_index")
        self.auth_index = str(index) if index not in (None, "") else None
        self.provider = str(entry.get("provider") or entry.get("type") or "").lower()
        names = [entry.get(k) for k in ("email", "account", "label", "name")]
        self.label = next((n.strip() for n in names if isinstance(n, str) and n.strip()), self.id)
        token = entry.get("id_token") if isinstance(entry.get("id_token"), dict) else {}
        account_id = token.get("chatgpt_account_id")
        self.chatgpt_account_id = account_id if isinstance(account_id, str) and account_id else None
        email = entry.get("email") if isinstance(entry.get("email"), str) else ""
        # One account per identity: the same login listed twice is read once. A
        # Codex login is per ChatGPT workspace.
        self.identity = (email.strip().lower() or self.id) + ("/" + self.chatgpt_account_id if self.chatgpt_account_id else "")
        # What a CPA Manager summary row may carry for the same login.
        self.keys = {k.strip().lower() for k in (email, entry.get("account"), self.chatgpt_account_id, self.id)
                     if isinstance(k, str) and k.strip()}

    @property
    def kind(self) -> str | None:
        return SUPPORTED.get(self.provider)


def listing(body) -> list:
    """Supported, enabled, callable OAuth logins in hub order."""
    if not isinstance(body, dict) or not isinstance(body.get("files"), list):
        raise HubRefused("bad_listing")
    out = []
    for entry in body["files"]:
        if not isinstance(entry, dict) or not entry.get("id"):
            continue
        if str(entry.get("account_type") or "oauth").lower() != "oauth" or entry.get("disabled") is True:
            continue
        login = Login(entry)
        if login.kind and login.auth_index:
            out.append(login)
    return out


class Hub:
    def __init__(self, base_url: str, key: str, http=core.http_request) -> None:
        self.base_url = normalize_base(base_url)
        self.key = key
        self.http = http
        self._lock = threading.Lock()
        self._refused: tuple | None = None  # (key, code)
        core.REDACTOR.add(key)

    def set_key(self, base_url: str, key: str) -> None:
        with self._lock:
            self.base_url = normalize_base(base_url)
            if key != self.key:
                self.key = key
                core.REDACTOR.add(key)

    @property
    def refusal(self) -> str | None:
        refused = self._refused
        return refused[1] if refused and refused[0] == self.key else None

    def management(self, method: str, path: str, payload: dict | None = None, timeout: float = 15) -> Response:
        if not allows_key(self.base_url):
            raise HubRefused("insecure")
        with self._lock:
            key = self.key
            if self._refused and self._refused[0] == key:
                raise HubRefused(self._refused[1])
            headers = {"Authorization": "Bearer " + key, "Accept": "application/json"}
            data = None
            if payload is not None:
                headers["Content-Type"] = "application/json"
                data = json.dumps(payload).encode("utf-8")
            try:
                response = self.http(method, self.base_url + "/v0/management/" + path, headers, data, timeout)
            except OSError:
                raise HubRefused("unreachable") from None
            code = classify(response)
            if code in HubRefused.CLOSES_GATE:
                self._refused = (key, code)
                core.log("hub refused the management key (%s); not calling it again until the key changes" % code)
            if code:
                raise HubRefused(code, response.status)
            return response

    def logins(self) -> list:
        return listing(self.management("GET", "auth-files").json())

    def call(self, login: Login, method: str, url: str, headers: dict, data: str | None = None,
             timeout: float = 15) -> Response:
        payload = {"auth_index": login.auth_index, "method": method, "url": url, "header": headers}
        if data is not None:
            payload["data"] = data
        envelope = self.management("POST", "api-call", payload, timeout + 10).json()
        if not isinstance(envelope, dict) or core.number(envelope.get("status_code")) is None:
            raise core.ProviderError("parse_failed")
        header = {}
        for name, values in (envelope.get("header") or {}).items():
            if isinstance(values, list) and values:
                header[str(name).lower()] = ", ".join(str(v) for v in values)
            elif isinstance(values, str):
                header[str(name).lower()] = values
        body = envelope.get("body")
        return Response(int(envelope["status_code"]), header, body if isinstance(body, str) else "")
