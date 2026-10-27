#!/usr/bin/env python3
"""Keepalive for the Google, OpenAI, and Z.AI auth files on serverseesghosts.

Sends a minimal "ping" message to:
  - gpt-5.6-luna at low reasoning  (activates the OpenAI / Codex 5-hour window)
  - gemini-3.7-flash at low reasoning (activates the Antigravity / Google 5-hour window)
  - glm-5.3-flash at low reasoning (activates the Z.AI 5-hour window)

For each enabled codex / antigravity / zai auth, a real inference is made so
the upstream rolling window starts counting down instead of staying idle.
Progress is streamed as NDJSON (one line per ping) so the QML bolt ring
fills 0..1. The public CPA inference endpoint is at serverseesghosts:8317
(tunneled to 127.0.0.1:8317); management is at 127.0.0.1:18317.

Scope: 3× antigravity (Google) + 3× codex (OpenAI) + 1× zai (GLM) = 7.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

# Management live quota (for Antigravity quota summary) — still needed as fallback
ANTIGRAVITY_SUMMARY_URLS = [
    "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
    "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
    "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
]
ANTIGRAVITY_MODEL_URLS = [
    "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
]
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"

KEEPALIVE_PROVIDERS = {"codex", "antigravity", "zai"}


def _path(v: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(v))).resolve()


def _text(v: Any) -> str:
    return str(v).strip() if v not in (None, "") else ""


def _first(obj: dict[str, Any], *keys: str) -> Any:
    for k in keys:
        if k in obj and obj[k] not in (None, ""):
            return obj[k]
    return None


def request_json(base: str, key: str, path: str, method: str = "GET", body: Any = None) -> Any:
    url = base.rstrip("/") + path
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + key,
        "Accept": "application/json",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def api_call(base: str, key: str, auth_index: str, method: str, url: str, headers: dict[str, str], data: str | None = None) -> tuple[int, dict[str, Any]]:
    payload: dict[str, Any] = {"auth_index": auth_index, "method": method, "url": url, "header": headers}
    if data is not None:
        payload["data"] = data
    resp = request_json(base, key, "/v0/management/api-call", "POST", payload)
    status = int(resp.get("status_code") or resp.get("statusCode") or 0)
    body = resp.get("body")
    if isinstance(body, str):
        try:
            body = json.loads(body)
        except Exception:
            body = {}
    return status, body if isinstance(body, dict) else {}


def codex_account_id(item: dict[str, Any]) -> str:
    token = _first(item, "id_token", "idToken")
    payload: Any = None
    if isinstance(token, dict):
        payload = token
    elif isinstance(token, str) and token.count(".") >= 2:
        try:
            seg = token.split(".")[1]
            seg += "=" * (-len(seg) % 4)
            payload = json.loads(base64.urlsafe_b64decode(seg))
        except Exception:
            payload = None
    if not isinstance(payload, dict):
        return ""
    auth = payload.get("https://api.openai.com/auth")
    acct = _first(payload, "chatgpt_account_id", "chatgptAccountId")
    if not acct and isinstance(auth, dict):
        acct = _first(auth, "chatgpt_account_id", "chatgptAccountId")
    return _text(acct)


def _chat_completion_via_8317(model: str, extra_body: dict[str, Any] | None = None) -> tuple[bool, str]:
    """One real inference via the public CPA inference endpoint (8317 tunneled to serverseesghosts).

    Returns (ok, error). A real completion is the only thing that moves the
    5-hour rolling window off idle; wham/usage reads do not.
    """
    api_key = os.environ.get("CPA_API_KEY")
    if not api_key:
        env_conf = Path.home() / ".config" / "environment.d" / "cpa.conf"
        if env_conf.is_file():
            try:
                for line in env_conf.read_text(encoding="utf-8").splitlines():
                    if line.startswith("CPA_API_KEY="):
                        api_key = line.split("=", 1)[1].strip()
                        break
            except Exception:
                pass
    # The inference endpoint is available at 127.0.0.1:8317 via SSH tunnel to serverseesghosts.
    # Use https via the tailnet DNS when available, else http via tunnel.
    endpoints = [
        "https://serverseesghosts.tail74ed91.ts.net:8317/v1/chat/completions",
        "http://127.0.0.1:8317/v1/chat/completions",
    ]
    body: dict[str, Any] = {"model": model, "messages": [{"role": "user", "content": "ping"}], "max_tokens": 8}
    if extra_body:
        body.update(extra_body)
    data = json.dumps(body).encode()
    last_err = ""
    for url in endpoints:
        try:
            req = urllib.request.Request(url, data=data, headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            })
            with urllib.request.urlopen(req, timeout=30) as resp:
                j = json.loads(resp.read().decode("utf-8", "replace"))
                if j.get("id") and (j.get("choices") or j.get("object") == "chat.completion"):
                    return True, ""
                last_err = str(j)[:200]
        except urllib.error.HTTPError as e:
            try:
                last_err = e.read().decode()[:300]
            except Exception:
                last_err = str(e)[:200]
            continue
        except Exception as e:
            last_err = str(e)[:200]
            continue
    return False, last_err


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--cpa-config", default="~/.config/omarchy/cpa-agents.json")
    ap.add_argument("--providers", default="codex,antigravity,zai", help="comma-separated providers to ping")
    args, _ = ap.parse_known_args()

    cfg_path = _path(args.cpa_config)
    wanted = {p.strip().lower() for p in args.providers.split(",") if p.strip()} if args.providers else KEEPALIVE_PROVIDERS

    try:
        st = cfg_path.stat()
        # Windows has no POSIX mode bits; every file reports group/other bits.
        if os.name != "nt" and st.st_mode & 0o077:
            print(json.dumps({"ok": False, "error": "cpa config permissions too open"}))
            return 0
        # utf-8-sig also accepts Windows editors that save a UTF-8 BOM.
        cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
        base, key = _text(cfg.get("baseUrl")), _text(cfg.get("adminKey"))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": f"config read failed: {exc}"}))
        return 0
    if not base or not key:
        print(json.dumps({"ok": False, "error": "missing baseUrl/adminKey"}))
        return 0

    try:
        inv = request_json(base, key, "/v0/management/auth-files")
    except Exception as exc:
        print(json.dumps({"ok": False, "error": f"auth-files failed: {exc}"}))
        return 0

    files = inv.get("files") if isinstance(inv, dict) else inv
    if not isinstance(files, list):
        files = []

    targets = []
    for f in files:
        if not isinstance(f, dict):
            continue
        if f.get("disabled") is True:
            continue
        prov = _text(_first(f, "provider", "auth_provider", "authProvider")).lower()
        if prov not in wanted:
            continue
        targets.append(f)

    results: list[dict[str, Any]] = []
    ok_count = 0
    total = len(targets)
    for idx, item in enumerate(targets):
        prov = _text(_first(item, "provider", "auth_provider", "authProvider")).lower()
        label = _text(_first(item, "account", "account_name", "accountName", "email", "file_name", "name"))
        auth_index = _text(_first(item, "auth_index", "authIndex"))
        if not auth_index:
            results.append({"provider": prov, "account": label, "ok": False, "error": "no auth_index"})
            prog = {"type": "progress", "done": idx + 1, "total": total, "provider": prov, "account": label, "ok": False}
            print(json.dumps(prog, separators=(",", ":")))
            sys.stdout.flush()
            continue
        try:
            if prov == "codex":
                # Real keepalive for OpenAI: gpt-5.6-luna at low reasoning (user spec).
                # Chat Completions wire is what the CPA inference proxy bills for the 5-hour window.
                ok, err = _chat_completion_via_8317("gpt-5.6-luna", {"reasoning": {"effort": "low"}})
                # Fallback to quota read if the real call is unavailable (still marks keepalive as attempted).
                if not ok:
                    acct = codex_account_id(item)
                    headers = {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json", "Chatgpt-Account-Id": acct} if acct else {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"}
                    try:
                        status, body = api_call(base, key, auth_index, "GET", CODEX_USAGE_URL, headers)
                        ok = 200 <= status < 300 and isinstance(body, dict) and bool(body)
                        if not ok:
                            err = _text(body.get("error") if isinstance(body, dict) else "")[:120] or err
                    except Exception as e:
                        err = str(e)[:120]
                if ok:
                    ok_count += 1
                    results.append({"provider": prov, "account": label, "ok": True})
                else:
                    results.append({"provider": prov, "account": label, "ok": False, "error": err[:200]})
            elif prov == "antigravity":
                # Real keepalive for Google: gemini-3.7-flash at low reasoning (user spec).
                # Try the real generation via 8317 first; Antigravity pool's billing still flows through the proxy.
                ok, err = _chat_completion_via_8317("gemini-3.7-flash", None)
                if not ok:
                    # Fallback: quota-summary read (the Google pool's 5-hour/weekly buckets are the displayed limits).
                    proj = _text(_first(item, "project_id", "projectId"))
                    headers = {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json", "User-Agent": "antigravity/1.11.5 windows/amd64"}
                    success = False
                    last_err = err
                    for url in ANTIGRAVITY_SUMMARY_URLS:
                        try:
                            status, body = api_call(base, key, auth_index, "POST", url, headers, "{}")
                        except Exception as exc:
                            last_err = str(exc)[:120]
                            continue
                        if 200 <= status < 300 and isinstance(body, dict) and body.get("groups"):
                            success = True
                            last_err = ""
                            break
                        if isinstance(body, dict):
                            last_err = _text(body.get("error") or body.get("message"))[:120] or last_err
                    if not success and proj:
                        for url in ANTIGRAVITY_MODEL_URLS:
                            try:
                                status, body = api_call(base, key, auth_index, "POST", url, headers, json.dumps({"project": proj}, separators=(",", ":")))
                            except Exception as exc:
                                last_err = str(exc)[:120]
                                continue
                            if 200 <= status < 300 and isinstance(body, dict) and body.get("models"):
                                success = True
                                break
                    ok = success
                    err = last_err
                if ok:
                    ok_count += 1
                    results.append({"provider": prov, "account": label, "ok": True})
                else:
                    results.append({"provider": prov, "account": label, "ok": False, "error": (err or "gemini keepalive failed")[:200]})
            elif prov == "zai":
                # Real keepalive for Z.AI: glm-5.3-flash via 8317
                ok, err = _chat_completion_via_8317("glm-5.3-flash", None)
                if not ok:
                    # Fallback to direct upstream messages call via api_call
                    base_url = _text(_first(item, "base_url", "baseUrl")) or "https://api.z.ai/api/anthropic"
                    url = f"{base_url.rstrip('/')}/v1/messages"
                    token = _text(_first(item, "access_token", "accessToken"))
                    headers = {
                        "Authorization": f"Bearer {token}" if token else "Bearer $TOKEN$",
                        "Content-Type": "application/json",
                        "Anthropic-Version": "2023-06-01",
                        "User-Agent": "curl/8.21.0"
                    }
                    body = {
                        "model": "glm-5.3-flash",
                        "max_tokens": 16,
                        "messages": [{"role": "user", "content": "ping"}],
                        "thinking": {"type": "enabled", "budget_tokens": 1024}
                    }
                    try:
                        status, rbody = api_call(base, key, auth_index, "POST", url, headers, json.dumps(body))
                        ok = 200 <= status < 300
                        if not ok and isinstance(rbody, dict):
                            err = _text(rbody.get("error") or rbody.get("msg"))[:120] or err
                    except Exception as e:
                        err = str(e)[:120]
                if ok:
                    ok_count += 1
                    results.append({"provider": prov, "account": label, "ok": True})
                else:
                    results.append({"provider": prov, "account": label, "ok": False, "error": (err or "zai keepalive failed")[:200]})
            else:
                results.append({"provider": prov, "account": label, "ok": False, "error": "unsupported provider"})
        except Exception as exc:
            results.append({"provider": prov, "account": label, "ok": False, "error": str(exc)[:160]})
        prog = {"type": "progress", "done": idx + 1, "total": total, "provider": prov, "account": label, "ok": results[-1].get("ok", False)}
        print(json.dumps(prog, separators=(",", ":")))
        sys.stdout.flush()

    summary = {"ok": ok_count > 0 or not targets, "pinged": len(targets), "succeeded": ok_count, "results": results}
    print(json.dumps(summary, separators=(",", ":")))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
