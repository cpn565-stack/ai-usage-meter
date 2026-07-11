#!/usr/bin/env python3
"""Spike: 用本地憑證抓 Claude / Codex 官方用量。只驗證可行性,不寫入任何東西。"""
import json, os, urllib.request, urllib.error, sys

HOME = os.path.expanduser("~")

def http(url, headers, method="GET"):
    req = urllib.request.Request(url, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return None, f"ERR {type(e).__name__}: {e}"

def section(t): print(f"\n{'='*8} {t} {'='*8}")

# ---------- Codex ----------
def codex():
    section("CODEX")
    p = os.path.join(HOME, ".codex", "auth.json")
    auth = json.load(open(p))
    tok = auth["tokens"]["access_token"]
    acct = auth["tokens"].get("account_id", "")
    print("token len:", len(tok), "| account_id:", acct[:8] + "...")
    h = {
        "Authorization": f"Bearer {tok}",
        "ChatGPT-Account-Id": acct,
        "User-Agent": "ai-usage-meter-spike/0.1",
        "Accept": "application/json",
    }
    for path in ["/backend-api/codex/usage", "/backend-api/wham/usage"]:
        st, body = http("https://chatgpt.com" + path, h)
        print(f"\n[{path}] -> {st}")
        print(body[:1200])

# ---------- Claude ----------
def claude_locate():
    section("CLAUDE: 找 token")
    # 1) ~/.claude.json 結構
    p = os.path.join(HOME, ".claude.json")
    if os.path.exists(p):
        o = json.load(open(p))
        toklike = [k for k in o.keys() if any(s in k.lower() for s in ("oauth","token","account","cred","access","refresh"))]
        print("~/.claude.json 頂層 token 相關 keys:", toklike or "(無)")
        for k in toklike:
            v = o[k]
            if isinstance(v, dict):
                print(f"  {k} ->", {kk:(f'<str {len(vv)}>' if isinstance(vv,str) else type(vv).__name__) for kk,vv in v.items()})
            else:
                print(f"  {k} -> {type(v).__name__}" + (f" len={len(v)}" if isinstance(v,str) else ""))
    else:
        print("無 ~/.claude.json")
    # 2) credentials 檔
    for cp in [os.path.join(HOME,".claude",".credentials.json")]:
        print(cp, "存在" if os.path.exists(cp) else "不存在")

def claude():
    section("CLAUDE (解密 oauth:tokenCache)")
    import base64, hashlib, subprocess
    # 1) keychain 金鑰
    pw = subprocess.run(["security","find-generic-password","-w","-s","Claude Safe Storage","-a","Claude Key"],
                        capture_output=True, text=True).stdout.strip()
    if not pw:
        print("拿不到 Claude Safe Storage 金鑰"); return
    # 2) 取出加密 token cache
    cfg = json.load(open("/Users/mike/Library/Application Support/Claude/config.json"))
    enc_b64 = cfg.get("oauth:tokenCache")
    if not enc_b64:
        print("config.json 無 oauth:tokenCache"); return
    raw = base64.b64decode(enc_b64)
    assert raw[:3] == b"v10", f"非 v10 前綴: {raw[:3]}"
    ct = raw[3:]
    # 3) 派生 AES-128 金鑰並用 openssl 解密 (IV = 16 個 0x20)
    key = hashlib.pbkdf2_hmac("sha1", pw.encode(), b"saltysalt", 1003, 16)
    iv = "20"*16
    p = subprocess.run(["openssl","enc","-aes-128-cbc","-d","-K",key.hex(),"-iv",iv],
                       input=ct, capture_output=True)
    pt = p.stdout
    if not pt:
        print("解密失敗:", p.stderr.decode("utf-8","replace")[:200]); return
    try:
        tok = json.loads(pt)
    except Exception:
        print("解密出非 JSON,前 80 bytes:", pt[:80]); return
    # 印結構 (遮罩值)
    def shape(x):
        if isinstance(x,dict): return {k:shape(v) for k,v in x.items()}
        if isinstance(x,str): return f"<str len={len(x)} pfx={x[:7]!r}>"
        return x if isinstance(x,(int,bool,type(None))) else type(x).__name__
    print("解密後 token 結構:", json.dumps(shape(tok),ensure_ascii=False))
    # 找含 claude_code scope 的那組 (退而求其次:有 subscriptionType 的)
    entry = None
    for k,v in tok.items():
        if isinstance(v,dict) and "claude_code" in k:
            entry = v; break
    if not entry:
        for k,v in tok.items():
            if isinstance(v,dict) and v.get("subscriptionType"): entry=v; break
    if not entry:
        print("找不到合適的 token entry"); return
    at = entry["token"]
    import time
    exp = entry.get("expiresAt",0)/1000
    print(f"access token len={len(at)} pfx={at[:10]} | 過期: {exp:.0f} ({'有效,剩 %.0f 分' % ((exp-time.time())/60) if exp>time.time() else '已過期'})")
    print(f"subscriptionType={entry.get('subscriptionType')} rateLimitTier={entry.get('rateLimitTier')}")
    # 4) 呼叫 usage 端點
    for beta in ["oauth-2025-04-20"]:
        h = {"Authorization": f"Bearer {at}", "anthropic-beta": beta,
             "anthropic-version": "2023-06-01", "User-Agent": "ai-usage-meter-spike/0.1",
             "Accept": "application/json"}
        st, body = http("https://api.anthropic.com/api/oauth/usage", h)
        print(f"\n[/api/oauth/usage] -> {st}")
        print(body[:1500])

if __name__ == "__main__":
    codex()
    claude_locate()
    claude()
