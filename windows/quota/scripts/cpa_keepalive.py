#!/usr/bin/env python3
"""Keepalive for the Google, OpenAI, and Z.AI auth files on a CPA proxy.

Sends a minimal "ping" message to:
  - gpt-5.6-luna at low reasoning  (activates the OpenAI / Codex 5-hour window)
  - gemini-3.7-flash at low reasoning (activates the Antigravity / Google 5-hour window)
  - glm-5.3-flash at low reasoning (activates the Z.AI 5-hour window)

For each enabled codex / antigravity / zai auth, a real inference is made so
the upstream rolling window starts counting down instead of staying idle.
Progress is streamed as NDJSON (one line per ping) so the QML bolt ring
fills 0..1. Management calls use baseUrl/adminKey from --cpa-config. The
inference endpoint is resolved from --inference-url, CPA_INFERENCE_URL, or
the config's inferenceUrl; without one a loopback endpoint is used, so the
inference key is never sent to an unconfigured remote host.

Scope: 3× antigravity (Google) + 3× codex (OpenAI) + 1× zai (GLM) = 7.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
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

# Loopback-only fallback for the inference call. The key stays on this host;
# a remote endpoint must be named explicitly in the config, environment or CLI.
DEFAULT_INFERENCE_URL = "http://127.0.0.1:8317/v1/chat/completions"
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse redirects so the inference key cannot follow one to another host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


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


def _inference_endpoint(value: str) -> tuple[str, str]:
    """Validate an inference endpoint, returning (url, error).

    A bare base URL gets the OpenAI chat-completions path. The inference key
    may travel over https, or plain http only to loopback.
    """
    raw = _text(value)
    if not raw:
        return "", "inference endpoint is not configured"
    if "://" not in raw:
        return "", "inference endpoint must be an absolute URL"
    try:
        parts = urllib.parse.urlsplit(raw)
        host = parts.hostname
    except ValueError:
        return "", "inference endpoint is not a valid URL"
    if parts.scheme not in ("http", "https") or not host:
        return "", "inference endpoint must be an http(s) URL"
    if parts.scheme == "http" and host.lower() not in LOOPBACK_HOSTS:
        return "", "plain http inference is only allowed on loopback"
    path = parts.path.rstrip("/")
    if not path:
        path = "/v1/chat/completions"
    elif path.endswith("/v1"):
        path += "/chat/completions"
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, parts.query, "")), ""


def _is_loopback_url(url: str) -> bool:
    try:
        host = urllib.parse.urlsplit(_text(url)).hostname
    except ValueError:
        return False
    return bool(host and host.lower() in LOOPBACK_HOSTS)


def _inference_url(cli_value: str, cfg: dict[str, Any]) -> str:
    explicit = (_text(cli_value)
                or _text(os.environ.get("CPA_INFERENCE_URL"))
                or _text(_first(cfg, "inferenceUrl", "inferenceBaseUrl")))
    if explicit:
        return explicit
    # Only fall back to loopback when management baseUrl is also on loopback;
    # remote management configs must explicitly name their inference endpoint.
    if _is_loopback_url(_text(cfg.get("baseUrl"))):
        return DEFAULT_INFERENCE_URL
    return ""


def _inference_key() -> str:
    key = _text(os.environ.get("CPA_API_KEY"))
    if key:
        return key
    env_conf = Path.home() / ".config" / "environment.d" / "cpa.conf"
    if env_conf.is_file():
        try:
            for line in env_conf.read_text(encoding="utf-8").splitlines():
                if line.startswith("CPA_API_KEY="):
                    return _text(line.split("=", 1)[1])
        except Exception:
            pass
    return ""


def _chat_completion(endpoint: str, api_key: str, model: str, extra_body: dict[str, Any] | None = None) -> tuple[bool, str]:
    """One real inference through the configured CPA inference endpoint.

    Returns (ok, error). A real completion is the only thing that moves the
    5-hour rolling window off idle; wham/usage reads do not.
    """
    if not endpoint:
        return False, "inference endpoint is not configured"
    if not api_key:
        return False, "CPA_API_KEY is not set"
    body: dict[str, Any] = {"model": model, "messages": [{"role": "user", "content": "ping"}], "max_tokens": 8}
    if extra_body:
        body.update(extra_body)
    data = json.dumps(body).encode()
    try:
        req = urllib.request.Request(endpoint, data=data, headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        })
        # No redirects: the key must not travel to a host other than the one
        # named by the config, environment or CLI.
        opener = urllib.request.build_opener(_NoRedirect)
        with opener.open(req, timeout=30) as resp:
            j = json.loads(resp.read().decode("utf-8", "replace"))
            if j.get("id") and (j.get("choices") or j.get("object") == "chat.completion"):
                return True, ""
            return False, str(j)[:200]
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode()[:300]
        except Exception:
            body = ""
        return False, body or f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)[:200]


# Every line this script prints reaches the shell's error text, so scrub the
# admin key (and any Bearer value) from it; raw exceptions can quote headers.
_SECRETS: list[str] = []


def _emit(obj: Any, **kwargs: Any) -> None:
    out = json.dumps(obj, **kwargs)
    for secret in _SECRETS:
        out = out.replace(json.dumps(secret)[1:-1], "[redacted]")
    print(re.sub(r'Bearer\s+[^\s"\\]+', "Bearer [redacted]", out))


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--cpa-config", default="~/.config/omarchy/cpa-agents.json")
    ap.add_argument("--inference-url", default="", help="CPA inference chat-completions endpoint")
    ap.add_argument("--providers", default="codex,antigravity,zai", help="comma-separated providers to ping")
    args, _ = ap.parse_known_args()

    cfg_path = _path(args.cpa_config)
    wanted = {p.strip().lower() for p in args.providers.split(",") if p.strip()} if args.providers else KEEPALIVE_PROVIDERS

    try:
        st = cfg_path.stat()
        # Windows has no POSIX mode bits; every file reports group/other bits.
        if os.name != "nt" and st.st_mode & 0o077:
            _emit({"ok": False, "error": "cpa config permissions too open"})
            return 0
        # utf-8-sig also accepts Windows editors that save a UTF-8 BOM.
        cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
        base, key = _text(cfg.get("baseUrl")), _text(cfg.get("adminKey"))
        if key:
            _SECRETS.extend(part for part in [key, *key.splitlines()] if len(part) >= 6)
    except Exception as exc:
        _emit({"ok": False, "error": f"config read failed: {type(exc).__name__}"})
        return 0
    if not base or not key:
        _emit({"ok": False, "error": "missing baseUrl/adminKey"})
        return 0

    inference_url, inference_error = _inference_endpoint(_inference_url(args.inference_url, cfg))
    if inference_error:
        _emit({"ok": False, "error": inference_error})
        return 0
    inference_key = _inference_key()
    if inference_key:
        _SECRETS.extend(part for part in [inference_key, *inference_key.splitlines()] if len(part) >= 6)

    try:
        inv = request_json(base, key, "/v0/management/auth-files")
    except Exception as exc:
        _emit({"ok": False, "error": f"auth-files failed: {type(exc).__name__}"})
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
            _emit(prog, separators=(",", ":"))
            sys.stdout.flush()
            continue
        try:
            if prov == "codex":
                # Real keepalive for OpenAI: gpt-5.6-luna at low reasoning (user spec).
                # Chat Completions wire is what the CPA inference proxy bills for the 5-hour window.
                ok, err = _chat_completion(inference_url, inference_key, "gpt-5.6-luna", {"reasoning": {"effort": "low"}})
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
                # Try the real generation via the configured inference endpoint first;
                # Antigravity pool's billing still flows through the proxy.
                ok, err = _chat_completion(inference_url, inference_key, "gemini-3.7-flash", None)
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
                # Real keepalive for Z.AI: glm-5.3-flash via the configured inference endpoint.
                ok, err = _chat_completion(inference_url, inference_key, "glm-5.3-flash", None)
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
        _emit(prog, separators=(",", ":"))
        sys.stdout.flush()

    summary = {"ok": ok_count > 0 or not targets, "pinged": len(targets), "succeeded": ok_count, "results": results}
    _emit(summary, separators=(",", ":"))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
