#!/usr/bin/env python3
"""Collect read-only CPA management usage into Agents records.

The management key is read from a mode-600 local configuration file and is
only ever sent as an HTTP header.  This collector deliberately accepts the
minor response-shape variations used by CPA releases; the panel consumes the
stable Agents record contract below rather than CPA's wire format.
"""
from __future__ import annotations

import datetime as dt
import argparse
import base64
import concurrent.futures
import hashlib
import json
import math
import os
import re
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

AGENT_PREFIX = "cpa-"
SCHEMA = 1

# Auth files in these provider groups share one plan, so their token usage
# is pooled into a single ledger (daily charts, per-model table, totals).
# Windows and their meters stay per-account — only tokens are pooled.
POOL_GROUPS: tuple[tuple[str, set[str]], ...] = (("openai", {"codex"}), ("google", {"antigravity"}))

# Providers whose per-account windows and all-time history CPA meters through
# the monitoring endpoints. Anything else (cursor today) has no monitoring
# coverage — quota queries are rejected and account-history matches nothing —
# so those records derive their stats from the plain request log instead.
QUOTA_PROVIDERS = {"codex", "claude", "antigravity", "kimi", "xai"}

# CPA only stores quota *snapshots* for codex, and those go stale the moment
# the upstream window rolls over or CPA has not proxied a request lately. The
# quota tooling therefore asks ChatGPT's usage endpoint directly through
# /v0/management/api-call, which fires the call with the account's own
# credential ($TOKEN$ substitution server-side). That live reading is the
# primary source for codex; stored snapshots are only the fallback.
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CODEX_USAGE_HEADERS = {
    "Authorization": "Bearer $TOKEN$",
    "Content-Type": "application/json",
    "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
}
# Windows are labeled from their own length, not their position: accounts
# report whichever windows their plan carries in either slot.
CODEX_WINDOW_SECONDS = {18000: "5-hour", 604800: "Weekly"}

# Use the same credential proxy as CPA Manager. OAuth tokens and refresh
# ownership stay on the server; no local Claude credential copy is needed.
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_USAGE_HEADERS = {
    "Authorization": "Bearer $TOKEN$",
    "Content-Type": "application/json",
    "anthropic-beta": "oauth-2025-04-20",
}
CLAUDE_WINDOW_LABELS = {
    "five_hour": "5-hour",
    "seven_day": "Weekly",
    "seven_day_oauth_apps": "OAuth apps · Weekly",
    "seven_day_opus": "Opus · Weekly",
    "seven_day_sonnet": "Sonnet · Weekly",
    "seven_day_cowork": "Cowork · Weekly",
}
CLAUDE_QUOTA_TTL_MS = 60000
CLAUDE_RETRY_MS = 300000

# Cursor never appears in CPA's quota-snapshots — its dashboard lives behind
# api2.cursor.sh and is fetched live through the same credential proxy. The
# same shape is rendered by the CPA Manager web (see utils/quota/constants +
# providerRequests + quotaConfigs: CURSOR_USAGE_URL, buildCursorUsageSummary,
# renderCursorItems).
CURSOR_USAGE_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
CURSOR_PROFILE_URL = "https://api2.cursor.sh/auth/full_stripe_profile"
CURSOR_USAGE_HEADERS = {
    "Authorization": "Bearer $TOKEN$",
    "Content-Type": "application/json",
}

# OpenCode Go is not a CPA auth file at all — its quota lives behind the
# opencode.ai Go dashboard. CPA Manager builds scrape it on demand and serve
# them at the management endpoint below; plain CPA builds don't, so the same
# data is fetched straight from opencode.ai's Zen Go usage endpoint using the
# API key CPA stores in its openai-compatibility entry.
OPENCODE_GO_ID = AGENT_PREFIX + "opencode-go"
OPENCODE_GO_WINDOWS = (("rolling", "5-hour"), ("weekly", "Weekly"), ("monthly", "Monthly"))
OPENCODE_GO_USAGE_URL = "https://opencode.ai/zen/go/v1/usage"

ANTIGRAVITY_MODEL_URLS = [
    "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
]
# retrieveUserQuotaSummary reports two real buckets per model group: the
# 5-hour burst and the weekly allocation. Using it as the primary source
# lets the panel show all four meters (Gemini 5-hour/Weekly + Claude/GPT
# 5-hour/Weekly) instead of compressing each group to a single bar the way
# fetchAvailableModels alone does.
ANTIGRAVITY_SUMMARY_URLS = [
    "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
    "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
    "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
]
# The panel wants two meters, not Google's per-model buckets: one for the
# Claude/GPT pool and one for every Gemini model (image included).
ANTIGRAVITY_MODEL_GROUPS = [
    ("Claude/GPT", ["claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b-medium"]),
    ("Gemini", [
        "gemini-3.1-pro-high", "gemini-3.1-pro-low",
        "gemini-3-pro-high", "gemini-3-pro-low",
        "gemini-3.1-flash-image",
        "gemini-3-flash",
        "gemini-2.5-flash", "gemini-2.5-flash-thinking",
        "gemini-2.5-flash-lite",
        "rev19-uic3-1p",
    ]),
]


def _path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def usage_dir() -> Path:
    return _path(os.environ.get("XDG_STATE_HOME", "~/.local/state")) / "omarchy/agents/usage"


# The /v0/management/usage request log is ~100MB (50k capped entries) and the
# CPA box serves it at ~10MB/s, so a bare fetch costs ~10s of every refresh.
# The log only feeds the 7-day charts and the per-model-today table — the
# quota meters come from the monitoring endpoints — so it is cached locally
# and refetched only when the TTL lapses or the local day rolls over.
LOG_CACHE_TTL_MS = 60 * 1000


def log_cache_path() -> Path:
    cache_root = _path(os.environ.get("XDG_CACHE_HOME", "~/.cache"))
    return cache_root / "caelestia" / "cpa-usage-log.json"


def read_log_cache(allow_stale: bool = False) -> dict[str, Any] | None:
    try:
        with log_cache_path().open(encoding="utf-8") as handle:
            obj = json.load(handle)
    except Exception:
        return None
    if not isinstance(obj, dict) or not isinstance(obj.get("payload"), dict) or not obj.get("fetched_at_ms"):
        return None
    # Enforce the TTL: without this the cache from just after local midnight
    # (a ~0-entry log for the new day) stayed fresh all day and starved the
    # per-model table — the regression that hid TOKENS BY MODEL.
    if not allow_stale and now_ms() - int(obj["fetched_at_ms"]) > LOG_CACHE_TTL_MS:
        return None
    # A cache from a previous local day mislabels "today's" per-model table.
    if parse_date(obj["fetched_at_ms"]) != date_now().isoformat():
        return None
    return obj


def write_log_cache(payload: dict[str, Any]) -> None:
    try:
        path = log_cache_path()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        atomic_write(path, {"fetched_at_ms": now_ms(), "payload": payload})
    except Exception:
        pass


def config_path() -> Path:
    return _path("~/.config/omarchy/cpa-agents.json")


def now_ms() -> int:
    return int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)


def date_now() -> dt.date:
    return dt.datetime.now().astimezone().date()


def days7() -> list[str]:
    today = date_now()
    return [(today - dt.timedelta(days=i)).isoformat() for i in range(6, -1, -1)]


def number(value: Any) -> float:
    try:
        n = float(value)
        return n if n == n and n >= 0 else 0.0
    except Exception:
        return 0.0


def integer(value: Any) -> int:
    return int(round(number(value)))


def text(value: Any) -> str:
    return str(value).strip() if value is not None else ""


def first(obj: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in obj and obj[key] not in (None, ""):
            return obj[key]
    return None


def parse_date(value: Any) -> str:
    if isinstance(value, (int, float)):
        n = float(value)
        if n > 10_000_000_000:
            n /= 1000
        try:
            return dt.datetime.fromtimestamp(n).date().isoformat()
        except Exception:
            return ""
    raw = text(value)
    if not raw:
        return ""
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw):
        return raw
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if parsed.tzinfo:
            parsed = parsed.astimezone()
        return parsed.date().isoformat()
    except Exception:
        return raw[:10] if re.match(r"\d{4}-\d{2}-\d{2}", raw) else ""


def reset_at(value: Any) -> str:
    if value in (None, ""):
        return ""
    if isinstance(value, (int, float)) or text(value).isdigit():
        n = float(value)
        if n < 1_000_000_000_000:
            n *= 1000
        try:
            return dt.datetime.fromtimestamp(n / 1000, dt.timezone.utc).isoformat()
        except Exception:
            return text(value)
    raw = text(value)
    try:
        return dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).isoformat()
    except Exception:
        return raw


def stable_id(item: dict[str, Any]) -> str:
    # File name is the durable identity in CPA.  Account id/index are useful
    # fallbacks for imported inventories which do not expose that name.
    provider = text(first(item, "provider", "auth_provider", "authProvider")) or "unknown"
    identity = first(item, "file_name", "fileName", "filename", "name")
    identity = identity or first(item, "account_id", "accountId", "project_id", "projectId")
    identity = identity or first(item, "auth_index", "authIndex", "email", "account_email")
    identity = identity or json.dumps(item, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256((provider.lower() + "\0" + text(identity)).encode()).hexdigest()[:20]
    return AGENT_PREFIX + digest


def target(item: dict[str, Any], sid: str) -> dict[str, Any]:
    """Build the target shape used by CPA monitoring endpoints."""
    out: dict[str, Any] = {"row_key": sid}
    mapping = {
        "account_snapshot": ("account_snapshot", "account", "account_id", "accountId"),
        "auth_label_snapshot": ("auth_label_snapshot", "label", "display_name", "displayName"),
        "auth_file_snapshot": ("auth_file_snapshot", "file_name", "fileName", "filename", "name"),
        "auth_provider_snapshot": ("auth_provider_snapshot", "provider", "auth_provider", "authProvider"),
        "auth_project_id_snapshot": ("auth_project_id_snapshot", "project_id", "projectId"),
        "auth_index": ("auth_index", "authIndex"),
        "source": ("source", "file_name", "fileName", "filename"),
    }
    for key, choices in mapping.items():
        val = first(item, *choices)
        if val not in (None, ""):
            out[key] = val
    return out


class ApiError(Exception):
    def __init__(self, status: int | None = None):
        self.status = status


def request_json(base: str, key: str, path: str, method: str = "GET", body: Any = None, timeout: float = 15) -> Any:
    url = base.rstrip("/") + path
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + key,
        "Accept": "application/json",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        raise ApiError(exc.code) from None
    except Exception:
        raise ApiError() from None


def list_files(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, dict):
        for key in ("files", "auth_files", "items", "data"):
            if isinstance(payload.get(key), list):
                return [x for x in payload[key] if isinstance(x, dict)]
    return [x for x in payload if isinstance(x, dict)] if isinstance(payload, list) else []


def items(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, dict):
        for key in ("items", "data", "entries", "windows", "history"):
            if isinstance(payload.get(key), list):
                return [x for x in payload[key] if isinstance(x, dict)]
    return [x for x in payload if isinstance(x, dict)] if isinstance(payload, list) else []


TOKEN_KEYS = ("tokens", "total_tokens", "totalTokens", "token_count", "tokenCount", "input_tokens", "output_tokens")


def token_count(obj: dict[str, Any]) -> int:
    direct = first(obj, "tokens", "total_tokens", "totalTokens", "token_count", "tokenCount")
    if direct is not None:
        return integer(direct)
    return sum(integer(obj.get(k)) for k in ("input_tokens", "inputTokens", "prompt_tokens", "output_tokens", "outputTokens", "completion_tokens"))


def history_days(payloads: list[Any]) -> tuple[dict[str, int], dict[str, dict[str, int]], int, int, dict[str, int]]:
    wanted = set(days7())
    daily = {d: 0 for d in wanted}
    models: dict[str, dict[str, int]] = {}
    total = 0
    prompts = 0
    requests_by_day = {d: 0 for d in wanted}

    def visit(obj: Any, inherited_day: str = "") -> None:
        nonlocal total, prompts
        if isinstance(obj, dict):
            day = parse_date(first(obj, "date", "day", "timestamp", "created_at", "createdAt", "observed_at", "observedAt")) or inherited_day
            count = token_count(obj)
            if count and day in wanted:
                daily[day] += count
                total += count
                reqs = integer(first(obj, "requests", "request_count", "requestCount", "prompts", "count")) or 1
                requests_by_day[day] += reqs
                prompts += reqs
                model = text(first(obj, "model", "model_id", "modelId"))
                if model:
                    bucket = models.setdefault(model, {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "totalTokens": 0, "tokens": 0})
                    in_t = integer(first(obj, "input_tokens", "inputTokens"))
                    out_t = integer(first(obj, "output_tokens", "outputTokens"))
                    bucket["inputTokens"] += in_t
                    bucket["outputTokens"] += out_t
                    bucket["totalTokens"] += in_t + out_t
                    bucket["tokens"] += in_t + out_t
            for key, value in obj.items():
                if key not in TOKEN_KEYS:
                    visit(value, day)
        elif isinstance(obj, list):
            for value in obj:
                visit(value, inherited_day)

    for payload in payloads:
        visit(payload)
    return daily, models, total, prompts, requests_by_day


def window_days(payload: Any, target_dates: dict[str, str]) -> tuple[dict[str, int], dict[str, dict[str, int]], int, int, dict[str, int]]:
    daily = {d: 0 for d in days7()}; requests = {d: 0 for d in days7()}; models: dict[str, dict[str, int]] = {}; total = prompts = 0
    for row in items(payload):
        day = target_dates.get(text(first(row, "request_key", "requestKey"))) or parse_date(first(row, "date", "day"))
        if day not in daily: continue
        tokens = token_count(row); req = integer(first(row, "total_requests", "totalRequests", "requests"))
        daily[day] += tokens; requests[day] += req; total += tokens; prompts += req
        model = text(first(row, "model", "model_id", "modelId"))
        if model:
            bucket = models.setdefault(model, {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "totalTokens": 0, "tokens": 0})
            in_t = integer(first(row, "input_tokens", "inputTokens")); out_t = integer(first(row, "output_tokens", "outputTokens"))
            bucket["inputTokens"] += in_t; bucket["outputTokens"] += out_t; bucket["totalTokens"] += in_t + out_t; bucket["tokens"] += in_t + out_t
    return daily, models, total, prompts, requests


def flatten_windows(payload: Any) -> list[dict[str, Any]]:
    """Unwrap quota query rows (`items[].windows`) into window records."""
    out: list[dict[str, Any]] = []
    for row in items(payload):
        nested = row.get("windows")
        if isinstance(nested, list):
            for window in nested:
                if isinstance(window, dict):
                    merged = dict(window)
                    merged.setdefault("row_key", row.get("row_key"))
                    out.append(merged)
        else:
            out.append(row)
    return out


def normalize_limits(payloads: list[Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for payload in payloads:
        entries = flatten_windows(payload) if isinstance(payload, dict) and any(isinstance(x, dict) and "windows" in x for x in items(payload)) else items(payload)
        for entry in entries:
            used = first(entry, "used", "usage", "used_tokens", "usedTokens", "consumed")
            limit = first(entry, "limit", "quota", "max", "capacity", "total")
            percentage = first(entry, "used_percent", "usedPercent", "usage_percent", "usagePercent")
            fraction = first(entry, "percent", "utilization", "utilisation")
            remaining = first(entry, "remaining_percent", "remainingPercent")
            if percentage is not None:
                p = number(percentage) / 100
            elif remaining is not None:
                p = 1 - number(remaining) / 100
            elif fraction is not None:
                p = number(fraction)
                if p > 1:
                    p /= 100
            elif used is not None and limit is not None and number(limit):
                p = number(used) / number(limit)
            else:
                continue
            p = max(0.0, min(1.0, p))
            cycle = entry.get("current_cycle") if isinstance(entry.get("current_cycle"), dict) else {}
            end = first(entry, "resets_at", "resetsAt", "reset_at", "resetAt", "expires_at", "expiresAt") or first(cycle, "scheduled_end_ms", "scheduledEndMs") or entry.get("cycle_end_ms")
            scope = entry.get("model_scope") if isinstance(entry.get("model_scope"), dict) else {}
            scope_kind = text(first(scope, "kind") or first(entry, "model_scope_kind", "modelScopeKind")).lower()
            scope_key = text(first(scope, "key", "name", "model") or first(entry, "model_scope_key", "modelScopeKey"))
            model_ids = scope.get("models") if isinstance(scope.get("models"), list) else entry.get("model_ids")
            if not scope_key and isinstance(model_ids, list):
                scope_key = ", ".join(text(model) for model in model_ids[:2] if text(model))
            label = text(first(entry, "label", "title", "name", "window", "window_kind", "windowKind", "kind"))
            if not label:
                label = text(first(entry, "provider_window_id", "providerWindowId"))
            label = re.sub(r"[_-]+", " ", label or "Quota").strip().title()
            if scope_kind not in ("", "all") and scope_key:
                label = f"{scope_key} · {label}"
            row = {"label": label, "title": label, "percent": p, "resetsAt": reset_at(end)}
            if used is not None:
                row["used"] = integer(used)
            if limit is not None:
                row["limit"] = integer(limit)
            out.append(row)
    # Keep the latest value for repeated labels.
    dedup: dict[str, dict[str, Any]] = {}
    for row in out:
        dedup[row["label"]] = row
    return list(dedup.values())


def metadata(item: dict[str, Any]) -> dict[str, str]:
    provider = text(first(item, "provider", "auth_provider", "authProvider")) or "CPA"
    account = text(first(item, "account", "account_name", "accountName", "email", "account_email", "accountEmail", "account_id", "accountId"))
    file_name = text(first(item, "file_name", "fileName", "filename", "name"))
    label = text(first(item, "label", "display_name", "displayName", "account_name", "accountName")) or account or file_name or provider
    return {"provider": provider, "account": account, "file": file_name, "label": label}


def provider_label(provider: str) -> str:
    labels = {"xai": "xAI", "codex": "Codex", "claude": "Claude", "kimi": "Kimi", "zai": "Zai"}
    return labels.get(provider.lower(), re.sub(r"[_-]+", " ", provider).title())


def usage_log_stats(payload: Any, file_name: str, account: str, model_prefix: str = "") -> dict[str, Any]:
    """Aggregate one auth file's traffic out of the plain /usage request log.

    Providers without monitoring coverage never appear in account-history or
    quota snapshots, but every completed request lands in the request log with
    snapshot fields recorded at request time. Match on the auth file name when
    the inventory knows it; fall back to the account label for inventories
    that do not; providers whose log entries carry no snapshots at all
    (opencode-go) match on their requested-model prefix.
    """
    today_str = days7()[-1]
    daily = {d: 0 for d in days7()}
    requests_by_day = {d: 0 for d in days7()}
    models: dict[str, dict[str, int]] = {}
    models_today: dict[str, dict[str, int]] = {}
    dates: set[str] = set()
    total = prompts = successes = 0

    want_file = text(file_name)
    want_account = text(account)
    want_prefix = text(model_prefix).lower()

    def visit_entry(entry: Any) -> None:
        nonlocal total, prompts, successes
        if not isinstance(entry, dict):
            return
        if want_file:
            if text(first(entry, "auth_file_snapshot", "authFileSnapshot")) != want_file:
                return
        elif want_account:
            if text(first(entry, "account_snapshot", "accountSnapshot")) != want_account:
                return
        elif want_prefix:
            requested = text(first(entry, "requested_model", "requestedModel", "resolved_model", "resolvedModel")).lower()
            if not requested.startswith(want_prefix):
                return
        else:
            return
        day = parse_date(first(entry, "timestamp", "created_at", "createdAt"))
        bucket = entry.get("tokens") if isinstance(entry.get("tokens"), dict) else {}
        tokens = token_count(bucket)
        prompts += 1
        total += tokens
        if entry.get("failed") is not True:
            successes += 1
        if day:
            dates.add(day)
            if day in daily:
                daily[day] += tokens
                requests_by_day[day] += 1
        model = text(first(entry, "resolved_model", "requested_model", "requestedModel"))
        if model:
            m = models.setdefault(model, {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "totalTokens": 0, "tokens": 0})
            in_tok = integer(first(bucket, "input_tokens", "inputTokens", "prompt_tokens"))
            out_tok = integer(first(bucket, "output_tokens", "outputTokens", "completion_tokens"))
            m["inputTokens"] += in_tok
            m["outputTokens"] += out_tok
            m["cacheReadInputTokens"] += integer(first(bucket, "cache_read_tokens", "cache_read_input_tokens", "cached_tokens"))
            m["cacheCreationInputTokens"] += integer(first(bucket, "cache_creation_tokens", "cache_creation_input_tokens"))
            # Model total must match token_count(bucket) (which prefers total_tokens) so the per-model sum aligns with the daily bar.
            tot = token_count(bucket) or (in_tok + out_tok)
            m["totalTokens"] += tot
            m["tokens"] += tot
            if day == today_str and tot > 0:
                mt = models_today.setdefault(model, {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "totalTokens": 0, "tokens": 0})
                mt["inputTokens"] += in_tok
                mt["outputTokens"] += out_tok
                mt["cacheReadInputTokens"] += integer(first(bucket, "cache_read_tokens", "cache_read_input_tokens", "cached_tokens"))
                mt["cacheCreationInputTokens"] += integer(first(bucket, "cache_creation_tokens", "cache_creation_input_tokens"))
                mt["totalTokens"] += tot
                mt["tokens"] += tot

    def visit(node: Any) -> None:
        if isinstance(node, dict):
            details = node.get("details")
            if isinstance(details, list):
                for entry in details:
                    visit_entry(entry)
            for field, value in node.items():
                if field != "details":
                    visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(payload)

    # Hide zero-token ghosts (e.g. probe failures with 0/0) so the panel
    # doesn't render a long list of "0" rows. Callers that need today-only
    # should use models_today; legacy "models" stays all-time for compat.
    models = {k: v for k, v in models.items() if (v.get("totalTokens") or 0) > 0 or (v.get("tokens") or 0) > 0 or (v.get("inputTokens", 0) + v.get("outputTokens", 0) > 0)}
    models_today = {k: v for k, v in models_today.items() if (v.get("totalTokens") or 0) > 0}
    since_text = ""
    if dates and (total or prompts):
        since_text = "From CPA request log · since " + min(dates)
    return {
        "daily": daily,
        "requests": requests_by_day,
        "models": models,
        "modelsToday": models_today,
        "activeDates": sorted(dates),
        "totalTokens": total,
        "totalRequests": prompts,
        "successes": successes,
        "sinceText": since_text,
    }


def last_used_by_auth(payload: Any) -> dict[str, str]:
    """Latest request timestamp per auth file out of the /usage request log.

    Drives the panel hero ("most recently used auth file"): log entries
    carry auth_index on every row but file snapshots on only some, so key
    by auth_index — the inventory maps each index back to its file at the
    call site. Returns auth_index -> ISO-8601 UTC instant of that file's
    newest entry. One walk covers every account.
    """
    best: dict[str, float] = {}
    # Secondary keys for rows whose auth_index is absent but which still
    # carry the file or account snapshot — keyed "file:<name>" / "acct:<id>".
    best_file: dict[str, float] = {}
    best_acct: dict[str, float] = {}

    def stamp(entry: Any) -> None:
        if not isinstance(entry, dict):
            return
        raw = text(first(entry, "timestamp", "created_at", "createdAt"))
        if not raw:
            return
        try:
            cleaned = re.sub(r"(\.\d{6})\d+", r"\1", raw.replace("Z", "+00:00"))
            moment = dt.datetime.fromisoformat(cleaned).timestamp()
        except Exception:
            return
        index = text(first(entry, "auth_index", "authIndex"))
        if index and moment > best.get(index, 0):
            best[index] = moment
        fname = text(first(entry, "auth_file_snapshot", "authFileSnapshot"))
        if fname and moment > best_file.get(fname, 0):
            best_file[fname] = moment
        acct = text(first(entry, "account_snapshot", "accountSnapshot", "auth_label_snapshot", "authLabelSnapshot"))
        if acct and moment > best_acct.get(acct, 0):
            best_acct[acct] = moment

    def visit(node: Any) -> None:
        if isinstance(node, dict):
            details = node.get("details")
            if isinstance(details, list):
                for entry in details:
                    stamp(entry)
            for field, value in node.items():
                if field != "details":
                    visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(payload)
    out = {index: dt.datetime.fromtimestamp(moment, dt.timezone.utc).isoformat() for index, moment in best.items()}
    out.update({"file:" + k: dt.datetime.fromtimestamp(v, dt.timezone.utc).isoformat() for k, v in best_file.items()})
    out.update({"acct:" + k: dt.datetime.fromtimestamp(v, dt.timezone.utc).isoformat() for k, v in best_acct.items()})
    return out


def apply_usage_stats(common: dict[str, Any], meta: dict[str, str], item: dict[str, Any], stats: dict[str, Any]) -> None:
    """Fill a record from request-log aggregates for a provider that has no
    monitoring coverage. Totals cover only the log's retention window, so the
    footer says where they start instead of implying all-time."""
    daily = stats.get("daily") or {}
    reqs = stats.get("requests") or {}
    wanted = days7()
    today = wanted[-1]
    total = integer(stats.get("totalTokens"))
    prompts = integer(stats.get("totalRequests"))
    successes = integer(stats.get("successes"))
    plan = text(first(item, "plan", "planName", "tier"))
    common["tierLabel"] = provider_label(meta["provider"])
    if plan:
        common["tierLabel"] += " · " + plan.title()
    # Panel now shows TOKENS BY MODEL for *today only* per spec; use
    # modelsToday when present so stale all-time ghosts don't fill the panel.
    today_models = stats.get("modelsToday")
    if today_models is None:
        today_models = {k: v for k, v in (stats.get("models") or {}).items() if (v.get("totalTokens") or v.get("tokens") or 0) > 0}
    else:
        today_models = {k: v for k, v in today_models.items() if (v.get("totalTokens") or v.get("tokens") or 0) > 0}
    common.update({
        "ready": bool(total or prompts),
        "limits": [],
        "recentDays": [{"date": d, "messageCount": daily.get(d, 0), "tokens": daily.get(d, 0), "requests": reqs.get(d, 0)} for d in wanted],
        "modelUsage": today_models,
        "todayTotalTokens": daily.get(today, 0),
        "todayPrompts": reqs.get(today, 0),
        "todaySessions": 0,
        "totalPrompts": prompts,
        "totalSessions": 0,
        "totalTokens": total,
        # A request-log success rate is window-bounded, but so is everything
        # else on this record; the all-time card is honest about its reach via
        # the same freshness line as the charts.
        "allTime": {"requests": prompts, "tokens": total, "successRate": (successes / prompts) if prompts else None},
        "activeDays": len(stats.get("activeDates") or []),
        "activeDates": sorted(stats.get("activeDates") or []),
        # Cursor-style executors can report tokens as zeros; fall back to a
        # request count rather than drawing a week of empty bars.
        "dailyMetric": "tokens" if total else "requests",
        "freshnessText": text(stats.get("sinceText")),
        "scope": "account",
    })


def api_call(base: str, key: str, auth_index: str, method: str, url: str, headers: dict[str, str], data: str | None = None) -> tuple[int, dict[str, Any]]:
    """One read-only upstream call through CPA's credential proxy. The
    management key travels only in the request header; the account's own
    token never reaches this process — $TOKEN$ in a header value is
    substituted server-side from the selected auth file."""
    payload: dict[str, Any] = {"auth_index": auth_index, "method": method, "url": url, "header": headers}
    if data is not None:
        payload["data"] = data
    response = request_json(base, key, "/v0/management/api-call", "POST", payload)
    status = integer(first(response, "status_code", "statusCode"))
    body = response.get("body")
    if isinstance(body, str):
        try:
            body = json.loads(body)
        except Exception:
            body = {}
    return status, body if isinstance(body, dict) else {}


def _antigravity_summary_limits(base: str, key: str, auth_index: str) -> list[dict[str, Any]] | None:
    """Try the richer retrieveUserQuotaSummary endpoint.

    Returns None when the endpoint is unavailable/unparsable so the caller can
    fall back to the per-model rollup. A successful parse expands each model
    group's two buckets into separate panel rows: \"Gemini · 5-hour\" etc.
    """
    headers = {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json",
               "User-Agent": "antigravity/1.11.5 windows/amd64"}
    for url in ANTIGRAVITY_SUMMARY_URLS:
        try:
            status, body = api_call(base, key, auth_index, "POST", url, headers, "{}")
        except ApiError:
            continue
        if not 200 <= status < 300:
            continue
        groups = body.get("groups") if isinstance(body, dict) else None
        if not isinstance(groups, list) or not groups:
            continue

        # Map summary group labels back to panel labels (summary says
        # "Gemini Models"/"Claude and GPT models").
        def group_label(display: str) -> str | None:
            lower = display.lower()
            if "gemini" in lower:
                return "Gemini"
            if "claude" in lower or "3p" in lower or "gpt" in lower:
                return "Claude/GPT"
            return None

        def window_label(window: str | None, fallback: str) -> str:
            if window == "5h":
                return "5-hour"
            if window == "weekly":
                return "Weekly"
            if fallback == "5h":
                return "5-hour"
            return "Weekly"

        synthesized: list[dict[str, Any]] = []
        for group in groups:
            if not isinstance(group, dict):
                continue
            display = text(first(group, "displayName", "display_name"))
            panel_label = group_label(display)
            if not panel_label:
                continue
            buckets = group.get("buckets") if isinstance(group.get("buckets"), list) else []
            for bucket in buckets:
                if not isinstance(bucket, dict):
                    continue
                remaining = first(bucket, "remainingFraction", "remaining_fraction", "remaining")
                if remaining is None:
                    continue
                try:
                    remaining_pct = float(remaining) * 100.0
                except (ValueError, TypeError):
                    continue
                remaining_pct = max(0.0, min(100.0, remaining_pct))
                percent = round(1 - remaining_pct / 100.0, 4)
                window = first(bucket, "window")
                bucket_id = text(first(bucket, "bucketId", "bucket_id"))
                # bucketId carries "weekly"/"5h" but window is the canonical field.
                window_id = window if isinstance(window, str) and window else (
                    "weekly" if "weekly" in bucket_id else ("5h" if "5h" in bucket_id else None)
                )
                label = f"{panel_label} · {window_label(window_id, bucket_id)}"
                resets = reset_at(first(bucket, "resetTime", "reset_time"))
                synthesized.append({"label": label, "title": label,
                                    "percent": percent, "resetsAt": resets})
        if synthesized:
            return synthesized
    return None


def antigravity_quota_limits(base: str, key: str, auth_index: str, project_id: str) -> list[dict[str, Any]]:
    """Per-model-group OAuth limits for Antigravity.

    The primary source is retrieveUserQuotaSummary (weekly + 5-hour per
    group). fetchAvailableModels remains the fallback. remainingFraction
    arrives as a 0..1 fraction; the record meters read used.
    """
    if not auth_index:
        return []
    summary = _antigravity_summary_limits(base, key, auth_index)
    if summary is not None:
        return summary
    # Fallback to fetchAvailableModels — still needs a project id.
    if not project_id:
        return []
    headers = {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json",
               "User-Agent": "antigravity/1.11.5 windows/amd64"}
    data = json.dumps({"project": project_id}, separators=(",", ":"))
    models: dict[str, Any] = {}
    for url in ANTIGRAVITY_MODEL_URLS:
        try:
            status, body = api_call(base, key, auth_index, "POST", url, headers, data)
        except ApiError:
            return []
        if 200 <= status < 300 and isinstance(body.get("models"), dict) and body["models"]:
            models = body["models"]
            break
    if not models:
        return []

    quotas: dict[str, dict[str, Any]] = {}
    for model_id, raw in models.items():
        if not isinstance(raw, dict):
            continue
        info = first(raw, "quotaInfo", "quota_info")
        info = info if isinstance(info, dict) else {}
        raw_remaining = first(info, "remainingFraction", "remaining_fraction", "remaining")
        reset = reset_at(first(info, "resetTime", "reset_time"))
        remaining = number(raw_remaining) * 100.0 if raw_remaining is not None else None
        if remaining is None:
            if reset:
                remaining = 0.0
            else:
                continue
        quotas[text(model_id)] = {"remaining": max(0.0, min(100.0, remaining)), "reset": reset,
                                  "displayName": text(first(raw, "displayName", "display_name"))}

    def rollup(label: str, model_ids: list[str]) -> tuple[float | None, str]:
        matches = [quotas[m] for m in model_ids if m in quotas]
        if not matches:
            return None, ""
        worst = min(m["remaining"] for m in matches)
        reset = next((m["reset"] for m in matches if m["reset"]), "")
        return worst, reset

    rows: list[dict[str, Any]] = []
    for label, model_ids in ANTIGRAVITY_MODEL_GROUPS:
        remaining, reset = rollup(label, model_ids)
        if remaining is None:
            continue
        rows.append({"label": label, "title": label,
                     "percent": round(1 - remaining / 100.0, 4), "resetsAt": reset})
    return rows


def upstream_quota_limits(base: str, key: str, meta: dict[str, str], item: dict[str, Any]) -> list[dict[str, Any]]:
    """Limits for providers whose quota snapshots CPA never captures. Only
    providers with a known read-only upstream endpoint are probeable; the
    rest simply have nothing to report."""
    if meta["provider"].lower() != "antigravity":
        return []
    return antigravity_quota_limits(base, key, text(first(item, "auth_index", "authIndex")),
                                    text(first(item, "project_id", "projectId")))


def codex_account_id(item: dict[str, Any]) -> str:
    """The ChatGPT workspace id the usage endpoint requires.

    CPA's inventory already decodes each auth file's id_token into a dict;
    raw JWT strings are decoded locally as a fallback for older releases.
    """
    token = first(item, "id_token", "idToken")
    payload: Any = None
    if isinstance(token, dict):
        payload = token
    elif isinstance(token, str) and token.count(".") >= 2:
        try:
            segment = token.split(".")[1]
            segment += "=" * (-len(segment) % 4)
            payload = json.loads(base64.urlsafe_b64decode(segment))
        except Exception:
            payload = None
    if not isinstance(payload, dict):
        return ""
    auth = payload.get("https://api.openai.com/auth")
    account = first(payload, "chatgpt_account_id", "chatgptAccountId")
    if not account and isinstance(auth, dict):
        account = first(auth, "chatgpt_account_id", "chatgptAccountId")
    return text(account)


def codex_window_label(window: dict[str, Any], position: int) -> str:
    seconds = integer(first(window, "limit_window_seconds", "limitWindowSeconds"))
    if seconds in CODEX_WINDOW_SECONDS:
        return CODEX_WINDOW_SECONDS[seconds]
    return "5-hour" if position == 0 else "Weekly"


# ----- Cursor (live quota, not CPA monitoring) --------------------------------

def cursor_limits_rows(usage: dict[str, Any]) -> list[dict[str, Any]]:
    """Turn Cursor's GetCurrentPeriodUsage response into panel limit rows.

    Mirrors the CPA Manager web logic (utils/quota/providerRequests +
    components/quota/quotaConfigs): a Monthly spend meter plus the two
    model-level sub-windows (Auto / API) when reported. All three are shown,
    labeled with their spend context, with a billing-cycle reset.
    """
    if not isinstance(usage, dict):
        return []
    plan_usage = usage.get("planUsage") if isinstance(usage.get("planUsage"), dict) else {}
    cycle_end = first(usage, "billingCycleEnd", "billing_cycle_end", "billingCycleEndMs")
    resets = reset_at(cycle_end) if cycle_end not in (None, "") else ""

    rows: list[dict[str, Any]] = []

    used_cents = first(plan_usage, "includedSpend", "included_spend")
    if used_cents is None:
        used_cents = first(plan_usage, "totalSpend", "total_spend")
    limit_cents = first(plan_usage, "limit")
    total_used = first(plan_usage, "totalPercentUsed", "total_percent_used")
    monthly_used: float | None = None
    # The included-dollar allowance can be exhausted while the API/bonus
    # allocation remains available. Cursor's own percentage is authoritative.
    if total_used is not None:
        monthly_used = number(total_used)
    elif limit_cents is not None and used_cents is not None and number(limit_cents):
        monthly_used = (number(used_cents) / number(limit_cents)) * 100.0
    if monthly_used is not None:
        monthly_used = max(0.0, min(100.0, monthly_used))
        rows.append({
            "label": "Monthly",
            "title": "Monthly",
            **({"resetsAt": resets} if resets else {}),
            "percent": round(monthly_used / 100.0, 4),
            # Spend is separate context, not the numerator/denominator of
            # Cursor's total percentage. Generic consumers must not relabel it.
            "includedSpendCents": integer(used_cents) if used_cents is not None else None,
            "includedLimitCents": integer(limit_cents) if limit_cents is not None else None,
        })

    for key, label in (("autoPercentUsed", "Auto"), ("auto_percent_used", "Auto"),
                       ("apiPercentUsed", "API"), ("api_percent_used", "API")):
        # Avoid duplicating label when the payload carries both casings for the
        # same logical pool (the collector favors camelCase and tests use it).
        if any(row["label"] == label for row in rows):
            continue
        value = first(plan_usage, key)
        if value is None:
            continue
        used = max(0.0, min(100.0, number(value)))
        rows.append({"label": label, "title": label,
                     **({"resetsAt": resets} if resets else {}),
                     "percent": round(used / 100.0, 4)})

    # Deduplicate label strictly (the loop above already avoids double-count
    # within the key pairs, but external callers may synthesize payloads).
    dedup: dict[str, dict[str, Any]] = {}
    for row in rows:
        dedup[row["label"]] = row
    return list(dedup.values())


def zai_limit_rows(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Map the /v0/management/zai-quota response onto panel limit rows.

    The manager server pre-flattens each account's CREDIT_LIMIT pools into
    windows: {label, percentage (0-100 used), usage, remaining,
    reset_at_ms, period_hours}. percentage is already the used fraction the
    record contract meters, so this is a pure relabel - the same role
    cursor_limits_rows plays for the Cursor dashboard. No windows means no
    meters rather than a misleading 0%.
    """
    if not isinstance(payload, dict):
        return []
    accounts = payload.get("accounts")
    if not isinstance(accounts, list) or not accounts:
        return []
    account = accounts[0] if isinstance(accounts[0], dict) else {}
    rows: list[dict[str, Any]] = []
    for window in items(account.get("windows")):
        used = first(window, "percentage", "percent", "usedPercent")
        if used is None:
            continue
        raw_label = text(first(window, "label", "title", "name")) or "Quota"
        lower = raw_label.lower()
        if "week" in lower:
            label = "Weekly"
        elif "5h" in lower or "5-hour" in lower or "5 hour" in lower:
            label = "5-hour"
        else:
            label = raw_label
        resets = reset_at(first(window, "reset_at_ms", "resetAtMs", "resetsAt", "resets_at"))
        percent = max(0.0, min(100.0, number(used))) / 100.0
        row: dict[str, Any] = {"label": label, "title": label,
                                "percent": round(percent, 4), "resetsAt": resets}
        if first(window, "usage") is not None:
            row["used"] = integer(first(window, "usage"))
        rows.append(row)
    if not rows and isinstance(account.get("raw"), dict):
        data = account["raw"].get("data")
        if isinstance(data, dict):
            raw_limits = data.get("limits")
            if isinstance(raw_limits, list):
                for lim in raw_limits:
                    if not isinstance(lim, dict):
                        continue
                    used = first(lim, "percentage", "percent")
                    if used is None:
                        continue
                    unit = integer(first(lim, "unit"))
                    num = integer(first(lim, "number"))
                    if unit == 3 and num == 5:
                        label = "5-hour"
                    elif unit == 6 or "week" in text(first(lim, "type", "label", "name")).lower():
                        label = "Weekly"
                    else:
                        label = f"{num}-hour" if unit == 3 else text(first(lim, "label", "type")) or "Quota"
                    resets = reset_at(first(lim, "nextResetTime", "next_reset_time", "reset_at_ms"))
                    percent = max(0.0, min(100.0, number(used))) / 100.0
                    row = {"label": label, "title": label,
                           "percent": round(percent, 4), "resetsAt": resets}
                    if first(lim, "usage") is not None:
                        row["used"] = integer(first(lim, "usage"))
                    rows.append(row)
    dedup: dict[str, dict[str, Any]] = {}
    for row in rows:
        dedup[row["label"]] = row
    return list(dedup.values())


def zai_live_limits(base: str, key: str, item: dict[str, Any]) -> tuple[list[dict[str, Any]], str]:
    """Live Zai limits from the manager server's zai-quota endpoint."""
    # The endpoint answers account-wide, not per-row: match the inventory
    # auth file name against the response account ids first, then fall back
    # to a single-account payload or the first account (the common case is
    # exactly one Zai credential).
    want = text(first(item, "file_name", "fileName", "filename", "name"))
    account: dict[str, Any] = {}
    try:
        payload = request_json(base, key, "/v0/management/zai-quota")
        if isinstance(payload, dict):
            accounts = payload.get("accounts")
            if isinstance(accounts, list) and accounts:
                if want:
                    for entry in accounts:
                        if isinstance(entry, dict) and text(entry.get("id")) == want:
                            account = entry
                            break
                if not account and isinstance(accounts[0], dict):
                    account = accounts[0]
    except ApiError:
        account = {}

    rows = zai_limit_rows({"accounts": [account]} if account else {})
    plan = text(first(account.get("raw", {}) if isinstance(account.get("raw"), dict) else {}, "level"))
    if not plan and isinstance(account.get("raw"), dict):
        data = account["raw"].get("data")
        if isinstance(data, dict):
            plan = text(first(data, "level", "plan", "planType"))

    # Direct proxy fallback if manager endpoint returned no windows or an error
    if not rows:
        auth_index = text(first(item, "auth_index", "authIndex"))
        if auth_index:
            try:
                headers = {"Authorization": "Bearer $TOKEN$", "User-Agent": "curl/8.21.0"}
                status, body = api_call(base, key, auth_index, "GET", "https://api.z.ai/api/monitor/usage/quota/limit", headers)
                if 200 <= status < 300 and isinstance(body, dict) and body.get("code") == 200:
                    data = body.get("data", {})
                    if not plan:
                        plan = text(first(data, "level", "plan", "planType"))
                    raw_limits = data.get("limits", [])
                    if isinstance(raw_limits, list):
                        for lim in raw_limits:
                            if not isinstance(lim, dict):
                                continue
                            used = first(lim, "percentage", "percent")
                            if used is None:
                                continue
                            unit = integer(first(lim, "unit"))
                            num = integer(first(lim, "number"))
                            if unit == 3 and num == 5:
                                label = "5-hour"
                            elif unit == 6 or "week" in text(first(lim, "type", "label", "name")).lower():
                                label = "Weekly"
                            else:
                                label = f"{num}-hour" if unit == 3 else text(first(lim, "label", "type")) or "Quota"
                            resets = reset_at(first(lim, "nextResetTime", "next_reset_time", "reset_at_ms"))
                            percent = max(0.0, min(100.0, number(used))) / 100.0
                            row = {"label": label, "title": label, "percent": round(percent, 4), "resetsAt": resets}
                            if first(lim, "usage") is not None:
                                row["used"] = integer(first(lim, "usage"))
                            rows.append(row)
            except Exception:
                pass

    dedup: dict[str, dict[str, Any]] = {}
    for row in rows:
        dedup[row["label"]] = row
    return list(dedup.values()), plan


def cursor_live_limits(base: str, key: str, item: dict[str, Any]) -> tuple[list[dict[str, Any]], str]:
    """Live cursor limits from the dashboard endpoint via the credential proxy."""
    auth_index = text(first(item, "auth_index", "authIndex"))
    if not auth_index:
        return [], ""
    try:
        status, body = api_call(base, key, auth_index, "POST", CURSOR_USAGE_URL, dict(CURSOR_USAGE_HEADERS), "{}")
    except ApiError:
        return [], ""
    if not 200 <= status < 300 or not isinstance(body, dict):
        return [], ""
    plan_usage = body.get("planUsage") if isinstance(body.get("planUsage"), dict) else None
    if not isinstance(plan_usage, dict):
        return [], ""
    rows = cursor_limits_rows(body)
    # The secondary profile call carries membershipType for the tierLabel; keep
    # the request optional so planUsage limits always surface.
    plan = ""
    try:
        p_status, p_body = api_call(base, key, auth_index, "GET", CURSOR_PROFILE_URL, dict(CURSOR_USAGE_HEADERS))
        if 200 <= p_status < 300 and isinstance(p_body, dict):
            plan = text(first(p_body, "individualMembershipType", "membershipType", "planType"))
    except ApiError:
        pass
    return rows, plan


def codex_window_rows(body: dict[str, Any]) -> list[dict[str, Any]]:
    """Turn a wham/usage payload into panel limit rows.

    used_percent is the whole truth when present. Without it, an explicit
    limit_reached (or a refused request) next to a known reset reads as an
    exhausted window — the same reading the quota tooling uses — while a
    window with neither number is simply unreported and dropped.
    """
    rate_limit = first(body, "rate_limit", "rateLimit")
    rate_limit = rate_limit if isinstance(rate_limit, dict) else {}
    limit_reached = first(rate_limit, "limit_reached", "limitReached")
    allowed = first(rate_limit, "allowed")

    groups: list[tuple[str, list[Any]]] = [("", [])]
    for key in ("primary_window", "primaryWindow", "secondary_window", "secondaryWindow"):
        window = rate_limit.get(key)
        if isinstance(window, dict):
            groups[0][1].append(window)
    additional = first(body, "additional_rate_limits", "additionalRateLimits")
    if isinstance(additional, list):
        for entry in additional:
            if not isinstance(entry, dict):
                continue
            nested = first(entry, "rate_limit", "rateLimit")
            nested = nested if isinstance(nested, dict) else {}
            name = text(first(entry, "limit_name", "limitName", "metered_feature", "meteredFeature"))
            windows = [w for w in (nested.get("primary_window"), nested.get("primaryWindow"),
                                   nested.get("secondary_window"), nested.get("secondaryWindow"))
                       if isinstance(w, dict)]
            if windows:
                groups.append((name, windows))

    rows: list[dict[str, Any]] = []
    for name, windows in groups:
        for position, window in enumerate(windows):
            used = first(window, "used_percent", "usedPercent")
            if used is None:
                reset = first(window, "reset_at", "resetAt", "reset_after_seconds", "resetAfterSeconds")
                if reset in (None, "") or not (limit_reached is True or allowed is False):
                    continue
                used = 100.0
            label = codex_window_label(window, position)
            if name:
                label = f"{re.sub(r'[_-]+', ' ', name).title()} · {label}"
            reset_at_value = first(window, "reset_at", "resetAt")
            if reset_at_value not in (None, ""):
                resets = reset_at(reset_at_value)
            else:
                seconds = integer(first(window, "reset_after_seconds", "resetAfterSeconds"))
                resets = dt.datetime.fromtimestamp(now_ms() / 1000 + seconds, dt.timezone.utc).isoformat() if seconds > 0 else ""
            percent = max(0.0, min(100.0, number(used))) / 100.0
            rows.append({"label": label, "title": label, "percent": round(percent, 4), "resetsAt": resets})
    # Keep the latest value for repeated labels.
    dedup: dict[str, dict[str, Any]] = {}
    for row in rows:
        dedup[row["label"]] = row
    return list(dedup.values())


def codex_live_limits(base: str, key: str, item: dict[str, Any]) -> tuple[list[dict[str, Any]], str]:
    """Live per-account codex limits straight from ChatGPT's usage endpoint.

    Returns no rows on any failure so the caller can fall back to CPA's
    stored snapshots; a stale meter still beats a missing one.
    """
    auth_index = text(first(item, "auth_index", "authIndex"))
    account_id = codex_account_id(item)
    if not auth_index or not account_id:
        return [], ""
    headers = dict(CODEX_USAGE_HEADERS)
    headers["Chatgpt-Account-Id"] = account_id
    try:
        status, body = api_call(base, key, auth_index, "GET", CODEX_USAGE_URL, headers)
    except ApiError:
        return [], ""
    if not 200 <= status < 300 or not isinstance(body, dict):
        return [], ""
    return codex_window_rows(body), text(first(body, "plan_type", "planType"))


def claude_window_rows(body: dict[str, Any]) -> list[dict[str, Any]]:
    """Claude percentages are always 0..100, including values below one.

    Named windows take precedence over the newer limits array. Model-scoped
    weekly limits remain distinct. Opaque experiment keys are not guessed.
    """
    rows: dict[str, dict[str, Any]] = {}

    def add(label: str, window: Any, field: str) -> None:
        if not isinstance(window, dict):
            return
        raw = window.get(field)
        if raw is None or isinstance(raw, bool):
            return
        try:
            used = float(raw)
        except (TypeError, ValueError):
            return
        if not math.isfinite(used):
            return
        row = {
            "label": label, "title": label,
            "percent": max(0.0, min(100.0, used)) / 100.0,
            "resetsAt": reset_at(first(window, "resets_at", "resetsAt", "reset_at", "resetAt")),
        }
        previous = rows.get(label)
        if previous is None or row["resetsAt"] > previous["resetsAt"]:
            rows[label] = row

    for key, label in CLAUDE_WINDOW_LABELS.items():
        add(label, body.get(key), "utilization")
    for limit in items(body.get("limits")):
        kind = text(limit.get("kind")).lower()
        scope = limit.get("scope")
        if not scope and kind in ("session", "weekly_all"):
            label = "5-hour" if kind == "session" else "Weekly"
            if label not in rows:
                add(label, limit, "percent")
        elif kind == "weekly_scoped" and isinstance(scope, dict):
            model = scope.get("model")
            if isinstance(model, dict):
                name = text(first(model, "display_name", "displayName", "id"))
                if name:
                    add(name + " · Weekly", limit, "percent")
    return list(rows.values())


def claude_live_quota(base: str, key: str, item: dict[str, Any], previous: dict[str, Any] | None = None) -> dict[str, Any]:
    """Cache probes across foreground/log passes and back off on failure.

    After an authentication denial, only a credential revision (managed by
    CPA) permits another probe. Never try to refresh or rewrite OAuth here.
    """
    previous = previous or {}
    auth_index = text(first(item, "auth_index", "authIndex"))
    revision = hashlib.sha256(json.dumps([
        auth_index, first(item, "last_refresh", "lastRefresh"),
        first(item, "modtime", "created_at"),
    ], separators=(",", ":")).encode()).hexdigest()
    checked = text(previous.get("quotaCheckedAt"))
    result = {
        "limits": previous.get("limits") or [],
        "quotaUpdatedAt": text(previous.get("quotaUpdatedAt")),
        "quotaCheckedAt": checked,
        "quotaError": text(previous.get("quotaError")),
        "quotaAuthRequired": bool(previous.get("quotaAuthRequired")),
        "quotaCredentialRevision": revision,
        "quotaRetryAtMs": integer(previous.get("quotaRetryAtMs")),
    }
    same_credential = revision == text(previous.get("quotaCredentialRevision"))
    try:
        age = now_ms() - dt.datetime.fromisoformat(checked.replace("Z", "+00:00")).timestamp() * 1000
    except (ValueError, TypeError):
        age = CLAUDE_QUOTA_TTL_MS
    # now_ms is millisecond-rounded while ISO stamps retain microseconds.
    if same_credential and (result["quotaAuthRequired"] or now_ms() < result["quotaRetryAtMs"] or -1 <= age < CLAUDE_QUOTA_TTL_MS):
        return result
    result.update({"quotaCheckedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                   "quotaAuthRequired": False, "quotaRetryAtMs": 0})
    if not auth_index:
        result.update({"quotaError": "Claude quota needs a CPA OAuth credential.",
                       "quotaAuthRequired": True})
        return result
    try:
        status, body = api_call(base, key, auth_index, "GET", CLAUDE_USAGE_URL, dict(CLAUDE_USAGE_HEADERS))
    except ApiError as error:
        status, body = error.status, {}
    if status is not None and 200 <= status < 300:
        rows = claude_window_rows(body)
        if rows:
            result.update({"limits": rows, "quotaUpdatedAt": result["quotaCheckedAt"], "quotaError": ""})
            return result
        message = "Claude quota windows were not reported. Showing saved data."
    elif status in (401, 403):
        message = "Claude quota access denied. Reconnect Claude in CPA Manager."
        result["quotaAuthRequired"] = True
    elif status == 429:
        message = "Claude quota rate limited. Retrying in 5 minutes."
    else:
        message = "Claude quota unavailable. Showing saved data."
    result.update({"quotaError": message, "quotaRetryAtMs": now_ms() + CLAUDE_RETRY_MS})
    return result


def opencode_go_limits(payload: Any) -> list[dict[str, Any]]:
    """Map the manager server's dashboard scrape onto panel limit rows.

    usagePercent arrives already pointing the right way for the record
    contract (used fraction); resetInSec is relative to now.
    """
    rows: list[dict[str, Any]] = []
    for key, label in OPENCODE_GO_WINDOWS:
        window = payload.get(key) if isinstance(payload, dict) else None
        if not isinstance(window, dict):
            continue
        used = first(window, "usagePercent", "usage_percent", "usedPercent")
        if used is None:
            continue
        reset_in = integer(first(window, "resetInSec", "reset_in_sec", "resetInSec"))
        resets = ""
        if reset_in > 0:
            resets = dt.datetime.fromtimestamp(now_ms() / 1000 + reset_in, dt.timezone.utc).isoformat()
        percent = max(0.0, min(100.0, number(used))) / 100.0
        rows.append({"label": label, "title": label, "percent": round(percent, 4), "resetsAt": resets})
    return rows


def opencode_go_api_key(server_config: dict[str, Any]) -> str:
    """The Zen Go API key CPA stores in its openai-compatibility entries."""
    for entry in items((server_config or {}).get("openai-compatibility")):
        if text(entry.get("name")).lower() != "opencode-go":
            continue
        for key_entry in items(entry.get("api-key-entries")):
            key = text(key_entry.get("api-key"))
            if key:
                return key
    return ""


def zen_go_usage_payload(api_key: str) -> dict[str, Any]:
    """Fetch the Go plan usage straight from opencode.ai."""
    request = urllib.request.Request(OPENCODE_GO_USAGE_URL, headers={
        "Authorization": "Bearer " + api_key,
        "Accept": "application/json",
        "User-Agent": "opencode/1.0 (linux)",
    })
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def normalize_zen_go_usage(payload: dict[str, Any]) -> dict[str, Any]:
    """Map the Zen Go usage shape onto the manager-scrape shape the record
    builder expects: {rolling: {usagePercent, resetInSec}, ...}."""
    usage = payload.get("usage") if isinstance(payload, dict) else None
    out: dict[str, Any] = {}
    if not isinstance(usage, dict):
        return out
    for key in ("rolling", "weekly", "monthly"):
        window = usage.get(key)
        if not isinstance(window, dict):
            continue
        percent = first(window, "percent", "usagePercent", "usage_percent")
        if percent is None:
            continue
        row: dict[str, Any] = {"usagePercent": number(percent)}
        resets = text(first(window, "resetsAt", "resets_at"))
        if resets:
            try:
                target_ms = dt.datetime.fromisoformat(resets.replace("Z", "+00:00")).timestamp() * 1000
                row["resetInSec"] = max(0, int((target_ms - now_ms()) / 1000))
            except Exception:
                pass
        out[key] = row
    return out


def opencode_go_record(payload: Any, generated_at: str) -> dict[str, Any]:
    """The synthetic panel record for the OpenCode Go plan.

    There is no auth file, no transcript, and no request-log coverage — the
    three dashboard pools are the entire truth, and the record says so.
    """
    limits = opencode_go_limits(payload)
    return {
        "schemaVersion": SCHEMA, "id": OPENCODE_GO_ID, "name": "OpenCode Go",
        "provider": "opencode-go", "account": "", "accountLabel": "OpenCode Go", "authFile": "",
        "updatedAt": generated_at, "tierLabel": "OpenCode Go · Go",
        "cpa": True, "cpaManaged": True, "hasLocalStats": False,
        "ready": bool(limits), "status": "", "statusMessage": "",
        "usageStatusText": "", "authHelpText": "", "unavailable": False, "errorText": "",
        "limits": limits,
        "recentDays": [{"date": d, "messageCount": 0, "tokens": 0, "requests": 0} for d in days7()],
        "modelUsage": {}, "todayTotalTokens": 0, "todayPrompts": 0, "todaySessions": 0,
        "totalPrompts": 0, "totalSessions": 0, "totalTokens": 0,
        "allTime": {"requests": 0, "tokens": 0, "successRate": None},
        "activeDays": 0, "activeDates": [], "dailyMetric": "tokens",
        "freshnessText": "Live from the opencode.ai Go dashboard · via CPA Manager",
        "scope": "account",
    }


def daily_targets(tgt: dict[str, Any], quota_payload: Any, day_offsets: list[int] | None = None) -> list[dict[str, Any]]:
    """Create one account-window target per requested local day.

    The default covers the full seven-day chart, but callers that refresh the
    chart every few minutes only need yesterday and today: the request-log
    aggregates fetched in the same pass own the older days via the merge in
    collect_one, and each monitoring window costs the server a slow upstream
    reconciliation.
    """
    windows = flatten_windows(quota_payload)
    template = windows[0] if windows else {}
    provider_window = first(template, "provider_window_id", "providerWindowId", "window_key", "windowKey") or "daily"
    raw_scope = template.get("model_scope") if isinstance(template.get("model_scope"), dict) else {}
    scope: dict[str, Any] = {
        "kind": text(first(raw_scope, "kind") or first(template, "model_scope_kind", "modelScopeKind")) or "all",
    }
    scope_key = first(raw_scope, "key") or first(template, "model_scope_key", "modelScopeKey")
    scope_models = raw_scope.get("models") if isinstance(raw_scope.get("models"), list) else first(template, "model_ids", "modelIds")
    if scope_key not in (None, ""):
        scope["key"] = scope_key
    if isinstance(scope_models, list) and scope_models:
        scope["models"] = scope_models
    out = []
    today = date_now()
    for offset in (day_offsets if day_offsets is not None else range(6, -1, -1)):
        day = today - dt.timedelta(days=offset)
        start = dt.datetime.combine(day, dt.time.min, tzinfo=dt.datetime.now().astimezone().tzinfo)
        end = start + dt.timedelta(days=1)
        row = dict(tgt)
        row.update({
            "request_key": f"{tgt.get('row_key', 'cpa')}:{day.isoformat()}",
            "row_key": tgt.get("row_key"),
            "window_key": f"{provider_window}:{day.isoformat()}",
            "provider_window_id": provider_window,
            "period": "current",
            "from_ms": int(start.timestamp() * 1000),
            "to_ms": int(end.timestamp() * 1000),
            "model_scope": scope,
        })
        out.append(row)
    return out


def friendly_inventory_error(raw: str) -> str:
    """Turn CPA inventory status_message into a human-readable line.

    The inventory often carries the upstream error as a JSON string like
    '{"error": {"code": 429, "message": "Resource has been exhausted...",
    "status": "RESOURCE_EXHAUSTED"}}' which horrendously dumps a raw JSON blob
    into the quota panel. Extract the inner message instead.
    """
    s = text(raw)
    if not s:
        return ""
    # Try JSON-encoded error envelope
    try:
        obj = json.loads(s)
        if isinstance(obj, dict):
            err = obj.get("error") if "error" in obj else obj
            if isinstance(err, dict):
                msg = text(err.get("message") or err.get("msg") or "")
                status = text(err.get("status") or "")
                code = err.get("code")
                if msg:
                    if status == "RESOURCE_EXHAUSTED" or code == 429:
                        if "exhausted" in msg.lower():
                            # "Resource has been exhausted (e.g. check quota)." at 60ch
                            # overflows the pill and, combined with the header,
                            # pushes the pill half a margin outside the card.
                            # The panel already shows which bucket is exhausted
                            # + its reset timer, so shorten to a single line.
                            return "Quota exhausted"
                        return msg
                    return msg
                if status:
                    return status + (f" ({code})" if code not in (None, "") else "")
                if code not in (None, ""):
                    return f"Error {code}"
            if isinstance(err, str) and text(err):
                return text(err)
    except Exception:
        pass
    # Not JSON: normalize whitespace and truncate overly long raw dumps.
    if s.startswith("{"):
        try:
            compact = json.dumps(json.loads(s), separators=(",", ":"))
            if len(compact) > 180:
                compact = compact[:180].rstrip() + "\u2026"
            return compact
        except Exception:
            pass
        # Fallback for malformed JSON-looking strings
        collapsed = re.sub(r"\s+", " ", s)
        if len(collapsed) > 200:
            collapsed = collapsed[:200].rstrip() + "\u2026"
        return collapsed
    collapsed = re.sub(r"\s+", " ", s)
    if len(collapsed) > 240:
        collapsed = collapsed[:240].rstrip() + "\u2026"
    return collapsed


def safe_error(error: ApiError, operation: str) -> str:
    if error.status == 401:
        return "CPA authentication unavailable"
    if error.status == 403:
        return "CPA management access denied"
    if error.status == 429:
        return "CPA rate limit reached"
    if error.status:
        return f"CPA {operation} unavailable (HTTP {error.status})"
    return f"CPA {operation} unavailable"


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        # os.fchmod is Unix-only. On Windows the profile directory is already
        # user-scoped, so skip the POSIX mode tightening.
        if hasattr(os, "fchmod"):
            os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
        os.replace(temp, path)
    finally:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass


def load_previous(sid: str, root: Path) -> dict[str, Any] | None:
    try:
        path = root / (sid + ".json")
        with path.open(encoding="utf-8") as handle:
            obj = json.load(handle)
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


def auth_is_disabled(item: dict[str, Any]) -> bool:
    return item.get("disabled") is True or text(item.get("status")).lower() == "disabled"


def inventory_state(item: dict[str, Any]) -> dict[str, Any]:
    """Public routing state only, never credential contents."""
    cooldowns = []
    for row in items(item.get("cooldowns")):
        cooldowns.append({key: row[key] for key in (
            "scope", "reason", "retry_at", "remaining_seconds", "model_key", "http_status",
        ) if key in row})
    # A credential-level cooldown is authoritative; model-only cooldowns
    # must not imply that every route for this credential is blocked.
    credential = [r for r in cooldowns if r.get("scope") == "credential"]
    retry_at = max((text(r.get("retry_at")) for r in credential), default="")
    return {"disabled": auth_is_disabled(item), "cooldowns": cooldowns,
            "cooldownUntil": retry_at}


def codex_inventory_limits(item: dict[str, Any]) -> tuple[list[dict[str, Any]], str, str]:
    """Recover saved Codex response-header quotas for an off credential."""
    quota = item.get("quota")
    if not isinstance(quota, dict):
        return [], "", ""
    signals = quota.get("signals")
    if not isinstance(signals, dict):
        return [], "", ""
    rate_limit = {}
    for slot, prefix in (("primary_window", "X-Codex-Primary"),
                         ("secondary_window", "X-Codex-Secondary")):
        minutes = integer(signals.get(prefix + "-Window-Minutes"))
        used = signals.get(prefix + "-Used-Percent")
        if not minutes or used is None:
            continue
        rate_limit[slot] = {
            "limit_window_seconds": minutes * 60,
            "used_percent": used,
            "reset_at": signals.get(prefix + "-Reset-At"),
        }
    return (codex_window_rows({"rate_limit": rate_limit}),
            text(quota.get("observed_at")), text(signals.get("X-Codex-Plan-Type")))


def disabled_record(item: dict[str, Any], sid: str, root: Path,
                    usage_stats: dict[str, Any] | None = None) -> dict[str, Any]:
    """Disabled/cooldown files stay visible, using only saved data.

    Do not reactivate them, refresh their OAuth, or send upstream probes.
    """
    meta = metadata(item)
    previous = load_previous(sid, root) or {}
    rec = dict(previous)
    saved_limits = previous.get("limits") or []
    saved_stamp = previous.get("quotaUpdatedAt") or previous.get("updatedAt") or ""
    rec.update({
        "schemaVersion": SCHEMA, "id": sid, "name": meta["label"],
        "provider": meta["provider"], "account": meta["account"],
        "accountLabel": meta["label"], "authFile": meta["file"],
        "cpa": True, "cpaManaged": True, "hasLocalStats": False,
        "status": "disabled", "unavailable": True,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
    })
    if usage_stats is not None:
        apply_usage_stats(rec, meta, item, usage_stats)
    live_inventory_rows, observed_at, plan = codex_inventory_limits(item) if meta["provider"].lower() == "codex" else ([], "", "")
    rec["limits"] = live_inventory_rows or saved_limits
    rec["quotaUpdatedAt"] = observed_at if live_inventory_rows else saved_stamp
    if plan:
        rec["tierLabel"] = provider_label(meta["provider"]) + " · " + plan.title()
    elif previous.get("tierLabel"):
        rec["tierLabel"] = previous["tierLabel"]
    else:
        rec.setdefault("tierLabel", provider_label(meta["provider"]))
    rec.update(inventory_state(item))
    rec["ready"] = bool(rec["limits"] or rec.get("totalTokens"))
    detail = friendly_inventory_error(text(first(item, "status_message", "statusMessage")))
    rec["statusMessage"] = detail
    rec["usageStatusText"] = detail or "Credential disabled in CPA"
    rec["errorText"] = ""  # A disabled route is not a failed quota refresh.
    return rec


def merge_pool_tokens(leader: dict[str, Any], members: list[dict[str, Any]]) -> dict[str, Any]:
    """Fold pool members' token ledgers into the leader record (in place).

    The panel shows one card per provider group, so the token ledger is
    summed across the group's auth files: daily bars, today's total and
    prompt count, the per-model-today table, and the lifetime totals.
    Limits and their reset timers stay per-account on each member record
    — OpenAI meters its 5-hour/weekly windows per file even inside the
    shared plan, and Google's accounts are plans of their own.
    """
    days = days7()
    today = days[-1]
    recent = leader.get("recentDays") or []
    by_date = {row.get("date"): row for row in recent if isinstance(row, dict)}
    models: dict[str, dict[str, Any]] = dict(leader.get("modelUsage") or {})
    today_tokens = integer(leader.get("todayTotalTokens"))
    today_prompts = integer(leader.get("todayPrompts"))
    total_tokens = integer(leader.get("totalTokens"))
    total_prompts = integer(leader.get("totalPrompts"))
    for member in members:
        if member is leader or not isinstance(member, dict):
            continue
        for row in member.get("recentDays") or []:
            if not isinstance(row, dict) or row.get("date") not in by_date:
                continue
            target_row = by_date[row["date"]]
            target_row["tokens"] = integer(target_row.get("tokens")) + integer(row.get("tokens") or row.get("messageCount"))
            target_row["messageCount"] = target_row["tokens"]
            target_row["requests"] = integer(target_row.get("requests")) + integer(row.get("requests"))
        for model, entry in (member.get("modelUsage") or {}).items():
            if not isinstance(entry, dict):
                continue
            bucket = models.setdefault(model, {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "totalTokens": 0, "tokens": 0})
            for key in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "totalTokens", "tokens"):
                bucket[key] = integer(bucket.get(key)) + integer(entry.get(key))
        today_tokens += integer(member.get("todayTotalTokens"))
        today_prompts += integer(member.get("todayPrompts"))
        total_tokens += integer(member.get("totalTokens"))
        total_prompts += integer(member.get("totalPrompts"))
        leader["poolAccounts"] = sorted(set((leader.get("poolAccounts") or []) + [member.get("accountLabel") or member.get("account") or member.get("name") or ""]))
    leader["recentDays"] = recent
    leader["modelUsage"] = models
    leader["todayTotalTokens"] = today_tokens
    leader["todayPrompts"] = today_prompts
    leader["totalTokens"] = total_tokens
    leader["totalPrompts"] = total_prompts
    if leader.get("allTime") is None:
        leader["allTime"] = {}
    leader["allTime"]["tokens"] = total_tokens
    leader["allTime"]["requests"] = total_prompts
    leader["activeDays"] = sum(1 for row in recent if integer(row.get("tokens")))
    leader["activeDates"] = [row.get("date") for row in recent if integer(row.get("tokens"))]
    if integer(leader.get("todayTotalTokens")):
        leader.setdefault("dailyMetric", "tokens")
    return leader


def write_pool_records(root: Path, pool_id: str, records: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Build the pooled token view for one pool_group and write its records.

    Every member record receives the pooled token ledger (daily charts,
    per-model-today table, totals) plus per-account limits under
    poolLimits, so the panel renders one card per provider group with all
    of the plan's meters on it. The member with real activity leads: its
    tierLabel/account head the pooled card. Membership is keyed by the
    auth-file names recorded on each record so a renamed or replaced file
    regroups automatically. Returns the leader record.
    """
    members = [r for r in records if isinstance(r, dict) and text(r.get("authFile"))]
    if not members:
        return None
    leader = next((r for r in members if integer(r.get("todayTotalTokens")) or (r.get("recentDays") and any(integer(row.get("tokens")) for row in r.get("recentDays") or []))), members[0])
    merge_pool_tokens(leader, [r for r in members if r is not leader])
    leader["poolGroup"] = pool_id
    # Per-account windows survive pooling as poolLimits so the plan's
    # 5-hour/weekly meters all show on the one pooled card. Recency tags
    # travel with each entry so the hero can still rank pooled files.
    leader["poolLimits"] = [{"accountLabel": r.get("accountLabel") or r.get("account") or "", "tierLabel": r.get("tierLabel") or "", "limits": r.get("limits") or [], "lastUsedAt": r.get("lastUsedAt") or ""} for r in members]
    for r in members:
        r["poolGroup"] = pool_id
        r["poolLimits"] = leader["poolLimits"]
        if r is not leader:
            r["poolMemberOf"] = leader.get("id")
        r["modelUsage"] = dict(leader.get("modelUsage") or {})
        r["recentDays"] = [dict(row) for row in (leader.get("recentDays") or [])]
        r["todayTotalTokens"] = leader.get("todayTotalTokens")
        r["todayPrompts"] = leader.get("todayPrompts")
        r["totalTokens"] = leader.get("totalTokens")
        r["totalPrompts"] = leader.get("totalPrompts")
        r["allTime"] = dict(leader.get("allTime") or {})
        atomic_write(root / (r.get("id") + ".json"), r)
    return leader


def collect_one(base: str, key: str, item: dict[str, Any], sid: str, root: Path, payloads: tuple[Any, Any, Any] | None = None, target_dates: dict[str, str] | None = None, usage_stats: dict[str, Any] | None = None, probes: dict[str, Any] | None = None) -> dict[str, Any]:
    if auth_is_disabled(item):
        return disabled_record(item, sid, root, usage_stats)
    meta = metadata(item)
    raw_inventory_status = text(first(item, "status_message", "statusMessage", "message"))
    if item.get("unavailable") is True and not raw_inventory_status:
        raw_inventory_status = "CPA credential unavailable"
    inventory_status = friendly_inventory_error(raw_inventory_status) if raw_inventory_status else ""
    common = {"schemaVersion": SCHEMA, "id": sid, "name": meta["label"], "provider": meta["provider"], "account": meta["account"], "accountLabel": meta["label"], "authFile": meta["file"], "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "tierLabel": text(first(item, "tier", "tier_label", "tierLabel", "plan", "planName")), "cpa": True, "cpaManaged": True, "hasLocalStats": False, "ready": False, "status": text(first(item, "status", "state")), "statusMessage": inventory_status}
    tgt = target(item, sid)
    monitored = meta["provider"].lower() in QUOTA_PROVIDERS
    try:
        # These are all read-only management calls. History is filtered to the
        # seven local calendar days below; CPA retains older history server-side.
        if payloads is None:
            history = request_json(base, key, "/v0/management/monitoring/account-history", "POST", {"accounts": [tgt], "catch_up": True}) if monitored else {"items": []}
            quota_account = {"row_key": sid, "provider": meta["provider"], "account": {k: v for k, v in tgt.items() if k != "row_key"}}
            quotas = request_json(base, key, "/v0/management/quota-snapshots/query", "POST", {"accounts": [quota_account], "include_inactive": False}) if monitored else {"items": []}
            window_usage = request_json(base, key, "/v0/management/monitoring/account-window-usage", "POST", {"windows": daily_targets(tgt, quotas)}) if monitored else {"items": []}
            if not monitored:
                usage_stats = usage_log_stats(request_json(base, key, "/v0/management/usage", timeout=45), meta["file"], meta["account"])
        else:
            history, quotas, window_usage = payloads
        if meta["provider"].lower() == "zai":
            # For Zai keep both: limits from the manager server's
            # zai-quota endpoint and tokens/charts from the request log
            # (same layering as cursor below).
            try:
                # Probes are pre-warmed in parallel by main(); only call
                # inline when that prefetch did not cover this account.
                if probes and "zai" in probes and probes["zai"][0]:
                    _zai_rows, _zai_plan = probes["zai"]
                else:
                    _zai_rows, _zai_plan = zai_live_limits(base, key, item)
            except Exception:
                _zai_rows, _zai_plan = [], ""
            _zai_usage = usage_stats if isinstance(usage_stats, dict) and usage_stats else usage_log_stats(request_json(base, key, "/v0/management/usage", timeout=45), meta["file"], meta["account"])
            apply_usage_stats(common, meta, item, _zai_usage)
            if _zai_rows:
                common["limits"] = _zai_rows
                if _zai_plan:
                    common["tierLabel"] = provider_label(meta["provider"]) + " · " + _zai_plan.title()
                # Mark ready when either signal is present
                common["ready"] = bool(common.get("ready") or _zai_rows)
            return common
        if not monitored or meta["provider"].lower() == "cursor":
            if meta["provider"].lower() == "cursor" and not str(meta["file"]).strip():
                # File-less inventories still fall back to account label.
                pass
            if meta["provider"].lower() == "cursor":
                # For cursor keep both: limits from the live dashboard and
                # tokens/charts from the request log.
                try:
                    # Probes are pre-warmed in parallel by main(); only call
                    # inline when that prefetch did not cover this account.
                    if probes and "cursor" in probes:
                        _cursor_rows, _cursor_plan = probes["cursor"]
                    else:
                        _cursor_rows, _cursor_plan = cursor_live_limits(base, key, item)
                except Exception:
                    _cursor_rows, _cursor_plan = [], ""
                if _cursor_rows:
                    # Merge onto the request-log record instead of replacing it.
                    _cursor_usage = usage_stats if isinstance(usage_stats, dict) and usage_stats else usage_log_stats(request_json(base, key, "/v0/management/usage", timeout=45), meta["file"], meta["account"])
                    apply_usage_stats(common, meta, item, _cursor_usage)
                    common["limits"] = _cursor_rows
                    if _cursor_plan:
                        common["tierLabel"] = provider_label(meta["provider"]) + " · " + _cursor_plan.title()
                    # Mark ready when either signal is present
                    common["ready"] = bool(common.get("ready") or _cursor_rows)
                    return common
                # No live quota — fall through to request-log-only record
            apply_usage_stats(common, meta, item, usage_stats or {})
            return common
        daily, models, daily_total, daily_prompts, requests_by_day = window_days(window_usage, target_dates or {})
        history_items = items(history)
        alltime = history_items[0] if history_items else {}
        total = integer(first(alltime, "total_tokens", "totalTokens")) or daily_total
        prompts = integer(first(alltime, "total_requests", "totalRequests", "requests")) or daily_prompts
        # Count upstream windows reported on the payload, even when their
        # numbers mean "empty" (used_percent == 0 or wrapped in nulls). A
        # flat window list from the endpoint beats a filled-in fallback, so
        # the fallback only runs when the upstream had nothing to say at all.
        def counted_upstream_windows(body: dict[str, Any]) -> int:
            if not isinstance(body, dict):
                return 0
            rl = first(body, "rate_limit", "rateLimit")
            rl = rl if isinstance(rl, dict) else {}
            count = 0
            for key in ("primary_window", "primaryWindow", "secondary_window", "secondaryWindow"):
                if isinstance(rl.get(key), dict):
                    count += 1
            add = first(body, "additional_rate_limits", "additionalRateLimits")
            if isinstance(add, list):
                for entry in add:
                    if not isinstance(entry, dict):
                        continue
                    nested = first(entry, "rate_limit", "rateLimit")
                    nested = nested if isinstance(nested, dict) else {}
                    for k in ("primary_window", "primaryWindow", "secondary_window", "secondaryWindow"):
                        if isinstance(nested.get(k), dict):
                            count += 1
            return count

        # Codex meters read live from the upstream usage endpoint; CPA's
        # stored snapshots only answer when the live probe had nothing at
        # all to say (no credential, endpoint down, or truly empty payload) —
        # a stale snapshot overwrites a genuine "0 now, resets later".
        live_limits, live_plan = ([], "")
        live_had_rows = False
        if meta["provider"].lower() == "codex":
            if probes and "codex" in probes:
                live_limits, live_plan = probes["codex"]
            else:
                live_limits, live_plan = codex_live_limits(base, key, item)
            live_had_rows = bool(live_limits)
        claude_quota = None
        if meta["provider"].lower() == "claude":
            claude_quota = probes.get("claude") if probes and "claude" in probes else claude_live_quota(base, key, item, load_previous(sid, root))
            live_limits = claude_quota["limits"]
            live_had_rows = bool(live_limits)
        if meta["provider"].lower() in ("codex", "claude"):
            fallback_limits = normalize_limits([quotas])
            # Any live-derived row beats stale snapshots, even at 0% with a
            # real reset — that's "fresh", not "missing".
            limits = live_limits if live_had_rows else fallback_limits
            # Edge: upstream reported slots but every row was dropped (e.g.
            # no used_percent and allowed:true with no reset) — let snapshots
            # fill in rather than showing nothing.
        else:
            fallback_limits = normalize_limits([quotas])
            limits = fallback_limits
        # Cursor never has CPA snapshots; its limits come from the live
        # dashboard probe before any snapshot-less upstream fallback.
        cursor_limits_extra: list[dict[str, Any]] = []
        if meta["provider"].lower() == "cursor":
            cursor_limits_extra, cursor_plan = cursor_live_limits(base, key, item)
            if cursor_limits_extra:
                limits = cursor_limits_extra
                if cursor_plan:
                    live_plan = cursor_plan
        if not limits:
            # The remaining snapshot-less providers are probed through CPA's
            # credential proxy instead.
            if probes and "antigravity" in probes:
                extra = probes["antigravity"]
            else:
                extra = upstream_quota_limits(base, key, meta, item)
            if extra:
                limits = extra
        if live_had_rows:
            # Live answer sets the tier label; fall back to entry/account only
            # if the endpoint omitted plan_type.
            plan = live_plan or text(first(item, "tier", "tier_label", "tierLabel", "plan", "planName")) or text(first(alltime, "plan_type", "planType"))
        else:
            # No live answer — let snapshots fill in.
            quota_windows = flatten_windows(quotas)
            quota_plan = next(
                (text(first(window, "plan_type", "planType")) for window in quota_windows if first(window, "plan_type", "planType")),
                "",
            )
            plan = quota_plan or text(first(alltime, "plan_type", "planType")) or text(first(item, "tier", "tier_label", "tierLabel", "plan", "planName")) or text(first(item, "plan", "planName", "tier"))
            if live_plan:
                plan = live_plan or plan
        common["tierLabel"] = provider_label(meta["provider"])
        if plan:
            common["tierLabel"] += " · " + plan.title()

        # Fallback: some CPA builds do not ship the monitoring endpoints at
        # all (account-history / account-window-usage / quota-snapshots answer
        # 404), which leaves monitored accounts with empty window aggregates
        # even though every completed request still lands in the plain request
        # log. When monitoring produced no activity whatsoever, rebuild the
        # daily charts and totals from the same request-log aggregates the
        # unmonitored providers use.
        #
        # Additionally, monitoring truncates early days once its retention
        # window has passed (first_seen > window start). In that case some
        # early local days show 0 from monitoring while the request log —
        # which is the live source of truth for the last 7 local days —
        # already has tokens. Merge per-day from the log where monitoring
        # is empty so the 7-day activity panel stays accurate.
        freshness = ""
        success_rate = first(alltime, "success_rate", "successRate")
        if (
            not any(daily.values())
            and not prompts
            and isinstance(usage_stats, dict)
            and (integer(usage_stats.get("totalTokens")) or integer(usage_stats.get("totalRequests")))
        ):
            daily = {d: integer((usage_stats.get("daily") or {}).get(d, 0)) for d in days7()}
            requests_by_day = {d: integer((usage_stats.get("requests") or {}).get(d, 0)) for d in days7()}
            total = integer(usage_stats.get("totalTokens"))
            prompts = integer(usage_stats.get("totalRequests"))
            successes = integer(usage_stats.get("successes"))
            if prompts:
                success_rate = (successes / prompts) if successes is not None else None
            freshness = text(usage_stats.get("sinceText"))
        elif isinstance(usage_stats, dict) and (usage_stats.get("daily") or usage_stats.get("requests")):
            # Partial truncation recovery: only fill in days where monitoring
            # is zero but the request log has observed tokens/requests for
            # the same local date. This repairs early-window truncation
            # (first_seen after the 7-day window start) without double
            # counting days that both sources agree on. Totals remain
            # account-history derived unless the log covers a strictly larger
            # set of active days, in which case flag with freshnessText.
            log_daily = usage_stats.get("daily") or {}
            log_reqs = usage_stats.get("requests") or {}
            patched = False
            for d in days7():
                log_tok = integer(log_daily.get(d, 0))
                log_req = integer(log_reqs.get(d, 0))
                # Recover truncated days: monitoring first_seen can miss the
                # early part of a local day (e.g. 08-22 before 16:41). Merge
                # from the request log whenever it has more coverage for the
                # same local date (log is ground truth for the 7-day chart).
                if log_tok > daily.get(d, 0) or log_req > requests_by_day.get(d, 0):
                    if log_tok != daily.get(d, 0) or log_req != requests_by_day.get(d, 0):
                        daily[d] = max(daily.get(d, 0), log_tok)
                        requests_by_day[d] = max(requests_by_day.get(d, 0), log_req)
                        patched = True
            if patched:
                # Daily charts are the live 7-day view; when the log widens
                # that window the account-history totals (which share the same
                # retention cutoff) are also truncated. The log's totals for
                # that same window — plus its all-time aggregate — are the
                # more complete signal, and modelUsage already reflects the
                # log's all-time sum. Promote totals when the patched 7-day
                # sum exceeds the history total so the panels stay consistent.
                seven_sum = sum(daily.values())
                seven_prompts = sum(requests_by_day.values())
                log_total = integer(usage_stats.get("totalTokens"))
                log_prompts = integer(usage_stats.get("totalRequests"))
                # Use the larger 7-day window sum and the log's all-time total
                # as the new ceiling. Success rate recomputed from log successes
                # when we adopt its totals.
                if log_total > total or seven_sum > total:
                    total = max(log_total, seven_sum, total)
                    prompts = max(log_prompts, seven_prompts, prompts)
                    successes = integer(usage_stats.get("successes"))
                    if prompts:
                        success_rate = (successes / prompts) if successes is not None else None
                # Surface log freshness whenever we patched from it
                if not freshness and text(usage_stats.get("sinceText")):
                    freshness = text(usage_stats.get("sinceText"))

        # Cursor-style executors can report tokens as zeros; fall back to a
        # request count rather than drawing a week of empty bars.
        metric = "tokens" if total else "requests"

        # TOKENS BY MODEL is *today only* per spec and zero-token models are
        # hidden. Build it from the request log's modelsToday (filtered to
        # days7()[-1] and stripped of zeros). Monitoring's window_days has no
        # per-model breakdown, so the log is the source of truth.
        # Backwards compat: prefer modelsToday, fall back to filtered models.
        log_models_today = {}
        log_models_all = {}
        if isinstance(usage_stats, dict):
            log_models_today = usage_stats.get("modelsToday") or {}
            log_models_all = usage_stats.get("models") or {}
            # If today's shard is empty but all-time has data for today (older
            # records before the shard was added), filter all-time down to today.
            if not log_models_today and log_models_all:
                today_str = days7()[-1]
                # Re-derive today models from the daily check is not needed:
                # usage_log_stats already split it; fallback stays empty.
                pass
        # Filter to >0 and today-only
        def _nonzero(bucket: dict[str, Any]) -> bool:
            return bool((bucket.get("totalTokens") or bucket.get("tokens") or 0) > 0 or (bucket.get("inputTokens", 0) + bucket.get("outputTokens", 0) > 0))
        # Prefer today shard; if empty and monitoring had no model data, show nothing (not all-time).
        if log_models_today:
            effective_models = {k: v for k, v in log_models_today.items() if _nonzero(v)}
        elif models:
            # models from window_days is empty (window has no per-model), so this is rarely taken
            effective_models = {k: v for k, v in models.items() if _nonzero(v)}
        else:
            # No today data: show empty rather than all-time ghosts (per request to hide 0 and day-only).
            effective_models = {}
        # Ensure totalTokens compat for today's entries
        for bucket in effective_models.values():
            if isinstance(bucket, dict) and "totalTokens" not in bucket:
                in_t = integer(bucket.get("inputTokens") or bucket.get("input_tokens"))
                out_t = integer(bucket.get("outputTokens") or bucket.get("output_tokens"))
                bucket["totalTokens"] = in_t + out_t
                bucket["tokens"] = in_t + out_t
        common.update({"ready": bool(total or limits), "usageStatusText": inventory_status, "authHelpText": inventory_status, "unavailable": bool(inventory_status) or bool(item.get("unavailable")), "limits": limits, "recentDays": [{"date": d, "messageCount": daily[d], "tokens": daily[d], "requests": requests_by_day[d]} for d in days7()], "modelUsage": effective_models, "todayTotalTokens": daily[days7()[-1]], "todayPrompts": requests_by_day[days7()[-1]], "todaySessions": 0, "totalPrompts": prompts, "totalSessions": 0, "totalTokens": total, "allTime": {"requests": prompts, "tokens": total, "successRate": success_rate}, "activeDays": sum(1 for n in daily.values() if n), "activeDates": [d for d, n in daily.items() if n], "dailyMetric": metric, "freshnessText": freshness, "errorText": inventory_status, "scope": "account"})
        if claude_quota is not None:
            common.update({k: v for k, v in claude_quota.items() if k != "limits"})
            if claude_quota["quotaError"]:
                common.update({"unavailable": True, "errorText": claude_quota["quotaError"],
                               "usageStatusText": claude_quota["quotaError"]})
    except ApiError as error:
        previous = load_previous(sid, root)
        if previous:
            common = previous
            common.update({"updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "usageStatusText": safe_error(error, "usage"), "error": safe_error(error, "usage"), "unavailable": True, "cpaTransient": True})
        else:
            common.update({"usageStatusText": safe_error(error, "usage"), "error": safe_error(error, "usage"), "unavailable": True, "cpaTransient": True, "limits": [], "recentDays": [{"date": d, "messageCount": 0, "tokens": 0} for d in days7()], "modelUsage": {}})
    common.update(inventory_state(item))
    return common


def main(config_override: str | None = None, cached_log: bool = False, refresh_log_only: bool = False) -> int:
    config_file = _path(config_override) if config_override else config_path()
    try:
        cfg_stat = config_file.stat()
        # Windows has no POSIX mode bits; every file reports group/other bits.
        if os.name != "nt" and cfg_stat.st_mode & 0o077:
            return 1
        # utf-8-sig also accepts Windows editors that save a UTF-8 BOM.
        cfg = json.loads(config_file.read_text(encoding="utf-8-sig"))
        base, key = text(cfg.get("baseUrl")), text(cfg.get("adminKey"))
    except Exception:
        return 1
    if not base or not key:
        return 1
    if refresh_log_only:
        if read_log_cache() is not None:
            return 3  # unchanged; the shell need not reapply the token ledger
        try:
            write_log_cache(request_json(base, key, "/v0/management/usage", timeout=45))
            return 0
        except ApiError:
            return 1
    root = usage_dir()
    try:
        inventory = list_files(request_json(base, key, "/v0/management/auth-files"))
    except ApiError:
        return 1  # no inventory means no safe stale-file cleanup
    ids = set()
    targets = [(item, stable_id(item), target(item, stable_id(item))) for item in inventory]
    metas = [metadata(item) for item, _, _ in targets]
    monitored = [(item, sid, tgt) for (item, sid, tgt), meta in zip(targets, metas) if meta["provider"].lower() in QUOTA_PROVIDERS and not auth_is_disabled(item)]
    quota_accounts = [{"row_key": sid, "provider": meta["provider"], "account": {k: v for k, v in tgt.items() if k != "row_key"}} for ((item, sid, tgt), meta) in zip(targets, metas) if meta["provider"].lower() in QUOTA_PROVIDERS and not auth_is_disabled(item)]
    # Enrich even the monitored accounts: the daily windows carry no
    # per-model token breakdown (the monitoring aggregate is by day), so
    # the per-model ledger — Gemini Flash vs Sonnet vs gpt-5.6 — only
    # lives in the request log. Cursor already layers the log underneath
    # its dashboard quota; do the same for Codex/Antigravity/Vertex/Kimi.

    # Every call in this phase is independent network wait, so they run
    # concurrently; serially the phase costs ~25s and is the whole reason a
    # quota refresh feels slow. account-window-usage is the one dependent
    # call (it wants the provider_window_id template from the snapshot
    # answer), so it is only submitted once that future resolves. It is
    # also split per account and trimmed to yesterday+today: the old
    # monolithic 7-day batch (42 windows) cost ~10s of server-side window
    # reconciliation alone, and the request-log merge in collect_one owns
    # the older chart days anyway.
    batch_failed = False
    log_failed = False
    log_stats: dict[str, dict[str, Any]] = {}
    usage_payload: Any = {}
    fresh_records: dict[str, dict[str, Any]] = {}

    def run_history() -> dict[str, Any]:
        nonlocal batch_failed
        if not monitored:
            return {"items": []}
        try:
            return request_json(base, key, "/v0/management/monitoring/account-history", "POST", {"accounts": [t for _, _, t in monitored], "catch_up": True})
        except ApiError:
            batch_failed = True
            return {"items": []}

    def run_quotas() -> dict[str, Any]:
        nonlocal batch_failed
        if not quota_accounts:
            return {"items": []}
        try:
            return request_json(base, key, "/v0/management/quota-snapshots/query", "POST", {"accounts": quota_accounts, "include_inactive": False})
        except ApiError:
            batch_failed = True
            return {"items": []}

    def run_log() -> Any:
        nonlocal log_failed
        cached = read_log_cache(allow_stale=cached_log)
        if cached_log:
            return cached["payload"] if cached is not None else {}
        if cached is not None:
            return cached["payload"]
        try:
            payload = request_json(base, key, "/v0/management/usage", timeout=45)
        except ApiError:
            log_failed = True
            # A stale cache still beats an empty log: charts keep their last
            # known shape instead of collapsing to zero for this pass.
            stale = read_log_cache(allow_stale=True)
            return stale["payload"] if stale is not None else {}
        write_log_cache(payload)
        return payload

    def probe_kind(provider: str) -> str:
        lowered = provider.lower()
        return lowered if lowered in ("codex", "claude", "cursor", "antigravity", "zai") else ""

    def run_probe(provider: str, item: dict[str, Any]) -> tuple[str, Any]:
        try:
            if provider == "codex":
                return "codex", codex_live_limits(base, key, item)
            if provider == "claude":
                return "claude", claude_live_quota(base, key, item, load_previous(stable_id(item), root))
            if provider == "cursor":
                return "cursor", cursor_live_limits(base, key, item)
            if provider == "zai":
                return "zai", zai_live_limits(base, key, item)
            if provider == "antigravity":
                return "antigravity", antigravity_quota_limits(
                    base, key, text(first(item, "auth_index", "authIndex")),
                    text(first(item, "project_id", "projectId")))
        except Exception:
            return "", None
        return "", None

    date_map: dict[str, str] = {}

    def run_windows(sid: str, tgt: dict[str, Any]) -> dict[str, Any]:
        nonlocal batch_failed
        try:
            account_quotas = {"items": [quota_by[sid]]} if sid in quota_by else {"items": []}
            windows = daily_targets(tgt, account_quotas, day_offsets=[1, 0])
            for row in windows:
                request_key = text(row.get("request_key"))
                date_map[request_key] = request_key.rsplit(":", 1)[-1]
            if not windows:
                return {"items": []}
            return request_json(base, key, "/v0/management/monitoring/account-window-usage", "POST", {"windows": windows})
        except ApiError:
            batch_failed = True
            return {"items": []}

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        history_future = pool.submit(run_history)
        quotas_future = pool.submit(run_quotas)
        log_future = pool.submit(run_log)
        probe_futures = {sid: pool.submit(run_probe, probe_kind(meta["provider"]), item)
                         for (item, sid, _tgt), meta in zip(targets, metas) if probe_kind(meta["provider"]) and not auth_is_disabled(item)}
        quotas_payload = quotas_future.result()
        quota_by = {text(x.get("row_key")): x for x in items(quotas_payload)}
        window_futures = {sid: pool.submit(run_windows, sid, tgt) for _item, sid, tgt in monitored}
        history_payload = history_future.result()
        if log_future is not None:
            usage_payload = log_future.result()
        probes: dict[str, dict[str, Any]] = {}
        for sid, probe_future in probe_futures.items():
            kind, result = probe_future.result()
            if kind:
                probes[sid] = {kind: result}
        window_payloads = {sid: probe_future.result() for sid, probe_future in window_futures.items()}

    for item, sid, _ in targets:
        meta = metadata(item)
        log_stats[sid] = usage_log_stats(usage_payload, meta["file"], meta["account"])
    # One log walk for every account: the hero ranks auth files by recency.
    last_used = last_used_by_auth(usage_payload) if isinstance(usage_payload, (dict, list)) else {}
    # Preserve the existing unmonitored aliases for the error-recovery
    # branch below which reasons about monitored vs unmonitored separately.
    history_by = {text(x.get("row_key")): x for x in items(history_payload)}
    win_by: dict[str, list[dict[str, Any]]] = {}
    for sid, window_payload in window_payloads.items():
        for row in items(window_payload):
            key_row = text(row.get("row_key")); win_by.setdefault(key_row, []).append(row)
    monitored_ids = {sid for _, sid, _ in monitored}
    for item, sid, tgt in targets:
        ids.add(sid)
        wins = {"items": win_by.get(sid, [])}
        rec = collect_one(base, key, item, sid, root, ( {"items": [history_by[sid]]} if sid in history_by else {"items": []}, {"items": [quota_by[sid]]} if sid in quota_by else {"items": []}, wins), {k: v for row in win_by.get(sid, []) for k, v in [(text(row.get("request_key")), date_map.get(text(row.get("request_key")), ""))]}, log_stats.get(sid), probes.get(sid))
        # A stale-record restore follows each record's own data source: a
        # monitoring batch outage says nothing about request-log providers,
        # and a failed log fetch says nothing about monitored ones.
        record_failed = (batch_failed and sid in monitored_ids) or (log_failed and sid not in monitored_ids)
        # A monitoring/log outage must not discard fresh data: live limits
        # probed through the credential proxy (codex/cursor/antigravity) are
        # real answers even when the monitoring endpoints are missing. Only
        # restore the stale copy when the fresh record collected nothing.
        fresh_has_data = bool(rec.get("limits")) or bool(rec.get("totalTokens")) or bool(rec.get("modelUsage"))
        # Most-recently-used rank for the hero: this file's newest log
        # entry ("" when the log never saw it — sorts last).
        # Recency resolution: prefer the durable auth_index key, then the
        # auth-file name, then the account id — the log rows carry at least
        # one of these even when the index field is absent.
        auth_index = text(first(item, "auth_index", "authIndex"))
        last_used_at = last_used.get(auth_index, "") if auth_index else ""
        if not last_used_at:
            fname = text(first(item, "file_name", "fileName", "filename", "name"))
            if fname:
                last_used_at = last_used.get("file:" + fname, "")
        if not last_used_at:
            acct = text(first(item, "account", "account_name", "accountName", "email", "account_email", "accountEmail", "label"))
            if acct:
                last_used_at = last_used.get("acct:" + acct, "")
        rec["lastUsedAt"] = last_used_at
        if record_failed and not fresh_has_data and load_previous(sid, root):
            rec = load_previous(sid, root) or rec
            rec.update({"updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "usageStatusText": "CPA usage unavailable", "error": "CPA usage unavailable", "errorText": "CPA usage unavailable", "unavailable": True, "cpaTransient": True})
            atomic_write(root / (sid + ".json"), rec)
            continue
        atomic_write(root / (sid + ".json"), rec)
        fresh_records[sid] = rec

    # Pool views: one token ledger per provider group whose auth files share
    # a plan — daily charts, per-model table, totals. The pooled view
    # replaces the per-account charts on whichever member record leads;
    # limits stay per-account on every member.
    for pool_id, providers in POOL_GROUPS:
        pool_members = [fresh_records[sid] for sid in fresh_records if fresh_records[sid].get("provider", "").lower() in providers]
        if len(pool_members) > 1:
            write_pool_records(root, pool_id, pool_members)
    # OpenCode Go has no auth file in the inventory; its three dashboard pools
    # arrive from the manager server's scrape. A failed scrape keeps the
    # last-good record on disk, flagged unavailable, instead of dropping the
    # provider from the panel.
    opencode_go = None
    try:
        og_payload = request_json(base, key, "/v0/management/opencode-go/quota")
        opencode_go = opencode_go_record(og_payload, dt.datetime.now(dt.timezone.utc).isoformat())
    except ApiError:
        # No CPA Manager scrape endpoint — fetch the same data straight from
        # opencode.ai's Zen Go usage endpoint using the API key from CPA's
        # openai-compatibility server config.
        try:
            og_key = opencode_go_api_key(request_json(base, key, "/v0/management/config"))
            if og_key:
                opencode_go = opencode_go_record(
                    normalize_zen_go_usage(zen_go_usage_payload(og_key)),
                    dt.datetime.now(dt.timezone.utc).isoformat(),
                )
        except Exception:
            opencode_go = None
    if opencode_go is None:
        opencode_go = load_previous(OPENCODE_GO_ID, root)
        if opencode_go is not None:
            message = "OpenCode Go quota unavailable"
            opencode_go.update({"updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                                "usageStatusText": message, "error": message, "errorText": message,
                                "unavailable": True, "cpaTransient": True})
    if opencode_go is not None:
        # The request log has every opencode-go completion — stamped with the
        # opencode-go/ requested-model prefix and no auth-file snapshot — so
        # the synthetic record gets real usage: daily charts, today's
        # per-model table, totals. The dashboard scrape still owns the
        # limits and the tier label.
        try:
            og_stats = usage_log_stats(usage_payload, "", "", "opencode-go/")
            og_total = integer(og_stats.get("totalTokens"))
            og_prompts = integer(og_stats.get("totalRequests"))
            if og_prompts:
                og_daily, og_reqs = og_stats.get("daily") or {}, og_stats.get("requests") or {}
                og_days = days7()
                og_today = og_days[-1]
                og_dates = sorted(og_stats.get("activeDates") or [])
                opencode_go.update({
                    "recentDays": [{"date": d, "messageCount": og_daily.get(d, 0), "tokens": og_daily.get(d, 0), "requests": og_reqs.get(d, 0)} for d in og_days],
                    "modelUsage": og_stats.get("modelsToday") or {},
                    "todayTotalTokens": og_daily.get(og_today, 0),
                    "todayPrompts": og_reqs.get(og_today, 0),
                    "totalPrompts": og_prompts,
                    "totalTokens": og_total,
                    "allTime": {"requests": og_prompts, "tokens": og_total, "successRate": (integer(og_stats.get("successes")) / og_prompts) if og_prompts else None},
                    "activeDays": len(og_dates),
                    "activeDates": og_dates,
                    "hasLocalStats": True,
                    "dailyMetric": "tokens" if og_total else "requests",
                    "freshnessText": "Limits live from opencode.ai · tokens from the CPA request log" + (f" · since {og_dates[0]}" if og_dates else ""),
                })
                opencode_go["ready"] = True
        except ApiError:
            pass
        ids.add(OPENCODE_GO_ID)
        atomic_write(root / (OPENCODE_GO_ID + ".json"), opencode_go)
    # Inventory succeeded: stale CPA records are now unambiguously removable.
    for path in root.glob(AGENT_PREFIX + "*.json"):
        if path.stem not in ids:
            try:
                path.unlink()
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--cpa-config")
    parser.add_argument("--cached-log", action="store_true")
    parser.add_argument("--refresh-log-only", action="store_true")
    args, _ = parser.parse_known_args()
    raise SystemExit(main(args.cpa_config, args.cached_log, args.refresh_log_only))
