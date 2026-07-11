#!/usr/bin/env python3
"""Probe live Grok billing API and check productUsage mapping compatibility."""
import json
import ssl
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

PRODUCT_MAP = {
    "GrokChat": "chat",
    "GrokBuild": "build",
    "GrokImagine": "imagine",
    "GrokPlugins": "plugins",
    "Other": "other",
    "GrokOther": "other",
}


def main() -> int:
    auth_path = Path.home() / ".grok" / "auth.json"
    if not auth_path.exists():
        print("MISS ~/.grok/auth.json")
        return 1

    auth = json.loads(auth_path.read_text())
    scope_key = next(iter(auth.keys()))
    entry = auth[scope_key]
    token = entry["key"]
    refresh_tok = entry.get("refresh_token")
    client_id = entry.get("oidc_client_id") or scope_key.split("::")[-1]
    print("email:", entry.get("email"))
    print("expires_at:", entry.get("expires_at"))
    print("client_id:", client_id)

    ctx = ssl.create_default_context()

    def get_billing(tok: str):
        req = urllib.request.Request(
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            method="GET",
        )
        req.add_header("Authorization", "Bearer " + tok)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", "ai-usage-meter/0.2")
        req.add_header("Origin", "https://grok.com")
        req.add_header("Referer", "https://grok.com/")
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
                return resp.status, json.loads(resp.read().decode())
        except Exception as exc:  # noqa: BLE001
            code = getattr(exc, "code", None)
            body = ""
            if hasattr(exc, "read"):
                try:
                    body = exc.read().decode()[:500]
                except Exception:  # noqa: BLE001
                    pass
            return code, body or str(exc)

    def do_refresh():
        payload = urllib.parse.urlencode(
            {
                "grant_type": "refresh_token",
                "refresh_token": refresh_tok,
                "client_id": client_id,
            }
        ).encode()
        req = urllib.request.Request(
            "https://auth.x.ai/oauth2/token", data=payload, method="POST"
        )
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            return json.loads(resp.read().decode())

    status, body = get_billing(token)
    if status == 401 and refresh_tok:
        print("access token rejected → refreshing…")
        tok_obj = do_refresh()
        token = tok_obj["access_token"]
        entry["key"] = token
        if tok_obj.get("refresh_token"):
            entry["refresh_token"] = tok_obj["refresh_token"]
        expires_in = float(tok_obj.get("expires_in") or 21600)
        entry["expires_at"] = (
            datetime.now(timezone.utc) + timedelta(seconds=expires_in)
        ).isoformat().replace("+00:00", "Z")
        auth[scope_key] = entry
        auth_path.write_text(json.dumps(auth, indent=2) + "\n")
        print("refreshed expires_at:", entry["expires_at"])
        status, body = get_billing(token)

    print("HTTP", status)
    if not isinstance(body, dict):
        print("body:", body)
        return 2

    cfg = body.get("config") or body
    print(
        json.dumps(
            {
                "creditUsagePercent": cfg.get("creditUsagePercent"),
                "currentPeriod": cfg.get("currentPeriod"),
                "productUsage": cfg.get("productUsage"),
                "isUnifiedBillingUser": cfg.get("isUnifiedBillingUser"),
            },
            indent=2,
            ensure_ascii=False,
        )
    )

    print("\n=== productMap check (app logic) ===")
    products = cfg.get("productUsage") or []
    unknown = []
    for item in products:
        name = item.get("product")
        pct = item.get("usagePercent")
        key = PRODUCT_MAP.get(name)
        if key is None:
            if pct is not None:
                unknown.append((name, pct))
                print(f"  UNMAPPED product={name!r} usagePercent={pct}")
            else:
                print(f"  skip product={name!r} (no usagePercent)")
        else:
            print(f"  OK {name!r} → key={key!r} usagePercent={pct}")

    total = cfg.get("creditUsagePercent")
    parts = [p.get("usagePercent") for p in products if p.get("usagePercent") is not None]
    summed = sum(parts) if parts else None
    print(f"\ncreditUsagePercent={total} sum(product %s)={summed}")
    if total is not None and summed is not None:
        print(f"diff total-sum={float(total) - float(summed)}")

    if unknown:
        print("\nFAIL unknown products with usagePercent:", unknown)
        return 3

    print("\nPASS all product ids with usagePercent are mapped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
