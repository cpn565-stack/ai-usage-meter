import Foundation

/// Claude(訂閱):解密 Claude.app 的 oauth tokenCache,呼叫 /api/oauth/usage。
/// token 過期時主動用 refresh token 續期,並把新 token(含輪替後的 refresh token)寫回 config.json,
/// 讓 Claude.app 與本工具保持同步(refresh token 每次續期都會輪替,故必須寫回)。
enum ClaudeProvider {
    static let configPath = NSString(string: "~/Library/Application Support/Claude/config.json").expandingTildeInPath
    static let keychainService = "Claude Safe Storage"
    static let keychainAccount = "Claude Key"
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    // OAuth token 端點 2026-06 從 console.anthropic.com 搬到 platform.claude.com(舊 host 回 404)。
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let userAgent = "claude-cli/2.0.0 (external, cli)"
    // Claude.app 升級後改用 oauth:tokenCacheV2(舊版 oauth:tokenCache 的 token 會停止維護而過期)。優先 V2,退回 V1。
    static let cacheKeysPreferred = ["oauth:tokenCacheV2", "oauth:tokenCache"]

    // safeStorage 金鑰不會輪替,讀一次後快取(之後重讀的是 config.json 檔案,不跳權限詢問)。
    private static var cachedKey: Data?

    struct Store {
        var cfg: [String: Any]
        var tokenCache: [String: Any]
        var ccKey: String
        var entry: [String: Any]
        var decKey: Data
        var cacheKey: String      // 這個 store 是從哪個 config 鍵讀出來的(寫回時用同一個)
    }

    static func safeStorageKey() throws -> Data {
        if let k = cachedKey { return k }
        guard let k = Keychain.genericPassword(service: keychainService, account: keychainAccount) else {
            throw ProviderError.noCredentials("Keychain『\(keychainService)』(需允許存取)")
        }
        cachedKey = k
        return k
    }

    /// 讀 config.json + 解密 tokenCache,取出 claude_code 那組與相關資訊。
    /// 優先讀 oauth:tokenCacheV2(Claude.app 現用),退回舊的 oauth:tokenCache。
    static func loadStore() throws -> Store {
        guard let cfgData = FileManager.default.contents(atPath: configPath),
              let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any] else {
            throw ProviderError.noCredentials("Claude config.json")
        }
        let key = try safeStorageKey()
        var lastErr: Error?
        for cacheKey in cacheKeysPreferred {
            guard let enc = cfg[cacheKey] as? String else { continue }
            let plain: Data
            do {
                plain = try Crypto.decryptElectronV10(base64Value: enc, keychainPassword: key)
            } catch {
                cachedKey = nil   // 金鑰可能失效 → 清快取讓下次重讀
                lastErr = error
                continue
            }
            guard let tc = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
                lastErr = ProviderError.decrypt("\(cacheKey) 解出非 JSON"); continue
            }
            var ccKey: String?
            for (k, v) in tc where k.contains("claude_code") && v is [String: Any] { ccKey = k; break }
            if ccKey == nil {
                for (k, v) in tc { if let d = v as? [String: Any], d["subscriptionType"] is String { ccKey = k; break } }
            }
            guard let ck = ccKey, let entry = tc[ck] as? [String: Any] else {
                lastErr = ProviderError.parse("\(cacheKey) 內找不到 claude_code entry"); continue
            }
            return Store(cfg: cfg, tokenCache: tc, ccKey: ck, entry: entry, decKey: key, cacheKey: cacheKey)
        }
        throw lastErr ?? ProviderError.noCredentials("Claude oauth:tokenCache(V2/V1 皆無)")
    }

    /// 用 refresh token 續期,更新 entry,re-encrypt 後原子寫回 config.json。回傳新 access token 與更新後的 store。
    static func refreshAndPersist(_ store: Store) async throws -> (String, Store) {
        guard let rt = store.entry["refreshToken"] as? String else { throw ProviderError.tokenExpired }
        let clientId = store.ccKey.split(separator: ":").first.map(String.init) ?? ""
        let (code, body) = try await Net.postJSON(tokenURL,
            headers: ["User-Agent": userAgent, "Accept": "application/json"],
            body: ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientId])
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let at = obj["access_token"] as? String else {
            throw ProviderError.http(code)
        }
        var s = store
        var entry = s.entry
        entry["token"] = at
        entry["refreshToken"] = (obj["refresh_token"] as? String) ?? rt   // 輪替後的新 refresh token
        let expiresIn = (obj["expires_in"] as? Double) ?? 28800
        entry["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        s.entry = entry
        s.tokenCache[s.ccKey] = entry

        // re-encrypt tokenCache 並寫回 config.json(原子寫入,保留其他鍵)。
        let plain = try JSONSerialization.data(withJSONObject: s.tokenCache, options: [])
        guard let encB64 = Crypto.encryptElectronV10(plaintext: plain, keychainPassword: s.decKey) else {
            throw ProviderError.decrypt("tokenCache 重新加密失敗")
        }
        s.cfg[s.cacheKey] = encB64
        let cfgData = try JSONSerialization.data(withJSONObject: s.cfg, options: [])
        try cfgData.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        return (at, s)
    }

    static func callUsage(_ token: String) async throws -> (Int, Data) {
        try await Net.get(usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "anthropic-version": "2023-06-01",
            "Accept": "application/json",
            "User-Agent": "ai-usage-meter/0.1",
        ])
    }

    static func fetch() async throws -> ProviderUsage {
        var store = try loadStore()
        var token = store.entry["token"] as? String ?? ""
        let expMs = store.entry["expiresAt"] as? Double ?? 0
        let expired = token.isEmpty || Date(timeIntervalSince1970: expMs / 1000) <= Date().addingTimeInterval(120)
        if expired {   // 過期/將過期 → 主動續期(Claude.app 沒幫忙時)
            (token, store) = try await refreshAndPersist(store)
        }

        var (code, data) = try await callUsage(token)
        if code == 401 {   // token 意外失效 → 續期一次重試
            (token, store) = try await refreshAndPersist(store)
            (code, data) = try await callUsage(token)
        }
        if code == 429 { throw ProviderError.rateLimited }
        if code == 401 { throw ProviderError.tokenExpired }
        guard code == 200 else { throw ProviderError.http(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse("usage 非 JSON")
        }
        // (jsonKey, bucketKey, label, defaultOn)
        let cats: [(String, String, String, Bool)] = [
            ("five_hour",          "5h",     "win.5h",   true),
            ("seven_day",          "week",   "win.week", true),
            ("seven_day_omelette", "design", "Design",   true),   // Claude Design
            ("seven_day_sonnet",   "sonnet", "Sonnet",   false),
            ("seven_day_opus",     "opus",   "Opus",     false),
            ("seven_day_cowork",   "cowork", "Cowork",   false),
        ]
        var buckets: [UsageBucket] = []
        for (jk, key, label, on) in cats {
            guard let w = obj[jk] as? [String: Any], let u = w["utilization"] as? Double else { continue }
            buckets.append(UsageBucket(key: key, label: label, usedPercent: u,
                                       resetsAt: Date.fromISO(w["resets_at"] as? String), defaultOn: on))
        }
        return ProviderUsage(provider: .claude, buckets: buckets, plan: friendlyPlan(store.tokenCache), error: nil, updatedAt: Date())
    }

    /// 掃描所有 token 組,取最高方案名(claude_code 那組可能是較低的 claude_ai/pro,但帳號其實是 Max)。
    private static func friendlyPlan(_ tc: [String: Any]) -> String? {
        var tiers: [String] = [], subs: [String] = []
        for (_, v) in tc {
            guard let d = v as? [String: Any] else { continue }
            if let t = d["rateLimitTier"] as? String { tiers.append(t) }
            if let s = d["subscriptionType"] as? String { subs.append(s) }
        }
        if tiers.contains(where: { $0.contains("max_20x") }) { return "Max 20x" }
        if tiers.contains(where: { $0.contains("max_5x") })  { return "Max 5x" }
        if subs.contains("max") { return "Max" }
        if subs.contains("pro") { return "Pro" }
        return nil
    }
}
