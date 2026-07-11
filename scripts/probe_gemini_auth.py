#!/usr/bin/env python3
"""Diagnose Antigravity/Gemini keychain token + refresh with app Secrets."""
import base64
import json
import os
import re
import subprocess
import urllib.parse
import urllib.request
import ssl
from datetime import datetime
from pathlib import Path

ctx = ssl.create_default_context()


def keychain_password(service: str, account: str) -> str | None:
    r = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def load_antigravity_token():
    raw = keychain_password("gemini", "antigravity")
    if not raw:
        raise SystemExit("No Keychain item service=gemini account=antigravity")
    s = raw
    if s.startswith("go-keyring-base64:"):
        s = s[len("go-keyring-base64:") :]
    obj = json.loads(base64.b64decode(s.strip()))
    tok = obj["token"]
    return tok


def post_form(url: str, form: dict):
    data = urllib.parse.urlencode(form).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            return resp.status, json.loads(resp.read().decode())
    except Exception as exc:  # noqa: BLE001
        code = getattr(exc, "code", None)
        body = ""
        if hasattr(exc, "read"):
            try:
                body = exc.read().decode()[:400]
            except Exception:  # noqa: BLE001
                pass
        return code, body or str(exc)


def post_json(url: str, token: str, body: dict):
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "antigravity/windows/amd64")
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            return resp.status, resp.read()[:400]
    except Exception as exc:  # noqa: BLE001
        code = getattr(exc, "code", None)
        body = b""
        if hasattr(exc, "read"):
            try:
                body = exc.read()[:400]
            except Exception:  # noqa: BLE001
                pass
        return code, body or str(exc).encode()


def read_app_secrets():
    p = Path(__file__).resolve().parents[1] / "Sources/UsageMeter/Secrets.swift"
    if not p.exists():
        return None, None
    text = p.read_text()
    cid = re.search(r'geminiClientID\s*=\s*"([^"]+)"', text)
    sec = re.search(r'geminiClientSecret\s*=\s*"([^"]+)"', text)
    return (cid.group(1) if cid else None, sec.group(1) if sec else None)


def main():
    tok = load_antigravity_token()
    access = tok["access_token"]
    refresh = tok["refresh_token"]
    expiry = tok.get("expiry")
    print("Keychain gemini/antigravity OK")
    print("  expiry:", expiry)
    try:
        exp = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
        now = datetime.now(exp.tzinfo)
        mins = (exp - now).total_seconds() / 60
        print(f"  now: {now.isoformat()}")
        print(f"  expired: {now >= exp}  minutes_left: {mins:.1f}")
    except Exception as e:  # noqa: BLE001
        print("  expiry parse error:", e)
    print("  access_len:", len(access), "refresh_len:", len(refresh))

    print("\n=== API with current access token ===")
    st, body = post_json(
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        access,
        {},
    )
    print("  fetchAvailableModels:", st, body[:180] if isinstance(body, (bytes, bytearray)) else body)

    st2, body2 = post_json(
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
        access,
        {"metadata": {"ideType": "ANTIGRAVITY"}},
    )
    print("  loadCodeAssist:", st2, body2[:180] if isinstance(body2, (bytes, bytearray)) else body2)

    cid, secret = read_app_secrets()
    print("\n=== App Secrets.swift ===")
    print("  client_id:", cid)
    print("  client_secret set:", bool(secret and "YOUR_" not in secret and secret))
    is_placeholder = (not cid) or ("YOUR_" in (cid or "")) or ("YOUR_" in (secret or ""))

    print("\n=== OAuth refresh with Secrets.swift client ===")
    st3, body3 = post_form(
        "https://oauth2.googleapis.com/token",
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": cid or "",
            "client_secret": secret or "",
        },
    )
    print("  status:", st3)
    if isinstance(body3, dict):
        print("  keys:", list(body3.keys()))
        if "access_token" in body3:
            print("  REFRESH OK, new token len", len(body3["access_token"]))
        else:
            print("  body:", body3)
    else:
        print("  body:", body3)

    # UsageMeter cache
    cache = keychain_password("com.mike.usagemeter.gemini", "antigravity")
    print("\n=== UsageMeter cache keychain ===")
    if not cache:
        print("  (empty)")
    else:
        try:
            c = json.loads(cache)
            print("  expiry:", c.get("expiry"))
            print("  has_access:", bool(c.get("accessToken")))
            print("  has_refresh:", bool(c.get("refreshToken")))
        except Exception as e:  # noqa: BLE001
            print("  parse fail", e, "len", len(cache))

    print("\n=== Diagnosis ===")
    if is_placeholder:
        print("ROOT CAUSE: Sources/UsageMeter/Secrets.swift still has PLACEHOLDER client id/secret.")
        print("App cannot refresh Google OAuth tokens without the real Antigravity desktop OAuth client.")
        print("When access token expires, Gemini calls fail with HTTP 401.")
    elif st3 != 200:
        print("ROOT CAUSE: refresh failed with real-looking Secrets — client id/secret may be wrong,")
        print("or Antigravity refresh_token was revoked. Re-login in Antigravity app.")
    elif st not in (200,):
        print("Access token rejected by API; refresh path should be checked next fetch.")
    else:
        print("Token + refresh look OK.")

    # Search Antigravity.app for client strings (public desktop client)
    app = "/Applications/Antigravity.app"
    print("\n=== Antigravity.app present:", os.path.isdir(app), "===")
    if os.path.isdir(app):
        hits = 0
        for root, _dirs, files in os.walk(app + "/Contents"):
            for f in files:
                if not f.endswith((".js", ".json", ".html", ".map", ".plist")):
                    continue
                path = os.path.join(root, f)
                try:
                    if os.path.getsize(path) > 8_000_000:
                        continue
                    text = open(path, "r", errors="ignore").read()
                except Exception:  # noqa: BLE001
                    continue
                if "apps.googleusercontent.com" not in text:
                    continue
                for m in re.finditer(
                    r"[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com", text
                ):
                    print("  client_id candidate:", m.group(0), "in", path.split("/Contents/")[-1])
                    hits += 1
                    if hits >= 8:
                        return
                for m in re.finditer(r'client_secret["\s:=]+([A-Za-z0-9\-_]+)', text):
                    print("  client_secret candidate:", m.group(1)[:8] + "…", "in", path.split("/Contents/")[-1])
                    hits += 1
                    if hits >= 12:
                        return


if __name__ == "__main__":
    main()
