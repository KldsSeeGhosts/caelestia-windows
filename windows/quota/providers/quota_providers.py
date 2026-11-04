#!/usr/bin/env python3
"""Quota provider helper for the Windows drawer: `py -3 -I quota_providers.py serve`.

The drawer starts this only while the Agent usage panel is on and kills it when
the panel goes off. It speaks JSON lines over stdin and stdout:

  in   {"type":"configure","baseUrl","adminKey","refreshIntervalMs","state":{...}}
       {"type":"summary","accounts":[{"ref","provider","keys":[...]}]}
       {"type":"refresh","force":bool}
  out  {"type":"snapshot","hub":{"state"},"accounts":[...],"nextDueAt","state":{...}}

The management key arrives on stdin only, never argv or the environment, and is
never written out: every stderr line goes through core.REDACTOR, and stdout
carries masked labels, windows and aggregates only. Hub mode is read-only.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import sys
import threading
import time

# -I leaves the script's own directory off sys.path; the modules sit beside it.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import antigravity  # noqa: E402
import claude  # noqa: E402
import codex  # noqa: E402
import core  # noqa: E402
import hub as hubmod  # noqa: E402
from scheduler import Scheduler  # noqa: E402

PROVIDERS = {m.KIND: m for m in (codex, claude, antigravity)}


class Ctx:
    """What a provider module sees of one account during one pass."""

    __slots__ = ("login", "now", "memory", "tag", "rate_windows")

    def __init__(self, login, now, memory, tag, rate_windows) -> None:
        self.login = login
        self.now = now
        self.memory = memory
        self.tag = tag
        self.rate_windows = rate_windows


class Account:
    def __init__(self, login, tag: str) -> None:
        self.login = login
        self.tag = tag
        self.memory: dict = {}
        self.error = ""
        self.read_at: float | None = None
        self.missing = False


class Service:
    def __init__(self, write, clock=time.time, http=core.http_request) -> None:
        self.write = write
        self.clock = clock
        self.http = http
        self.hub: hubmod.Hub | None = None
        self.hub_state = "idle"
        self.listed = False
        self.accounts: dict[str, Account] = {}
        self.order: list[str] = []
        self.scheduler = Scheduler()
        self.summary: list = []
        # Claude 429 windows by account tag: {tag: {"until": s, "strikes": n}}.
        self.rate_windows: dict = {}
        self.lock = threading.Lock()

    # -- Commands ------------------------------------------------------------

    def configure(self, message: dict) -> None:
        base = str(message.get("baseUrl") or "")
        key = str(message.get("adminKey") or "")
        core.REDACTOR.add(key)
        if self.hub is None:
            self.hub = hubmod.Hub(base, key, self.http, self.clock)
        else:
            changed = key != self.hub.key or hubmod.normalize_base(base) != self.hub.base_url
            self.hub.set_key(base, key)
            if changed:
                # Another hub or key: its logins are listed afresh.
                self.accounts.clear()
                self.order = []
                self.scheduler = Scheduler(self.scheduler.interval)
                self.listed = False
        self.scheduler.set_interval((core.number(message.get("refreshIntervalMs")) or 0) / 1000)
        state = core.obj(message.get("state"))
        # A key the hub refused before, in an earlier helper or shell: nothing is sent with it.
        self.hub.restore_refusal(state.get("refusal"))
        windows = core.obj(state.get("claudeWindows"))
        for tag, entry in windows.items():
            until = core.number(core.obj(entry).get("until"))
            strikes = core.number(core.obj(entry).get("strikes"))
            if until is not None and isinstance(tag, str):
                self.rate_windows.setdefault(tag, {"until": until / 1000, "strikes": int(strikes or 1)})

    def set_summary(self, rows) -> None:
        self.summary = []
        for row in core.items(rows):
            row = core.obj(row)
            keys = {str(k).strip().lower() for k in core.items(row.get("keys")) if isinstance(k, str) and k.strip()}
            if isinstance(row.get("ref"), str) and keys:
                self.summary.append((str(row.get("provider") or "").lower(), row["ref"], keys))

    # -- Pass ----------------------------------------------------------------

    def tag(self, kind: str, identity: str) -> str:
        # An opaque per-key tag, so the drawer and its cache never hold an email or id.
        return hmac.new(self.hub.key.encode("utf-8"), (kind + "\0" + identity).encode("utf-8"),
                        hashlib.sha256).hexdigest()[:12]

    def run_pass(self, force: bool = False) -> None:
        with self.lock:
            if self.hub is None:
                return
            now = self.clock()
            if self.hub.refusal:
                self.hub_state = self.hub.refusal
            elif force or not self.listed or now >= self.scheduler.listing_due:
                self.list_logins(now)
            for key in list(self.order):
                if self.hub.refusal:
                    break
                self.read_account(key, force)
            self.emit()

    def list_logins(self, now: float) -> None:
        try:
            logins = self.hub.logins()
        except hubmod.HubRefused as error:
            self.hub_state = error.code
            self.scheduler.listing_failed(now)
            return
        self.hub_state = "ok"
        self.listed = True
        self.scheduler.listed(now)
        seen = []
        for login in logins:
            key = self.tag(login.kind, login.identity)
            if key in seen:
                continue
            seen.append(key)
            account = self.accounts.get(key)
            if account is None:
                self.accounts[key] = Account(login, key)
            else:
                account.login = login  # auth_index can change when the hub renames a file
                account.missing = False
        # A login missing from the list goes only when the previous list lacked it too.
        order = list(seen)
        for key in self.order:
            if key in seen:
                continue
            account = self.accounts[key]
            if account.missing:
                del self.accounts[key]
                self.scheduler.forget(key)
                self.rate_windows.pop(key, None)
            else:
                account.missing = True
                order.append(key)
        self.order = order

    def read_account(self, key: str, force: bool) -> None:
        account = self.accounts[key]
        now = self.clock()
        if not self.scheduler.due(key, now, force):
            return
        provider = PROVIDERS[account.login.kind]
        ctx = Ctx(account.login, now, account.memory, key, self.rate_windows)
        login = account.login

        def call(method, url, headers, data=None):
            return self.hub.call(login, method, url, headers, data)

        apart = getattr(provider, "SECONDARY_APART", False)
        secondary = self.scheduler.secondary_due(key, now)
        try:
            if apart and secondary and account.read_at is not None:
                # Claude: the hourly reads take this pass's slot instead of usage.
                provider.secondary(ctx, call)
                self.scheduler.secondary_done(key, now)
            else:
                provider.read(ctx, call)
                if secondary and not apart:
                    try:
                        provider.secondary(ctx, call)
                        self.scheduler.secondary_done(key, now)
                    except core.ProviderError as error:
                        self.scheduler.secondary_done(key, now, error.retry_after)
                elif apart and account.read_at is None:
                    # First read done; the hourly reads follow in the next pass.
                    self.scheduler.entry(key).secondary_due = now
            account.error = ""
            account.read_at = now
            self.scheduler.read_ok(key, now)
        except core.ProviderError as error:
            account.error = error.code
            self.scheduler.read_failed(key, now, error.retry_after)
        except hubmod.HubRefused as error:
            if error.code in hubmod.HubRefused.CLOSES_GATE:
                self.hub_state = error.code
            elif error.code == "login_missing":
                self.scheduler.listing_due = now
            account.error = {"key_rejected": "hub_key", "banned": "hub_banned", "login_missing": "not_found",
                             "no_token": "unauthorized", "unreachable": "timeout"}.get(error.code, "error")
            self.scheduler.read_failed(key, now)
        except Exception as error:  # noqa: BLE001 - one bad answer must not end the helper
            core.log("%s read failed: %s" % (account.login.kind, type(error).__name__))
            account.error = "parse_failed"
            self.scheduler.read_failed(key, now)

    # -- Output --------------------------------------------------------------

    def summary_ref(self, login) -> str | None:
        for provider, ref, keys in self.summary:
            if provider == login.kind and keys & login.keys:
                return ref
        return None

    def account_record(self, account: Account) -> dict:
        provider = PROVIDERS[account.login.kind]
        ctx = Ctx(account.login, self.clock(), account.memory, account.tag, self.rate_windows)
        snap = provider.snapshot(ctx)
        record = {
            "id": "hub-" + account.tag,
            "provider": provider.KIND,
            "providerLabel": provider.LABEL,
            "label": core.mask_label(account.login.label),
            "plan": snap.get("plan", ""),
            "status": "error" if account.error else ("ok" if snap else "pending"),
            "error": {"code": account.error} if account.error else None,
            "windows": snap.get("windows", []),
            "readAt": core.iso(account.read_at),
            "summaryRef": self.summary_ref(account.login),
        }
        for field in ("resetCredits", "history"):
            if field in snap:
                record[field] = snap[field]
        return record

    def emit(self) -> None:
        accounts = [self.account_record(self.accounts[k]) for k in self.order]
        now = self.clock()
        windows = {tag: {"until": int(w["until"] * 1000), "strikes": w["strikes"]}
                   for tag, w in self.rate_windows.items() if w["until"] > now}
        state = {"claudeWindows": windows}
        if self.hub.refusal:
            state["refusal"] = self.hub.refused
        self.write({
            "type": "snapshot",
            "schemaVersion": core.SCHEMA_VERSION,
            "hub": {"state": self.hub_state},
            "accounts": accounts,
            "nextDueAt": None if self.hub.refusal else int(self.scheduler.next_deadline(now) * 1000),
            "state": state,
        })


def serve(stdin=None, stdout=None) -> int:
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    out_lock = threading.Lock()

    def write(message: dict) -> None:
        line = core.REDACTOR.redact(json.dumps(message, separators=(",", ":")))
        with out_lock:
            stdout.write(line + "\n")
            stdout.flush()

    service = Service(write)
    wake = threading.Condition()
    pending = {"run": False, "force": False}

    def worker() -> None:
        while True:
            with wake:
                while not pending["run"]:
                    wake.wait()
                force = pending["force"]
                pending["run"] = pending["force"] = False
            try:
                service.run_pass(force)
            except Exception as error:  # noqa: BLE001
                core.log("pass failed: %s" % type(error).__name__)

    threading.Thread(target=worker, daemon=True).start()

    def schedule(force: bool) -> None:
        with wake:
            pending["run"] = True
            pending["force"] = pending["force"] or force
            wake.notify()

    for raw in stdin:
        try:
            message = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(message, dict):
            continue
        kind = message.get("type")
        if kind == "configure":
            with service.lock:
                service.configure(message)
            schedule(False)
        elif kind == "summary":
            with service.lock:
                service.set_summary(message.get("accounts"))
                if service.hub is not None and service.listed:
                    service.emit()
        elif kind == "refresh":
            schedule(bool(message.get("force")))
        elif kind == "quit":
            break
    # stdin closed: the drawer is gone.
    return 0


def main(argv: list) -> int:
    if len(argv) < 2 or argv[1] != "serve":
        sys.stderr.write("usage: quota_providers.py serve\n")
        return 2
    for stream in (sys.stdin, sys.stdout):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    return serve()


if __name__ == "__main__":
    code = main(sys.argv)
    sys.stdout.flush()
    # The worker thread is a daemon; leave without waiting for a pass in flight.
    os._exit(code)
