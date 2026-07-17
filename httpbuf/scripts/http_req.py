# -*- coding: utf-8 -*-
"""Minimal HTTP client (stdlib). Args: method url [header:value ...] -- body on stdin after headers via JSON file.

Usage:
  python -X utf8 http_req.py --meta meta.json
meta.json: { "method", "url", "headers": {k:v}, "body": "..." }
Prints JSON: { ok, status, headers, body, error, ms }
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    meta_path = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--meta" and i + 1 < len(args):
            meta_path = args[i + 1]
            i += 2
        else:
            i += 1
    if not meta_path:
        print(json.dumps({"ok": False, "error": "need --meta"}, ensure_ascii=False))
        return 2
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    method = (meta.get("method") or "GET").upper()
    url = meta.get("url") or ""
    headers = meta.get("headers") or {}
    body = meta.get("body")
    if not url:
        print(json.dumps({"ok": False, "error": "empty url"}, ensure_ascii=False))
        return 2
    data = None
    if body is not None and body != "" and method not in ("GET", "HEAD"):
        if isinstance(body, str):
            data = body.encode("utf-8")
        else:
            data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in headers.items():
        if k and v is not None:
            req.add_header(str(k), str(v))
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=float(meta.get("timeout") or 30)) as resp:
            raw = resp.read()
            try:
                text = raw.decode("utf-8")
            except Exception:
                text = raw.decode("utf-8", errors="replace")
            hdrs = {k: v for k, v in resp.headers.items()}
            ms = int((time.time() - t0) * 1000)
            print(
                json.dumps(
                    {
                        "ok": True,
                        "status": resp.status,
                        "reason": getattr(resp, "reason", ""),
                        "headers": hdrs,
                        "body": text,
                        "ms": ms,
                    },
                    ensure_ascii=False,
                )
            )
            return 0
    except urllib.error.HTTPError as e:
        raw = e.read() if hasattr(e, "read") else b""
        try:
            text = raw.decode("utf-8")
        except Exception:
            text = raw.decode("utf-8", errors="replace")
        ms = int((time.time() - t0) * 1000)
        print(
            json.dumps(
                {
                    "ok": True,
                    "status": e.code,
                    "reason": e.reason,
                    "headers": dict(e.headers.items()) if e.headers else {},
                    "body": text,
                    "ms": ms,
                },
                ensure_ascii=False,
            )
        )
        return 0
    except Exception as e:
        ms = int((time.time() - t0) * 1000)
        print(json.dumps({"ok": False, "error": str(e), "ms": ms}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
