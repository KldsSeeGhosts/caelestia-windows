"""Shared helpers for the quota provider helper: HTTP, parsing and redaction.

Standard library only. Nothing here logs a request or response body, a header
value, a key or a token. `log()` is the only writer to stderr, and it redacts
every secret registered with `REDACTOR` first.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import sys
import threading
import urllib.error
import urllib.request
from typing import Any

SCHEMA_VERSION = 1

# OpenUsage's refresh rules (RefreshSetting.swift): accounts refresh every
# 5 minutes at most, failures back off from 5 minutes doubling to an hour, and
# plan, resets and history are read hourly.
MIN_INTERVAL_S = 300
SECONDARY_INTERVAL_S = 3600
BACKOFF_MAX_S = 3600
FORCE_SKIP_S = 60


class Redactor:
    """Replaces every registered secret in text before it is written anywhere."""

    def __init__(self) -> None:
        self._secrets: set[str] = set()
        self._lock = threading.Lock()

    def add(self, secret: str | None) -> None:
        if secret and len(secret) >= 4:
            with self._lock:
                self._secrets.add(secret)

    def redact(self, text: str) -> str:
        with self._lock:
            secrets = sorted(self._secrets, key=len, reverse=True)
        for secret in secrets:
            text = text.replace(secret, "[redacted]")
        return text


REDACTOR = Redactor()


def log(message: str) -> None:
    """A short diagnostic line on stderr. Never pass a body or header value."""
    try:
        sys.stderr.write(REDACTOR.redact("quota-providers: " + message) + "\n")
        sys.stderr.flush()
    except (OSError, ValueError):
        pass


class Response:
    def __init__(self, status: int, headers: dict[str, str] | None = None, body: bytes | str = b"") -> None:
        self.status = int(status)
        self.headers = {str(k).lower(): str(v) for k, v in (headers or {}).items()}
        self.body = body.encode("utf-8") if isinstance(body, str) else bytes(body or b"")

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def header(self, name: str) -> str | None:
        return self.headers.get(name.lower())

    def json(self) -> Any:
        try:
            return json.loads(self.body.decode("utf-8") or "null")
        except (UnicodeDecodeError, ValueError):
            return None

    def retry_after(self, now: float) -> float | None:
        """Seconds to wait from a Retry-After header (seconds or an HTTP date)."""
        value = self.header("retry-after")
        if not value:
            return None
        seconds = number(value)
        if seconds is not None:
            return max(0.0, seconds)
        try:
            from email.utils import parsedate_to_datetime

            return max(0.0, parsedate_to_datetime(value).timestamp() - now)
        except (TypeError, ValueError, IndexError):
            return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # urllib copies the Authorization header onto a redirect, even to another
    # host. The management key must only ever go to the configured address.
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def http_request(method: str, url: str, headers: dict[str, str] | None = None,
                 body: bytes | None = None, timeout: float = 15) -> Response:
    """One HTTP request with a timeout and no redirects. Raises OSError on transport failure."""
    request = urllib.request.Request(url, data=body, method=method, headers=dict(headers or {}))
    try:
        with _OPENER.open(request, timeout=timeout) as reply:
            return Response(reply.status, dict(reply.headers.items()), reply.read())
    except urllib.error.HTTPError as error:
        try:
            data = error.read()
        except OSError:
            data = b""
        return Response(error.code, dict(error.headers.items()) if error.headers else {}, data)
    except urllib.error.URLError as error:
        raise OSError("transport failed") from error


# -- Parsing -----------------------------------------------------------------

def number(value: Any) -> float | None:
    """A finite number from a JSON number or numeric string; None for null, bools and junk."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        result = float(value)
    elif isinstance(value, str):
        try:
            result = float(value.strip())
        except ValueError:
            return None
    else:
        return None
    return result if math.isfinite(result) else None


def obj(value: Any) -> dict:
    return value if isinstance(value, dict) else {}


def items(value: Any) -> list:
    return value if isinstance(value, list) else []


def parse_time(value: Any) -> float | None:
    """Epoch seconds from an ISO 8601 string or a number of seconds or milliseconds."""
    if isinstance(value, str) and value.strip():
        text = value.strip()
        seconds = number(text)
        if seconds is None:
            try:
                parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
            except ValueError:
                return None
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
            return parsed.timestamp()
        value = seconds
    seconds = number(value)
    if seconds is None:
        return None
    return seconds / 1000 if abs(seconds) >= 1e10 else seconds


def iso(seconds: float | None) -> str:
    if seconds is None:
        return ""
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat().replace("+00:00", "Z")


def utc_date(seconds: float) -> str:
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).strftime("%Y-%m-%d")


def window(window_id: str, label: str, used_percent: float | None, reset_at: float | None) -> dict:
    """One window in CPA Manager's summary shape, which the drawer already maps."""
    used = None if used_percent is None else max(0.0, min(100.0, used_percent))
    return {"id": window_id, "label": label, "usedPercent": used, "resetAt": iso(reset_at)}


def title_case(raw: str, separator: str = "_") -> str:
    return " ".join(part[:1].upper() + part[1:].lower() for part in raw.split(separator) if part)


def mask_label(text: str) -> str:
    """What the drawer may show of a login: an email's local part, or a file name without .json."""
    text = (text or "").strip()
    if "@" in text:
        return text.split("@", 1)[0]
    return text[:-5] if text.lower().endswith(".json") else text


class ProviderError(Exception):
    """A failed read, by the drawer's error code (see Quota.qml friendlyError)."""

    def __init__(self, code: str, retry_after: float | None = None) -> None:
        super().__init__(code)
        self.code = code
        self.retry_after = retry_after


def require_json(response: Response, now: float) -> dict:
    """The JSON object of a successful provider response, or the matching ProviderError."""
    if response.status in (401, 403):
        raise ProviderError("unauthorized")
    if response.status == 429:
        raise ProviderError("rate_limited", response.retry_after(now))
    if response.status == 404:
        raise ProviderError("not_found")
    if not response.ok:
        raise ProviderError("error")
    body = response.json()
    if not isinstance(body, dict):
        raise ProviderError("parse_failed")
    return body
