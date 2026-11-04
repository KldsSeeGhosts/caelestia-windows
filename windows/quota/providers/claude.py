# Ported from OpenUsage (https://github.com/robinebers/openusage) at commit
# 629f1740, MIT License, Copyright (c) 2026 Robin Ebers. Sources:
#   Sources/OpenUsage/Providers/Claude/ClaudeUsageClient.swift
#   Sources/OpenUsage/Providers/Claude/ClaudeUsageMapper.swift
#   Sources/OpenUsage/Providers/Claude/ClaudeResetGrantStatus.swift
#   Sources/OpenUsage/Providers/Claude/ClaudeSession.swift
#   Sources/OpenUsage/Providers/Claude/AccountProviderRuntime+ClaudeUsage.swift
# See THIRD_PARTY_NOTICES.md for the license text.
"""Claude usage, read-only.

Anthropic budgets the usage endpoint at about 30 requests an hour per login,
shared with Claude Code, and holds a 429 penalty on its side. So every request
for a login goes through its 429 window, which the service persists in the
drawer cache, and the reset-grant read never runs in the same pass as a usage
read (Anthropic answers it with a 429 then). The reset claim endpoint is
described in RESET_ACTION and is never called.
"""
from __future__ import annotations

import re

from core import BACKOFF_MAX_S, MIN_INTERVAL_S, ProviderError, items, iso, number, obj, parse_time, require_json, window

KIND = "claude"
LABEL = "Claude"
AUTH_METHODS = ["hub"]
# Grants must not follow a usage read in the same pass.
SECONDARY_APART = True

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
GRANTS_URL = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
# Anthropic only returns grants to a Claude Code client, and rejects old versions.
CLAUDE_CODE_VERSION = "2.1.294"

# Documented only. TODO(provider-integrations).
RESET_ACTION = {
    "method": "POST",
    "url": "https://api.anthropic.com/api/organizations/{orgUUID}/reset_rate_limits",
    "body": ["program=cedar_ember", "grant_id", "request_id"],
}


def _headers(profile: bool = False) -> dict:
    headers = {"Authorization": "Bearer $TOKEN$", "Accept": "application/json",
               "anthropic-beta": "oauth-2025-04-20"}
    if not profile:
        headers["Content-Type"] = "application/json"
        headers["User-Agent"] = "claude-cli/%s (external, cli)" % CLAUDE_CODE_VERSION
    return headers


def backoff(strikes: int) -> float:
    return min(BACKOFF_MAX_S, MIN_INTERVAL_S * 2 ** max(0, strikes - 1))


def wait(ctx) -> float | None:
    entry = ctx.rate_windows.get(ctx.tag)
    if entry and ctx.now < entry["until"]:
        return entry["until"] - ctx.now
    return None


def _send(ctx, call, url: str, profile: bool = False):
    """Every request for this login, through its persisted 429 window."""
    remaining = wait(ctx)
    if remaining is not None:
        raise ProviderError("rate_limited", remaining)
    response = call("GET", url, _headers(profile))
    if response.status == 429:
        strikes = ctx.rate_windows.get(ctx.tag, {}).get("strikes", 0) + 1
        delay = max(response.retry_after(ctx.now) or 0, backoff(strikes))
        ctx.rate_windows[ctx.tag] = {"until": ctx.now + delay, "strikes": strikes}
        raise ProviderError("rate_limited", delay)
    if response.ok:
        ctx.rate_windows.pop(ctx.tag, None)
    return response


def read(ctx, call) -> None:
    ctx.memory["usage"] = require_json(_send(ctx, call, USAGE_URL), ctx.now)
    # A hub login shows its plan from its first read, as upstream does. A 429
    # here only sets the window; the usage just read still counts.
    if "plan" not in ctx.memory:
        try:
            _read_profile(ctx, call)
        except ProviderError:
            pass


def secondary(ctx, call) -> None:
    _read_profile(ctx, call)
    body = require_json(_send(ctx, call, GRANTS_URL), ctx.now)
    ctx.memory["grants"] = body.get("cedar_ember")


def _read_profile(ctx, call) -> None:
    try:
        body = require_json(_send(ctx, call, PROFILE_URL, profile=True), ctx.now)
    except ProviderError as error:
        if error.code == "rate_limited":
            raise
        ctx.memory.setdefault("plan", "")
        return
    ctx.memory["plan"] = format_plan(obj(body.get("organization")))


def snapshot(ctx) -> dict:
    usage = ctx.memory.get("usage")
    if usage is None:
        return {}
    out = {"plan": ctx.memory.get("plan", ""), "windows": map_usage(usage)}
    if "grants" in ctx.memory:
        resets = map_grants(ctx.memory["grants"], ctx.now)
        if resets is not None:
            out["resetCredits"] = resets
    return out


# -- Mapping -----------------------------------------------------------------

def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def map_usage(body: dict) -> list:
    out = []
    for key, window_id, label in (("five_hour", "five-hour", "5-hour"), ("seven_day", "weekly", "Weekly"),
                                  ("seven_day_sonnet", "seven-day-sonnet", "Weekly")):
        entry = body.get(key)
        used = number(obj(entry).get("utilization"))
        if isinstance(entry, dict) and used is not None:
            out.append(window(window_id, label, used, parse_time(entry.get("resets_at"))))
    # Model-scoped weekly limits moved from seven_day_<model> keys into `limits`.
    seen = {w["id"] for w in out}
    for entry in items(body.get("limits")):
        entry = obj(entry)
        name = obj(obj(entry.get("scope")).get("model")).get("display_name")
        used = number(entry.get("percent"))
        if entry.get("kind") != "weekly_scoped" or not isinstance(name, str) or not name.strip() or used is None:
            continue
        window_id = "seven-day-" + _slug(name)
        if window_id in seen:
            continue
        seen.add(window_id)
        out.append(window(window_id, "Weekly", used, parse_time(entry.get("resets_at"))))
    return out


def format_plan(organization: dict) -> str:
    kind = organization.get("organization_type")
    if not isinstance(kind, str):
        return ""
    raw = (kind[len("claude_"):] if kind.startswith("claude_") else kind).strip()
    if not raw:
        return ""
    base = " ".join(w[:1].upper() + w[1:].lower() for w in raw.replace("_", " ").split())
    tier = organization.get("rate_limit_tier") if isinstance(organization.get("rate_limit_tier"), str) else ""
    if base == "Ultra" or (base == "Max" and ("ultra" in tier or "20x" in tier)):
        return "Ultra"
    if base == "Max":
        return base
    match = re.search(r"\d+x", tier)
    return base + " " + match.group(0) if match else base


def map_grants(value, now: float) -> dict | None:
    """`cedar_ember` as {count, expiries}: each grant counts its resets_left, until it ends.
    A malformed grant drops the whole block, as upstream does."""
    if not isinstance(value, dict):
        return None
    grants = []
    for grant in items(value.get("grants")):
        grant = obj(grant)
        left = number(grant.get("resets_left"))
        if not isinstance(grant.get("id"), str) or not grant.get("id") or left is None:
            return None
        grants.append((max(0, int(left)), parse_time(grant.get("ends_at"))))
    count, expiries = 0, []
    if value.get("eligible") is True:
        for left, ends in grants:
            if left < 1 or (ends is not None and ends <= now):
                continue
            count += left
            if ends is not None:
                expiries += [ends] * left
    return {"count": count, "expiries": [iso(t) for t in sorted(expiries)]}
