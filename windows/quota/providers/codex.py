# Ported from OpenUsage (https://github.com/robinebers/openusage) at commit
# 629f1740, MIT License, Copyright (c) 2026 Robin Ebers. Sources:
#   Sources/OpenUsage/Providers/Codex/CodexUsageClient.swift
#   Sources/OpenUsage/Providers/Codex/CodexUsageMapper.swift
#   Sources/OpenUsage/Providers/Codex/CodexUsageReports.swift
#   Sources/OpenUsage/Providers/Codex/CodexHistorySource.swift
#   Sources/OpenUsage/Providers/Codex/AccountProviderRuntime+CodexResets.swift
# See THIRD_PARTY_NOTICES.md for the license text.
"""ChatGPT (Codex) usage, read-only.

`read` fetches `wham/usage` every pass; `secondary` fetches the reset-credit
list and 30 days of history hourly. `snapshot` maps what was read into the
drawer's account shape. The consume endpoint is described in RESET_ACTION and
is never called.
"""
from __future__ import annotations

import time
import urllib.parse

from core import ProviderError, items, iso, number, obj, parse_time, require_json, title_case, utc_date, window

KIND = "codex"
LABEL = "Codex"
AUTH_METHODS = ["hub"]

USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
RESET_CREDITS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
REPORTS_URL = "https://chatgpt.com/backend-api/wham/"

# Documented only: claiming a reset spends an entitlement and needs a confirm
# step and maintainer sign-off. TODO(provider-integrations).
RESET_ACTION = {
    "method": "POST",
    "url": RESET_CREDITS_URL + "/consume",
    "body": ["credit_id", "redeem_request_id"],
    "headers": {"OpenAI-Beta": "codex-1", "originator": "Codex Desktop"},
}

SESSION_S = 5 * 3600
WEEK_S = 7 * 86400


def _headers(ctx, desktop: bool = False) -> dict:
    headers = {"Authorization": "Bearer $TOKEN$", "Accept": "application/json"}
    if ctx.login.chatgpt_account_id:
        headers["ChatGPT-Account-Id"] = ctx.login.chatgpt_account_id
    if desktop:
        # The reset-credit list expects the Codex desktop client's headers.
        headers.update({"OpenAI-Beta": "codex-1", "originator": "Codex Desktop"})
    return headers


def read(ctx, call) -> None:
    response = call("GET", USAGE_URL, _headers(ctx))
    body = require_json(response, ctx.now)
    ctx.memory["usage"] = {"body": body, "headers": dict(response.headers), "at": ctx.now}


def secondary(ctx, call) -> None:
    # The list only matters next to a usage body that agrees with its count.
    try:
        response = call("GET", RESET_CREDITS_URL, _headers(ctx, desktop=True))
        ctx.memory["credits"] = response.json() if response.ok else None
    except ProviderError:
        ctx.memory["credits"] = None
    end = ctx.now
    start = end - 29 * 86400
    query = urllib.parse.urlencode({
        "start_date": utc_date(start), "end_date": utc_date(end),
        "group_by": "day", "workspace_user": "true",
    })
    response = call("GET", REPORTS_URL + "analytics/daily-workspace-usage-counts?" + query, _headers(ctx))
    if response.status == 429:
        raise ProviderError("rate_limited", response.retry_after(ctx.now) or 3600)
    if response.ok:
        days = map_history(response.json())
        if days is not None:
            ctx.memory["history"] = days


def snapshot(ctx) -> dict:
    usage = ctx.memory.get("usage")
    if not usage:
        return {}
    out = map_usage(usage["body"], usage["headers"], ctx.memory.get("credits"), usage["at"])
    if ctx.memory.get("history") is not None:
        out["history"] = {"days": ctx.memory["history"]}
    return out


# -- Mapping -----------------------------------------------------------------

def _period(win: dict) -> float | None:
    return number(win.get("limit_window_seconds"))


def _reset(win: dict, now: float) -> float | None:
    at = number(win.get("reset_at"))
    if at is not None:
        return at
    after = number(win.get("reset_after_seconds"))
    return now + after if after is not None else None


def map_windows(rate_limit: dict, now: float, ids: tuple, header_percents: tuple = (None, None)) -> list:
    """Codex reports the 5-hour window first and the weekly second, but may put a
    lone weekly window in the primary slot: each meter takes the window whose
    duration is its own, else the window in its own slot when that window's
    duration is absent or unfamiliar."""
    slots = []
    for key, header in zip(("primary_window", "secondary_window"), header_percents):
        raw = rate_limit.get(key)
        if isinstance(raw, dict):
            slots.append((raw, number(raw.get("used_percent")) if number(raw.get("used_percent")) is not None else header))
        elif header is not None:
            slots.append(({}, header))
        else:
            slots.append(None)
    meters = ((ids[0], "5-hour", SESSION_S), (ids[1], "Weekly", WEEK_S))
    familiar = {SESSION_S, WEEK_S}
    out = []
    for slot, (window_id, label, period) in enumerate(meters):
        exact = next((s for s in slots if s and _period(s[0]) == period), None)
        fallback = slots[slot] if slots[slot] and _period(slots[slot][0]) not in familiar else None
        chosen = exact or fallback
        if not chosen or chosen[1] is None:
            continue
        out.append(window(window_id, label, chosen[1], _reset(chosen[0], now)))
    return out


def _available_count(source: dict) -> int | None:
    count = number(source.get("available_count"))
    return int(count) if count is not None and count >= 0 else None


def _available_expiries(source: dict) -> list:
    expiries = []
    for credit in items(source.get("credits")):
        credit = obj(credit)
        status = credit.get("status")
        if isinstance(status, str) and status != "available":
            continue
        at = parse_time(credit.get("expires_at"))
        if at is not None:
            expiries.append(at)
    return sorted(expiries)


def reset_credits(body: dict, dedicated: dict | None) -> dict | None:
    """The count comes from this pass's usage body; the hourly list supplies it only
    when the body has none, and its expiries only while it agrees with the count."""
    embedded = obj(body.get("rate_limit_reset_credits")) if isinstance(body.get("rate_limit_reset_credits"), dict) else None
    dedicated = dedicated if isinstance(dedicated, dict) and _available_count(dedicated) is not None else None
    count = (_available_count(embedded) if embedded else None)
    if count is None and dedicated:
        count = _available_count(dedicated)
    if count is None:
        return None
    if count <= 0:
        return {"count": 0, "expiries": []}
    if dedicated and _available_count(dedicated) == count:
        expiries = _available_expiries(dedicated)
    else:
        expiries = _available_expiries(embedded) if embedded else []
    return {"count": count, "expiries": [iso(t) for t in expiries]}


def format_plan(value) -> str:
    raw = value.strip() if isinstance(value, str) else ""
    if not raw:
        return ""
    return {
        "prolite": "Pro 100", "pro": "Pro 200", "promax": "Pro 500",
        "self_serve_business_prolite": "Business Premium",
    }.get(raw.lower(), title_case(raw))


def map_usage(body: dict, headers: dict, credits: dict | None, now: float | None = None) -> dict:
    now = time.time() if now is None else now
    rate_limit = obj(body.get("rate_limit"))
    lower = {str(k).lower(): v for k, v in (headers or {}).items()}
    windows = map_windows(rate_limit, now, ("five-hour", "weekly"), (
        number(lower.get("x-codex-primary-used-percent")), number(lower.get("x-codex-secondary-used-percent"))))
    for entry in items(body.get("additional_rate_limits")):
        entry = obj(entry)
        names = [str(entry.get(k) or "").lower() for k in ("limit_name", "metered_feature")]
        if any("spark" in n for n in names) and isinstance(entry.get("rate_limit"), dict):
            # Spark rows become "Spark · 5-hour" and "Spark · Weekly".
            windows += map_windows(entry["rate_limit"], now, ("five-hour-spark", "seven-day-spark"))
            break
    out = {"plan": format_plan(body.get("plan_type")), "windows": windows}
    resets = reset_credits(body, credits)
    if resets is not None:
        out["resetCredits"] = resets
    return out


_TOKENS = (("text_total_tokens", "tokens"), ("uncached_text_input_tokens", "input"),
           ("cached_text_input_tokens", "cached"), ("text_output_tokens", "output"))


def _count(value) -> float | None:
    n = number(value)
    return n if n is not None and n >= 0 else None


def map_history(body) -> dict | None:
    """`analytics/daily-workspace-usage-counts` as {date: {totals, byModel}}. A report with
    any malformed day is rejected whole, so a day is never partly read."""
    records = obj(body).get("data")
    if not isinstance(records, list):
        return None
    days: dict = {}
    for record in records:
        record = obj(record)
        date = record.get("date")
        totals = record.get("totals")
        if not isinstance(date, str) or len(date) < 10 or not isinstance(totals, dict):
            return None
        turns = _count(totals.get("turns"))
        if turns is None:
            return None
        values = {"turns": turns}
        for key, name in _TOKENS:
            if totals.get(key) is None:
                continue
            tokens = _count(totals.get(key))
            if tokens is None:
                return None
            values[name] = tokens
        by_model = {}
        for model in items(record.get("models")):
            model = obj(model)
            name = model.get("model") if isinstance(model.get("model"), str) else "Unknown"
            entry = by_model.setdefault(name, {})
            for key, field in (("turns", "turns"), ("text_total_tokens", "tokens")):
                n = _count(model.get(key))
                if n is not None:
                    entry[field] = entry.get(field, 0) + n
        day = days.setdefault(date[:10], {"totals": {}, "byModel": {}})
        for name, n in values.items():
            day["totals"][name] = day["totals"].get(name, 0) + n
        for name, entry in by_model.items():
            target = day["byModel"].setdefault(name, {})
            for field, n in entry.items():
                target[field] = target.get(field, 0) + n
    return days
