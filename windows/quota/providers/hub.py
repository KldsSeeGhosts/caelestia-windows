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

import hashlib
import ipaddress
import json
import secrets
import socket
import threading
import time
import urllib.parse

import core
from core import Response

SUPPORTED = {"codex": "codex", "claude": "claude", "antigravity": "antigravity"}
LABELS = {"codex": "Codex", "claude": "Claude", "antigravity": "Antigravity"}


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


# Where plain http may carry the key: this PC, RFC 1918 networks and Tailscale
# (CGNAT and its IPv6 range). Link-local and other unique-local addresses are not.
PLAIN_HTTP_NETWORKS = tuple(ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "100.64.0.0/10", "fd7a:115c:a1e0::/48"))


def key_addresses(url: str) -> list | None:
    """Where the key may be sent for url: None for https (TLS checks the name),
    else the resolved addresses to connect to, in the resolver's order. Plain
    http needs every address the host resolves to inside PLAIN_HTTP_NETWORKS;
    names are never trusted."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https" and parts.hostname:
        return None
    if parts.scheme != "http" or not parts.hostname:
        raise HubRefused("insecure")
    try:
        infos = socket.getaddrinfo(parts.hostname, parts.port or 80, type=socket.SOCK_STREAM)
        addresses = [ipaddress.ip_address(str(info[4][0]).split("%")[0]) for info in infos]
    except (OSError, UnicodeError, ValueError):
        raise HubRefused("unreachable") from None
    if not addresses or not all(any(a in n for n in PLAIN_HTTP_NETWORKS) for a in addresses):
        raise HubRefused("insecure")
    return list(dict.fromkeys(str(a) for a in addresses))


def allows_key(url: str) -> bool:
    try:
        key_addresses(url)
        return True
    except HubRefused:
        return False


def fingerprint(salt: str, key: str) -> str:
    """A non-reversible tag of a key, so a refusal can outlive the helper without the key."""
    return hashlib.sha256((salt + "\0" + key).encode("utf-8")).hexdigest()[:16]


def refusal_matches(record, key: str) -> bool:
    return (isinstance(record, dict) and isinstance(record.get("salt"), str) and bool(key)
            and record.get("code") in HubRefused.CLOSES_GATE
            and record.get("fingerprint") == fingerprint(record["salt"], key))


class Login:
    __slots__ = ("id", "auth_index", "provider", "label", "identity", "keys", "chatgpt_account_id")

    def __init__(self, entry: dict) -> None:
        self.id = str(entry.get("id") or "")
        index = entry.get("auth_index")
        self.auth_index = str(index) if index not in (None, "") else None
        self.provider = str(entry.get("provider") or entry.get("type") or "").lower()
        names = [entry.get(k) for k in ("email", "account", "label", "name")]
        # No name: listing() gives a neutral one. The raw id never leaves the helper.
        self.label = next((n.strip() for n in names if isinstance(n, str) and n.strip()), "")
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
    numbered: dict = {}
    for login in sorted((l for l in out if not l.label), key=lambda l: l.id):
        numbered[login.kind] = numbered.get(login.kind, 0) + 1
        login.label = "%s account %d" % (LABELS[login.kind], numbered[login.kind])
    return out


BAN_S = 30 * 60


class Hub:
    def __init__(self, base_url: str, key: str, http=core.http_request, clock=time.time) -> None:
        self.base_url = normalize_base(base_url)
        self.key = key
        self.http = http
        self.clock = clock
        self._lock = threading.Lock()
        # {salt, fingerprint, code, until}: persisted by the drawer, never the key.
        self.refused: dict | None = None
        core.REDACTOR.add(key)

    def set_key(self, base_url: str, key: str) -> None:
        with self._lock:
            self.base_url = normalize_base(base_url)
            if key != self.key:
                self.key = key
                core.REDACTOR.add(key)

    def restore_refusal(self, record) -> None:
        if refusal_matches(record, self.key):
            self.refused = dict(record)

    @property
    def refusal(self) -> str | None:
        return self.refused["code"] if refusal_matches(self.refused, self.key) else None

    def management(self, method: str, path: str, payload: dict | None = None, timeout: float = 15) -> Response:
        with self._lock:
            key = self.key
            if refusal_matches(self.refused, key):
                raise HubRefused(self.refused["code"])
            # Resolved and checked on every call, then connected only to those
            # addresses, so a second DNS answer cannot redirect the key.
            addresses = key_addresses(self.base_url)
            headers = {"Authorization": "Bearer " + key, "Accept": "application/json"}
            data = None
            if payload is not None:
                headers["Content-Type"] = "application/json"
                data = json.dumps(payload).encode("utf-8")
            pin = {} if addresses is None else {"addresses": addresses}
            try:
                response = self.http(method, self.base_url + "/v0/management/" + path, headers, data, timeout, **pin)
            except OSError:
                raise HubRefused("unreachable") from None
            code = classify(response)
            if code in HubRefused.CLOSES_GATE:
                salt = secrets.token_hex(8)
                self.refused = {"salt": salt, "fingerprint": fingerprint(salt, key), "code": code,
                                "until": int((self.clock() + BAN_S) * 1000) if code == "banned" else 0}
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
