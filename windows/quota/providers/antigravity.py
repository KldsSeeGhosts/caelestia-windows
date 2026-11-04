# Ported from OpenUsage (https://github.com/robinebers/openusage) at commit
# 629f1740, MIT License, Copyright (c) 2026 Robin Ebers. Sources:
#   Sources/OpenUsage/Providers/Antigravity/AntigravityUsageClient.swift
#   Sources/OpenUsage/Providers/Antigravity/AntigravityUsageMapper.swift
#   Sources/OpenUsage/Providers/Antigravity/AntigravityMetric.swift
# See THIRD_PARTY_NOTICES.md for the license text.
"""Antigravity usage, read-only.

`loadCodeAssist` gives the plan and the Cloud Code project; it runs on the
first read and then hourly. `retrieveUserQuotaSummary` runs every pass. Both
try production first and fall back to the daily endpoint. Google marks callers
without Antigravity's User-Agent UNSUPPORTED_CLIENT, so the request carries it
(see the ToS notes in windows/quota/README.md).
"""
from __future__ import annotations

import json
import platform

from core import ProviderError, items, number, obj, parse_time, title_case, window

KIND = "antigravity"
LABEL = "Antigravity"
AUTH_METHODS = ["hub"]
RESET_ACTION = None

BASES = ("https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com")
LOAD_PATH = "/v1internal:loadCodeAssist"
SUMMARY_PATH = "/v1internal:retrieveUserQuotaSummary"
LOAD_PAYLOAD = '{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}'
USER_AGENT = "antigravity/2.24.0 (aidev_client; os_type=windows; arch=%s)" % (
    "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "amd64")

# bucketId -> (window id, label): "5-hour", "Weekly", "Claude · 5-hour", "Claude · Weekly".
BUCKETS = (("gemini-5h", "five-hour", "5-hour"), ("gemini-weekly", "weekly", "Weekly"),
           ("3p-5h", "five-hour-claude", "5-hour"), ("3p-weekly", "seven-day-claude", "Weekly"))
ARGON_GROUP = "Gemini 4 Argon"
PAID_TIERS = {"g1-pro-tier": "Google AI Pro", "g1-ultra-tier": "Google AI Ultra",
              "g1-ultra-lite-tier": "Google AI Ultra Lite"}


def _headers() -> dict:
    return {"Accept": "application/json", "Content-Type": "application/json",
            "Authorization": "Bearer $TOKEN$", "User-Agent": USER_AGENT}


def _load(ctx, call) -> None:
    for base in BASES:
        try:
            response = call("POST", base + LOAD_PATH, _headers(), LOAD_PAYLOAD)
        except ProviderError:
            continue
        if response.status in (401, 403):
            raise ProviderError("unauthorized")
        if response.ok:
            body = obj(response.json())
            ctx.memory["plan"] = map_plan(body)
            project = body.get("cloudaicompanionProject")
            ctx.memory["project"] = project if isinstance(project, str) and project else None
            return
    raise ProviderError("error")


def read(ctx, call) -> None:
    if "project" not in ctx.memory:
        _load(ctx, call)
    project = ctx.memory.get("project")
    payload = json.dumps({"project": project} if project else {})
    bodies, statuses = [], []
    for index, base in enumerate(BASES):
        try:
            response = call("POST", base + SUMMARY_PATH, _headers(), payload)
        except ProviderError:
            continue
        statuses.append(response.status)
        if response.ok:
            body = response.json()
            bodies.append(body)
            # The daily endpoint can omit Gemini quotas; production is enough when complete.
            if index == 0 and is_complete(body):
                break
    if bodies:
        ctx.memory["summaries"] = bodies
        return
    if any(s in (401, 403) for s in statuses):
        raise ProviderError("unauthorized")
    if 429 in statuses:
        raise ProviderError("rate_limited")
    raise ProviderError("error")


def secondary(ctx, call) -> None:
    _load(ctx, call)


def snapshot(ctx) -> dict:
    if "summaries" not in ctx.memory:
        return {}
    return {"plan": ctx.memory.get("plan", ""), "windows": map_summaries(ctx.memory["summaries"])}


# -- Mapping -----------------------------------------------------------------

def _groups(body) -> list | None:
    body = obj(body)
    groups = obj(body.get("response")).get("groups", body.get("groups"))
    return groups if isinstance(groups, list) else None


def _used(fraction: float) -> float:
    return round((1 - max(0.0, min(1.0, fraction))) * 100)


def is_complete(body) -> bool:
    groups = _groups(body)
    if groups is None:
        return False
    usable = {obj(b).get("bucketId") for g in groups if obj(g).get("displayName") != ARGON_GROUP
              for b in items(obj(g).get("buckets")) if number(obj(b).get("remainingFraction")) is not None}
    return all(bucket in usable for bucket, _, _ in BUCKETS)


def map_summaries(bodies: list) -> list:
    lists = [g for g in (_groups(b) for b in bodies) if g is not None]
    pooled: dict = {}
    for groups in lists:
        for group in groups:
            group = obj(group)
            if group.get("displayName") == ARGON_GROUP:
                continue
            for bucket in items(group.get("buckets")):
                bucket = obj(bucket)
                bucket_id = bucket.get("bucketId")
                fraction = number(bucket.get("remainingFraction"))
                if bucket_id in pooled or fraction is None or not any(bucket_id == b for b, _, _ in BUCKETS):
                    continue
                pooled[bucket_id] = (fraction, parse_time(bucket.get("resetTime")))
    out = [window(wid, label, _used(pooled[b][0]), pooled[b][1]) for b, wid, label in BUCKETS if b in pooled]
    argon = next((a for a in (_argon(g) for g in lists) if a), None)
    if argon:
        at = next((i for i, w in enumerate(out) if w["id"].endswith("-claude")), len(out))
        out.insert(at, argon)
    return out


def _argon(groups: list) -> dict | None:
    buckets = [obj(b) for g in groups if obj(g).get("displayName") == ARGON_GROUP for b in items(obj(g).get("buckets"))]
    weekly = [b for b in buckets if b.get("window") == "weekly"]
    if len(weekly) != 1:
        return None
    bucket = weekly[0]
    if not bucket.get("bucketId") or any(bucket.get("bucketId") == b for b, _, _ in BUCKETS):
        return None
    if bucket.get("disabled") is not None and not isinstance(bucket.get("disabled"), bool):
        return None
    fraction = number(bucket.get("remainingFraction"))
    if bucket.get("disabled") is True or fraction is None:
        return None
    return window("seven-day-argon", "Weekly", _used(fraction), parse_time(bucket.get("resetTime")))


def map_plan(body: dict) -> str:
    paid = obj(body.get("paidTier"))
    if paid.get("id") in PAID_TIERS:
        return PAID_TIERS[paid["id"]]
    raw = paid.get("name") or obj(body.get("currentTier")).get("name")
    raw = raw.strip() if isinstance(raw, str) else ""
    if not raw:
        return ""
    for tier in ("Ultra Lite", "Ultra", "Pro"):
        if tier.lower() in raw.lower():
            return "Google AI " + tier
    return title_case(raw, " ")
