#!/usr/bin/env python3
"""驗證 Codex(ChatGPT)OAuth 續期 + 寫回 auth.json(含備份)。"""
import json, base64, time, urllib.request, urllib.error, os, shutil

AUTH = os.path.expanduser("~/.codex/auth.json")
TOKEN_URL = "https://auth.openai.com/oauth/token"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
UA = "ai-usage-meter/0.1"

def post_json(url, body, headers=None):
    h = {"Content-Type": "application/json", "User-Agent": UA}
    if headers: h.update(headers)
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=20)
        return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def main():
    auth = json.load(open(AUTH))
    t = auth["tokens"]
    rt = t["refresh_token"]

    # 1) 續期
    st, body = post_json(TOKEN_URL, {
        "client_id": CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": rt,
        "scope": "openid profile email",
    })
    print("續期端點 ->", st)
    if st != 200:
        print(body[:400]); return
    resp = json.loads(body)
    print("  回應欄位:", list(resp.keys()))
    rotated = resp.get("refresh_token") and resp["refresh_token"] != rt
    print("  refresh_token 輪替:", "是(必須寫回)" if rotated else "否")
    print("  expires_in:", resp.get("expires_in"))

    new_access = resp.get("access_token") or t["access_token"]
    new_refresh = resp.get("refresh_token", rt)
    new_id = resp.get("id_token", t.get("id_token"))

    # 2) 用新 access token 驗證 usage
    h = {"Authorization": "Bearer " + new_access, "ChatGPT-Account-Id": t.get("account_id", ""),
         "Accept": "application/json", "User-Agent": UA}
    try:
        u = urllib.request.urlopen(urllib.request.Request(
            "https://chatgpt.com/backend-api/codex/usage", headers=h), timeout=15)
        ud = json.loads(u.read())
        print("✓ 新 token 打 usage ->", u.status, "primary used%=",
              ud.get("rate_limit", {}).get("primary_window", {}).get("used_percent"))
    except urllib.error.HTTPError as e:
        print("usage 驗證 ->", e.code, "(可能是 chatgpt.com 對 python 的 CF 擋,Swift 端正常)")

    # 3) 備份 + 寫回
    bak = AUTH + ".usagemeter-bak"
    if not os.path.exists(bak): shutil.copy2(AUTH, bak); print("✓ 已備份 ->", bak)
    t["access_token"] = new_access
    t["refresh_token"] = new_refresh
    if new_id: t["id_token"] = new_id
    auth["tokens"] = t
    auth["last_refresh"] = time.strftime("%Y-%m-%dT%H:%M:%S.000000Z", time.gmtime())
    tmp = AUTH + ".tmp"
    json.dump(auth, open(tmp, "w"))
    os.replace(tmp, AUTH)
    print("✓ 已寫回 auth.json")

    # 4) 重讀確認
    a2 = json.load(open(AUTH))
    c = json.loads(base64.urlsafe_b64decode(a2["tokens"]["access_token"].split(".")[1] + "=="))
    print("✓ 重讀:access exp 剩 %.0f 分,refresh len=%d" %
          ((c["exp"] - time.time()) / 60, len(a2["tokens"]["refresh_token"])))

if __name__ == "__main__":
    main()
