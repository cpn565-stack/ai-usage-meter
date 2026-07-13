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

    // safeStorage 金鑰不會輪替：記憶體 → Application Support 檔案 → Keychain（僅首次 / 失效時）。
    // 避免每次 refresh 或重裝後的 ad-hoc 簽章變更就彈 Keychain 密碼框。
    private static var cachedKey: Data?
    private static let keyFileName = "claude-safe-storage.key"

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
        if let disk = AppSupportCache.readData(keyFileName), !disk.isEmpty {
            cachedKey = disk
            return disk
        }
        guard let k = Keychain.genericPassword(service: keychainService, account: keychainAccount) else {
            throw ProviderError.noCredentials("Keychain『\(keychainService)』(需允許存取)")
        }
        cachedKey = k
        AppSupportCache.writeData(k, name: keyFileName)
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
                // 金鑰可能失效 → 清記憶體與檔案快取，下次才再問 Keychain
                cachedKey = nil
                AppSupportCache.remove(keyFileName)
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
        try FileBackups.backupBeforeWrite(path: configPath, tag: "claude")
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
        return try parseUsageResponse(data, tokenCache: store.tokenCache)
    }

    static func parseUsageResponse(_ data: Data, tokenCache: [String: Any]) throws -> ProviderUsage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.apiChanged("Claude /api/oauth/usage 回應不是 JSON。")
        }
        var buckets = parseLimitBuckets(obj)

        let legacyBuckets = parseLegacyBuckets(obj)
        if buckets.isEmpty {
            buckets = legacyBuckets
        } else {
            var seenKeys = Set(buckets.map(\.key))
            var seenLabels = Set(buckets.map { $0.label.lowercased() })
            for bucket in legacyBuckets where !seenKeys.contains(bucket.key) && !seenLabels.contains(bucket.label.lowercased()) {
                buckets.append(bucket)
                seenKeys.insert(bucket.key)
                seenLabels.insert(bucket.label.lowercased())
            }
        }

        guard !buckets.isEmpty else {
            throw ProviderError.apiChanged("Claude usage 回應缺少已知 quota 欄位。")
        }
        return ProviderUsage(provider: .claude, buckets: buckets, plan: parsePlan(tokenCache: tokenCache), error: nil, updatedAt: Date())
    }

    private static func parseLegacyBuckets(_ obj: [String: Any]) -> [UsageBucket] {
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
        return buckets
    }

    private static func parseLimitBuckets(_ obj: [String: Any]) -> [UsageBucket] {
        guard let limits = obj["limits"] as? [[String: Any]] else { return [] }
        return limits.compactMap(limitBucket)
    }

    private static func limitBucket(_ limit: [String: Any]) -> UsageBucket? {
        guard let percent = number(limit["percent"]) else { return nil }
        let kind = limit["kind"] as? String ?? limit["group"] as? String ?? "limit"
        let reset = Date.fromISO(limit["resets_at"] as? String)

        switch kind {
        case "session":
            return UsageBucket(key: "5h", label: "win.5h", usedPercent: percent, resetsAt: reset)
        case "weekly_all":
            return UsageBucket(key: "week", label: "win.week", usedPercent: percent, resetsAt: reset)
        case "weekly_scoped":
            let scoped = scopedLimitIdentity(limit["scope"])
            return UsageBucket(key: "weekly.\(scoped.key)", label: scoped.label,
                               usedPercent: percent, resetsAt: reset, defaultOn: true)
        default:
            let label = titleFromIdentifier(kind)
            return UsageBucket(key: stableKeyPart(kind), label: label,
                               usedPercent: percent, resetsAt: reset, defaultOn: false)
        }
    }

    private static func scopedLimitIdentity(_ scopeValue: Any?) -> (key: String, label: String) {
        guard let scope = scopeValue as? [String: Any] else { return ("scoped", "Scoped") }
        for scopeKey in ["model", "surface"] {
            guard let item = scope[scopeKey] as? [String: Any] else { continue }
            let id = (item["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (item["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = [name, id].compactMap { $0 }.first { !$0.isEmpty }
            if let label {
                return (stableKeyPart(id?.isEmpty == false ? id! : label), label)
            }
        }
        return ("scoped", "Scoped")
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func stableKeyPart(_ value: String) -> String {
        var out = ""
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(Character(scalar))
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func titleFromIdentifier(_ value: String) -> String {
        value.split(separator: "_")
            .map { part in part.prefix(1).uppercased() + part.dropFirst() }
            .joined(separator: " ")
    }

    /// 掃描所有 token 組,取最高方案名(claude_code 那組可能是較低的 claude_ai/pro,但帳號其實是 Max)。
    static func parsePlan(tokenCache tc: [String: Any]) -> String? {
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
