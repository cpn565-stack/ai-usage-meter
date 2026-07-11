import Foundation

/// Grok (SuperGrok):讀 Grok Build CLI 的 `~/.grok/auth.json`,呼叫
/// `cli-chat-proxy.grok.com/v1/billing?format=credits` 取得每週額度。
///
/// 回傳結構對應 grok.com「使用情況」面板:
/// - 總週用量 `creditUsagePercent`
/// - 產品拆分 `productUsage`: GrokChat / GrokBuild / GrokImagine / Other / GrokPlugins (Office Plugins)
///
/// access token 將過期時用 refresh token 續期並寫回 auth.json。
enum GrokProvider {
    static let authPath = NSString(string: "~/.grok/auth.json").expandingTildeInPath
    static let tokenURL = "https://auth.x.ai/oauth2/token"
    static let billingURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    static let oidcPrefix = "https://auth.x.ai::"
    static let userAgent = "ai-usage-meter/0.2"

    /// 產品 id → (bucket key, 顯示 label key 或字面值)
    private static let productMap: [String: (key: String, label: String, defaultOn: Bool)] = [
        "GrokChat":    ("chat",    "grok.chat",    true),
        "GrokBuild":   ("build",   "grok.build",   true),
        "GrokImagine": ("imagine", "grok.imagine", true),
        "GrokPlugins": ("plugins", "grok.plugins", false),
        "Other":       ("other",   "grok.other",   false),
        "GrokOther":   ("other",   "grok.other",   false),
    ]

    struct Store {
        var root: [String: Any]
        var scopeKey: String
        var entry: [String: Any]
        var accessToken: String
        var refreshToken: String?
        var clientID: String
        var expiresAt: Date?
        var email: String?
    }

    // MARK: - Auth

    static func loadStore() throws -> Store {
        guard let data = FileManager.default.contents(atPath: authPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.noCredentials("~/.grok/auth.json（請先執行 grok login）")
        }

        // 優先 OIDC 條目,再退回任一含 key 的 entry。
        var candidates: [(String, [String: Any])] = []
        for (k, v) in root {
            guard let entry = v as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty else { continue }
            candidates.append((k, entry))
        }
        guard !candidates.isEmpty else {
            throw ProviderError.noCredentials("~/.grok/auth.json 無有效 token")
        }
        let picked = candidates.first(where: { $0.0.hasPrefix(oidcPrefix) }) ?? candidates[0]
        let entry = picked.1
        let token = entry["key"] as! String
        let clientID = (entry["oidc_client_id"] as? String)
            ?? picked.0.replacingOccurrences(of: oidcPrefix, with: "")
        return Store(
            root: root,
            scopeKey: picked.0,
            entry: entry,
            accessToken: token,
            refreshToken: entry["refresh_token"] as? String,
            clientID: clientID,
            expiresAt: Date.fromISO(entry["expires_at"] as? String) ?? jwtExpiry(token),
            email: entry["email"] as? String
        )
    }

    /// 解 JWT exp(秒）。
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let exp = o["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = o["exp"] as? Int { return Date(timeIntervalSince1970: Double(exp)) }
        return nil
    }

    /// 用 refresh token 續期並寫回 auth.json。
    static func refreshAndPersist(_ store: Store) async throws -> Store {
        guard let rt = store.refreshToken, !rt.isEmpty else { throw ProviderError.tokenExpired }
        let (code, body) = try await Net.postForm(tokenURL, form: [
            "grant_type": "refresh_token",
            "refresh_token": rt,
            "client_id": store.clientID,
        ])
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let at = obj["access_token"] as? String, !at.isEmpty else {
            if code == 400 || code == 401 { throw ProviderError.tokenExpired }
            throw ProviderError.http(code)
        }

        var s = store
        var entry = s.entry
        entry["key"] = at
        if let nrt = obj["refresh_token"] as? String, !nrt.isEmpty {
            entry["refresh_token"] = nrt
            s.refreshToken = nrt
        }
        let expiresIn = (obj["expires_in"] as? Double)
            ?? (obj["expires_in"] as? Int).map(Double.init)
            ?? 21600
        let exp = Date().addingTimeInterval(expiresIn)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entry["expires_at"] = f.string(from: exp)
        s.entry = entry
        s.accessToken = at
        s.expiresAt = exp
        s.root[s.scopeKey] = entry

        let data = try JSONSerialization.data(withJSONObject: s.root, options: [.prettyPrinted, .sortedKeys])
        try FileBackups.backupBeforeWrite(path: authPath, tag: "grok")
        try data.write(to: URL(fileURLWithPath: authPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: authPath)
        return s
    }

    // MARK: - Fetch

    static func callBilling(_ token: String) async throws -> (Int, Data) {
        try await Net.get(billingURL, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": userAgent,
            "Origin": "https://grok.com",
            "Referer": "https://grok.com/",
        ])
    }

    static func fetch() async throws -> ProviderUsage {
        var store = try loadStore()
        let expired = store.accessToken.isEmpty
            || (store.expiresAt.map { $0 <= Date().addingTimeInterval(120) } ?? true)
        if expired {
            store = try await refreshAndPersist(store)
        }

        var (code, data) = try await callBilling(store.accessToken)
        if code == 401 {
            store = try await refreshAndPersist(store)
            (code, data) = try await callBilling(store.accessToken)
        }
        if code == 429 { throw ProviderError.rateLimited }
        if code == 401 { throw ProviderError.tokenExpired }
        guard code == 200 else { throw ProviderError.http(code) }
        return try parseBillingResponse(data)
    }

    // MARK: - Parse

    /// 解析 `?format=credits` 回傳(週額度 + 產品拆分)。
    static func parseBillingResponse(_ data: Data) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.apiChanged("Grok billing 回應不是 JSON。")
        }
        let config = (root["config"] as? [String: Any]) ?? root

        let period = config["currentPeriod"] as? [String: Any]
        let resetsAt = Date.fromISO(period?["end"] as? String)
            ?? Date.fromISO(config["billingPeriodEnd"] as? String)

        var buckets: [UsageBucket] = []

        // 總週用量(對應 UI「23% 已使用」)
        if let total = number(config["creditUsagePercent"]) {
            buckets.append(UsageBucket(
                key: "week",
                label: "win.week",
                usedPercent: clampPercent(total),
                resetsAt: resetsAt,
                defaultOn: true
            ))
        }

        // 產品拆分:對話 / Build / Imagine / Other 等
        if let products = config["productUsage"] as? [[String: Any]] {
            for item in products {
                guard let product = item["product"] as? String else { continue }
                guard let pct = number(item["usagePercent"]) else { continue }
                let meta = productMap[product]
                    ?? (stableKey(product), product, false)
                buckets.append(UsageBucket(
                    key: meta.key,
                    label: meta.label,
                    usedPercent: clampPercent(pct),
                    resetsAt: resetsAt,
                    defaultOn: meta.defaultOn
                ))
            }
        }

        // 若 format=credits 沒給百分比,退回金額式 monthlyLimit/used。
        if buckets.isEmpty {
            let used = money(config["used"]) ?? money((config["usage"] as? [String: Any])?["totalUsed"])
            let limit = money(config["monthlyLimit"])
            if let used, let limit, limit > 0 {
                buckets.append(UsageBucket(
                    key: "week",
                    label: "win.week",
                    usedPercent: clampPercent(used / limit * 100),
                    resetsAt: resetsAt,
                    defaultOn: true
                ))
            }
        }

        guard !buckets.isEmpty else {
            throw ProviderError.apiChanged("Grok billing 回應缺少 creditUsagePercent / productUsage。")
        }

        return ProviderUsage(
            provider: .grok,
            buckets: buckets,
            plan: planLabel(from: config),
            error: nil,
            updatedAt: Date()
        )
    }

    private static func planLabel(from config: [String: Any]) -> String {
        if let period = config["currentPeriod"] as? [String: Any],
           let type = period["type"] as? String,
           type.contains("WEEKLY") {
            return "SuperGrok"
        }
        if config["isUnifiedBillingUser"] as? Bool == true {
            return "SuperGrok"
        }
        return "Grok"
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let n = Double(s) { return n }
        // protobuf money-style { "val": 12.0 }
        if let obj = value as? [String: Any] {
            return number(obj["val"])
        }
        return nil
    }

    private static func money(_ value: Any?) -> Double? { number(value) }

    private static func clampPercent(_ p: Double) -> Double {
        max(0, min(100, p))
    }

    private static func stableKey(_ value: String) -> String {
        var out = ""
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(Character(scalar))
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "product" : trimmed
    }
}
