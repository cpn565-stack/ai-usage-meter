#!/usr/bin/env python3
"""Spike: 驗證 Antigravity/Gemini 配額流程。"""
import base64, json, subprocess, urllib.request, urllib.error, time, os

# Antigravity 公開 OAuth client(社群逆向 opencode-antigravity-auth)。
# 從環境變數帶入,避免進版控:
#   export ANTIGRAVITY_CLIENT_ID=...  ANTIGRAVITY_CLIENT_SECRET=...
CLIENT_ID = os.environ.get("ANTIGRAVITY_CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("ANTIGRAVITY_CLIENT_SECRET", "")
BASE = "https://cloudcode-pa.googleapis.com"
UA = "antigravity/windows/amd64"

def post(url, token, body, form=False):
    if form:
        data = "&".join(f"{k}={urllib.request.quote(v)}" for k,v in body.items()).encode()
        headers = {"Content-Type":"application/x-www-form-urlencoded"}
    else:
        data = json.dumps(body).encode()
        headers = {"Content-Type":"application/json","User-Agent":UA}
    if token: headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def creds():
    d = subprocess.run(["security","find-generic-password","-w","-s","gemini","-a","antigravity"],
                       capture_output=True,text=True).stdout.strip()
    o = json.loads(base64.b64decode(d[len("go-keyring-base64:"):]))
    return o["token"]

def refresh(rt):
    st, body = post("https://oauth2.googleapis.com/token", None,
                    {"grant_type":"refresh_token","refresh_token":rt,
                     "client_id":CLIENT_ID,"client_secret":CLIENT_SECRET}, form=True)
    print("refresh ->", st)
    return json.loads(body)["access_token"] if st==200 else None

def main():
    t = creds()
    at = t["access_token"]
    exp = t.get("expiry","")
    print("access expiry:", exp)
    # loadCodeAssist
    st, body = post(f"{BASE}/v1internal:loadCodeAssist", at, {"metadata":{"ideType":"ANTIGRAVITY"}})
    print("loadCodeAssist ->", st)
    if st == 401:
        at = refresh(t["refresh_token"]); assert at
        st, body = post(f"{BASE}/v1internal:loadCodeAssist", at, {"metadata":{"ideType":"ANTIGRAVITY"}})
        print("loadCodeAssist(retry) ->", st)
    proj = ""
    if st == 200:
        p = json.loads(body).get("cloudaicompanionProject")
        proj = p if isinstance(p,str) else (p or {}).get("id","") if isinstance(p,dict) else ""
    print("project:", proj or "(none)")
    # fetchAvailableModels
    st, body = post(f"{BASE}/v1internal:fetchAvailableModels", at, {"project":proj} if proj else {})
    print("fetchAvailableModels ->", st)
    if st != 200:
        print(body[:500]); return
    data = json.loads(body)
    models = data.get("models",{})
    print(f"共 {len(models)} 個 model,有 quotaInfo 的:")
    for name, info in models.items():
        q = (info or {}).get("quotaInfo")
        if not q: continue
        rem = q.get("remainingFraction")
        used = None if rem is None else round((1-rem)*100)
        reset = q.get("resetTime","")
        print(f"  {name}: 已用 {used}% (remainingFraction={rem}) reset={reset}")

if __name__ == "__main__":
    main()
