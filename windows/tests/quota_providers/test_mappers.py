"""Mapper unit tests for the quota provider helper: pure functions, no network."""
from __future__ import annotations

import os
import sys
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "quota"))
sys.path.insert(0, os.path.join(ROOT, "providers"))

import antigravity  # noqa: E402
import claude  # noqa: E402
import codex  # noqa: E402
from core import parse_time  # noqa: E402

NOW = 1_800_000_000.0


def ids(windows):
    return [(w["id"], w["usedPercent"]) for w in windows]


class CodexWindows(unittest.TestCase):
    def test_primary_and_secondary_by_duration(self):
        out = codex.map_usage({"plan_type": "pro", "rate_limit": {
            "primary_window": {"used_percent": 34, "limit_window_seconds": 18000, "reset_after_seconds": 60},
            "secondary_window": {"used_percent": 72, "limit_window_seconds": 604800, "reset_at": NOW + 100},
        }}, {}, None, NOW)
        self.assertEqual(ids(out["windows"]), [("five-hour", 34), ("weekly", 72)])
        self.assertEqual(parse_time(out["windows"][0]["resetAt"]), NOW + 60)
        self.assertEqual(parse_time(out["windows"][1]["resetAt"]), NOW + 100)
        self.assertEqual(out["plan"], "Pro 200")

    def test_lone_weekly_in_the_primary_slot(self):
        out = codex.map_usage({"rate_limit": {
            "primary_window": {"used_percent": 40, "limit_window_seconds": 604800},
            "secondary_window": None,
        }}, {}, None, NOW)
        self.assertEqual(ids(out["windows"]), [("weekly", 40)])

    def test_header_percent_and_missing_fields(self):
        out = codex.map_usage({"rate_limit": {"primary_window": None}, "plan_type": None},
                              {"X-Codex-Primary-Used-Percent": "12.5"}, None, NOW)
        self.assertEqual(ids(out["windows"]), [("five-hour", 12.5)])
        self.assertEqual(out["windows"][0]["resetAt"], "")
        self.assertEqual(out["plan"], "")
        self.assertNotIn("resetCredits", out)
        self.assertEqual(codex.map_usage({}, {}, None, NOW)["windows"], [])

    def test_spark_rows_are_scoped(self):
        out = codex.map_usage({"additional_rate_limits": [None, {"limit_name": "GPT Spark", "rate_limit": {
            "primary_window": {"used_percent": 8, "limit_window_seconds": 18000}}}]}, {}, None, NOW)
        self.assertEqual(ids(out["windows"]), [("five-hour-spark", 8)])

    def test_reset_credits_count_and_expiries(self):
        listing = {"available_count": 2, "credits": [
            {"id": "a", "status": "available", "expires_at": "2027-01-02T00:00:00Z"},
            {"id": "b", "status": "redeemed", "expires_at": "2027-01-01T00:00:00Z"},
            {"id": "c", "expires_at": NOW + 10},
        ]}
        out = codex.map_usage({"rate_limit_reset_credits": {"available_count": 2}}, {}, listing, NOW)
        self.assertEqual(out["resetCredits"]["count"], 2)
        self.assertEqual([parse_time(e) for e in out["resetCredits"]["expiries"]],
                         sorted([NOW + 10, parse_time("2027-01-02T00:00:00Z")]))

    def test_stale_list_never_stands_in_for_the_count(self):
        listing = {"available_count": 3, "credits": [{"expires_at": NOW + 5}] * 3}
        out = codex.map_usage({"rate_limit_reset_credits": {"available_count": 1}}, {}, listing, NOW)
        self.assertEqual(out["resetCredits"], {"count": 1, "expiries": []})
        self.assertEqual(codex.map_usage({"rate_limit_reset_credits": {"available_count": None}}, {}, None, NOW)
                         .get("resetCredits"), None)
        self.assertEqual(codex.map_usage({"rate_limit_reset_credits": {"available_count": 0}}, {}, listing, NOW)
                         ["resetCredits"], {"count": 0, "expiries": []})


class CodexHistory(unittest.TestCase):
    def test_days_totals_and_models(self):
        days = codex.map_history({"data": [
            {"date": "2026-11-03T00:00:00Z", "totals": {"turns": 4, "text_total_tokens": 100,
                                                       "uncached_text_input_tokens": 10, "cached_text_input_tokens": 80,
                                                       "text_output_tokens": 10},
             "models": [{"model": "m1", "turns": 3, "text_total_tokens": 70}, {"turns": 1, "text_total_tokens": 30}]},
            {"date": "2026-11-03", "totals": {"turns": 1, "text_total_tokens": None}},
        ]})
        day = days["2026-11-03"]
        self.assertEqual(day["totals"], {"turns": 5, "tokens": 100, "input": 10, "cached": 80, "output": 10})
        self.assertEqual(day["byModel"], {"m1": {"turns": 3, "tokens": 70}, "Unknown": {"turns": 1, "tokens": 30}})

    def test_malformed_report_is_rejected_whole(self):
        self.assertIsNone(codex.map_history({"data": [{"date": "2026-11-03", "totals": {"turns": None}}]}))
        self.assertIsNone(codex.map_history({"data": [{"date": "2026-11-03", "totals": {"turns": 1, "text_total_tokens": -4}}]}))
        self.assertIsNone(codex.map_history({"data": None}))
        self.assertIsNone(codex.map_history(None))
        self.assertEqual(codex.map_history({"data": []}), {})


class ClaudeMapping(unittest.TestCase):
    def test_windows_and_scoped_weekly(self):
        out = claude.map_usage({
            "five_hour": {"utilization": 58, "resets_at": "2026-11-04T14:00:00Z"},
            "seven_day": {"utilization": 77, "resets_at": None},
            "seven_day_sonnet": {"utilization": 12},
            "seven_day_opus": None,
            "limits": [{"kind": "weekly_scoped", "percent": 91, "scope": {"model": {"display_name": "Fable"}}},
                       {"kind": "weekly_scoped", "percent": None, "scope": {"model": {"display_name": "Opus"}}},
                       {"kind": "monthly", "percent": 5, "scope": {"model": {"display_name": "X"}}},
                       {"kind": "weekly_scoped", "percent": 3, "scope": {"model": {"display_name": "Sonnet"}}}],
        })
        self.assertEqual(ids(out), [("five-hour", 58), ("weekly", 77), ("seven-day-sonnet", 12), ("seven-day-fable", 91)])
        self.assertEqual(out[1]["resetAt"], "")

    def test_missing_and_null(self):
        self.assertEqual(claude.map_usage({"five_hour": None, "seven_day": {"utilization": None}, "limits": None}), [])

    def test_plan(self):
        self.assertEqual(claude.format_plan({"organization_type": "claude_max", "rate_limit_tier": "default_claude_max_5x"}), "Max")
        self.assertEqual(claude.format_plan({"organization_type": "claude_max", "rate_limit_tier": "x_20x"}), "Ultra")
        self.assertEqual(claude.format_plan({"organization_type": "claude_team", "rate_limit_tier": "tier_5x"}), "Team 5x")
        self.assertEqual(claude.format_plan({"organization_type": None}), "")

    def test_grants(self):
        out = claude.map_grants({"eligible": True, "grants": [
            {"id": "g1", "resets_left": 2, "ends_at": NOW + 100},
            {"id": "g2", "resets_left": 1, "ends_at": NOW - 1},
            {"id": "g3", "resets_left": 0, "ends_at": NOW + 5},
            {"id": "g4", "resets_left": 1, "ends_at": None},
        ]}, NOW)
        self.assertEqual(out["count"], 3)
        self.assertEqual([parse_time(e) for e in out["expiries"]], [NOW + 100, NOW + 100])
        self.assertEqual(claude.map_grants({"eligible": False, "grants": [{"id": "g", "resets_left": 4}]}, NOW),
                         {"count": 0, "expiries": []})
        self.assertIsNone(claude.map_grants({"eligible": True, "grants": [{"id": "", "resets_left": 1}]}, NOW))
        self.assertIsNone(claude.map_grants(None, NOW))


class AntigravityMapping(unittest.TestCase):
    def test_buckets_argon_and_fallback_pooling(self):
        production = {"response": {"groups": [
            {"displayName": "Gemini", "buckets": [{"bucketId": "gemini-5h", "remainingFraction": 0.81, "resetTime": "2026-11-04T15:00:00Z"}]},
            {"displayName": "Gemini 4 Argon", "buckets": [{"bucketId": "argon-weekly", "remainingFraction": 0.95, "window": "weekly"}]},
            {"displayName": "Third", "buckets": [{"bucketId": "3p-5h", "remainingFraction": 0.27}, {"bucketId": "mystery", "remainingFraction": 1}]},
        ]}}
        daily = {"groups": [{"displayName": "Gemini", "buckets": [
            {"bucketId": "gemini-5h", "remainingFraction": 0.1}, {"bucketId": "gemini-weekly", "remainingFraction": 0.64},
            {"bucketId": "3p-weekly", "remainingFraction": None}]}]}
        self.assertFalse(antigravity.is_complete(production))
        out = antigravity.map_summaries([production, daily])
        self.assertEqual(ids(out), [("five-hour", 19), ("weekly", 36), ("seven-day-argon", 5), ("five-hour-claude", 73)])

    def test_missing_and_null(self):
        self.assertEqual(antigravity.map_summaries([None, {"response": None}, {"groups": None}]), [])
        self.assertEqual(antigravity.map_summaries([{"groups": [{"displayName": "Gemini 4 Argon", "buckets": [
            {"bucketId": "a", "remainingFraction": 0.5, "window": "weekly", "disabled": "yes"}]}]}]), [])

    def test_plan(self):
        self.assertEqual(antigravity.map_plan({"paidTier": {"id": "g1-ultra-tier"}}), "Google AI Ultra")
        self.assertEqual(antigravity.map_plan({"currentTier": {"name": "free tier"}}), "Free Tier")
        self.assertEqual(antigravity.map_plan({"paidTier": None, "currentTier": None}), "")


if __name__ == "__main__":
    unittest.main()
