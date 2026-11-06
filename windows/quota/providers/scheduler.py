"""Per-account deadlines for hub reads, after OpenUsage's RefreshSetting.

Nothing here sleeps or polls. The service reports `next_deadline()` and the
drawer arms one single-shot timer for it (Quota.qml, hubTimer).

- An account is read automatically no more often than every 300 s, whatever
  quota.json asks for.
- A failed read backs off from 5 minutes, doubling to an hour, and honours a
  longer Retry-After.
- Secondary reads (plan, resets, history) and the hub's login list are hourly.
- Refresh now reads every account not read in the last 60 s.
"""
from __future__ import annotations

from core import BACKOFF_MAX_S, FORCE_SKIP_S, MIN_INTERVAL_S, SECONDARY_INTERVAL_S


class Entry:
    __slots__ = ("last_read", "next_due", "failures", "secondary_due")

    def __init__(self) -> None:
        self.last_read: float | None = None
        self.next_due = 0.0
        self.failures = 0
        self.secondary_due = 0.0


def backoff(failures: int) -> float:
    return min(BACKOFF_MAX_S, MIN_INTERVAL_S * 2 ** max(0, failures - 1))


class Scheduler:
    def __init__(self, interval_s: float = MIN_INTERVAL_S) -> None:
        self.entries: dict[str, Entry] = {}
        self.listing_due = 0.0
        self.set_interval(interval_s)

    def set_interval(self, interval_s: float) -> None:
        self.interval = max(float(MIN_INTERVAL_S), float(interval_s or 0))

    def entry(self, key: str) -> Entry:
        return self.entries.setdefault(key, Entry())

    def forget(self, key: str) -> None:
        self.entries.pop(key, None)

    def due(self, key: str, now: float, force: bool) -> bool:
        e = self.entry(key)
        if force:
            return e.last_read is None or now - e.last_read >= FORCE_SKIP_S
        return now >= e.next_due

    def secondary_due(self, key: str, now: float) -> bool:
        return now >= self.entry(key).secondary_due

    def read_ok(self, key: str, now: float) -> None:
        e = self.entry(key)
        e.last_read = now
        e.failures = 0
        e.next_due = now + self.interval

    def read_failed(self, key: str, now: float, retry_after: float | None = None) -> None:
        e = self.entry(key)
        e.last_read = now
        e.failures += 1
        e.next_due = now + max(self.interval, backoff(e.failures), retry_after or 0)

    def secondary_done(self, key: str, now: float, retry_after: float | None = None) -> None:
        self.entry(key).secondary_due = now + max(SECONDARY_INTERVAL_S, retry_after or 0)

    def listed(self, now: float) -> None:
        self.listing_due = now + SECONDARY_INTERVAL_S

    def listing_failed(self, now: float) -> None:
        self.listing_due = now + self.interval

    def next_deadline(self, now: float) -> float:
        deadlines = [self.listing_due] + [e.next_due for e in self.entries.values()]
        return max(now + 1, min(deadlines))
