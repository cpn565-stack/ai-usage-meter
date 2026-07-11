#!/usr/bin/env python3
"""驗證 Claude OAuth 自動續期 + 寫回 config.json 的完整流程(含備份與往返驗證)。"""
import json, base64, hashlib, subprocess, time, urllib.request, urllib.error, os, shutil

CFG = os.path.expanduser("~/Library/Application Support/Claude/config.json")
TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"

def keychain_key():
    pw = subprocess.run(["security","find-generic-password","-w","-s","Claude Safe Storage","-a","Claude Key"],
                        capture_output=True,text=True).stdout.strip()
    return hashlib.pbkdf2_hmac("sha1", pw.encode(), b"saltysalt", 1003, 16)

def decrypt_v10(b64, key):
    raw = base64.b64decode(b64); assert raw[:3]==b"v10"
    p = subprocess.run(["openssl","enc","-aes-128-cbc","-d","-K",key.hex(),"-iv","20"*16],
                       input=raw[3:], capture_output=True)
    return p.stdout

def encrypt_v10(plaintext_bytes, key):
    p = subprocess.run(["openssl","enc","-aes-128-cbc","-K",key.hex(),"-iv","20"*16],
                       input=plaintext_bytes, capture_output=True)
    return base64.b64encode(b"v10"+p.stdout).decode()

def main():
    key = keychain_key()
    cfg = json.load(open(CFG))
    enc = cfg["oauth:tokenCache"]
    plain = decrypt_v10(enc, key)
    tok = json.loads(plain)

    # 找 claude_code 那組,並取出 client_id(key 的第一段)
    cc_key = next(k for k in tok if "claude_code" in k)
    client_id = cc_key.split(":")[0]
    entry = tok[cc_key]
    print("client_id =", client_id)
    exp = entry.get("expiresAt",0)/1000
    print("目前 access token 剩 %.0f 分" % ((exp-time.time())/60))

    # === 1) 加密往返驗證(不改內容)===
    re_enc = encrypt_v10(plain, key)
    assert decrypt_v10(re_enc, key) == plain, "往返失敗!"
    print("✓ 加密往返驗證通過(Claude.app 能讀回我重新加密的內容)")

    # === 2) 測續期端點 ===
    body = json.dumps({"grant_type":"refresh_token",
                       "refresh_token":entry["refreshToken"],
                       "client_id":client_id}).encode()
    req = urllib.request.Request(TOKEN_URL, data=body,
                                 headers={"Content-Type":"application/json",
                                          "Accept":"application/json",
                                          "User-Agent":"claude-cli/2.0.0 (external, cli)"}, method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=20)
        resp = json.loads(r.read())
        print("✓ 續期端點 ->", r.status)
    except urllib.error.HTTPError as e:
        print("✗ 續期端點 ->", e.code, e.read().decode()[:300]); return

    print("  回應欄位:", list(resp.keys()))
    rotated = resp.get("refresh_token") and resp["refresh_token"] != entry["refreshToken"]
    print("  refresh_token 是否輪替:", "是(必須寫回)" if rotated else "否")
    print("  expires_in:", resp.get("expires_in"))

    new_access = resp["access_token"]
    new_refresh = resp.get("refresh_token", entry["refreshToken"])
    new_exp_ms = int((time.time() + resp.get("expires_in", 28800))*1000)

    # === 3) 用新 access token 驗證 usage ===
    h={"Authorization":"Bearer "+new_access,"anthropic-beta":"oauth-2025-04-20","anthropic-version":"2023-06-01"}
    u=urllib.request.urlopen(urllib.request.Request("https://api.anthropic.com/api/oauth/usage",headers=h),timeout=15)
    udata=json.loads(u.read())
    print("✓ 用新 token 打 usage ->", u.status, "five_hour=%s%%" % udata.get("five_hour",{}).get("utilization"))

    # === 4) 備份 + 寫回 ===
    bak = CFG + ".usagemeter-bak"
    if not os.path.exists(bak): shutil.copy2(CFG, bak); print("✓ 已備份 ->", bak)
    entry["token"]=new_access; entry["refreshToken"]=new_refresh; entry["expiresAt"]=new_exp_ms
    tok[cc_key]=entry
    new_plain=json.dumps(tok,separators=(",",":")).encode()
    cfg["oauth:tokenCache"]=encrypt_v10(new_plain, key)
    tmp=CFG+".tmp"
    json.dump(cfg, open(tmp,"w"), ensure_ascii=False)
    os.replace(tmp, CFG)
    print("✓ 已寫回 config.json")

    # === 5) 再讀一次確認 ===
    cfg2=json.load(open(CFG)); tok2=json.loads(decrypt_v10(cfg2["oauth:tokenCache"], key))
    e2=tok2[cc_key]
    print("✓ 重讀驗證:token 已更新 =", e2["token"][:12]+"…剩 %.0f 分" % ((e2["expiresAt"]/1000-time.time())/60))

if __name__ == "__main__":
    main()
