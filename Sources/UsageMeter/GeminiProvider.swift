import Foundation

/// Gemini / Antigravity:讀 Antigravity 在 Keychain 的 Google OAuth token(go-keyring 格式)。
/// 優先 `v1internal:retrieveUserQuotaSummary`（官方 Model Quota：Gemini Models / Claude and GPT models
/// 各有 weekly + 5h）；失敗再退回 `fetchAvailableModels` 依 modelProvider 歸兩池推斷。
/// Keychain 只在首次(或刷新失敗)時讀取,之後 token 在記憶體快取、靠 refresh token 換新,避免每次更新都跳權限詢問。
enum GeminiProvider {
    // Antigravity 的公開 OAuth client(由社群逆向 opencode-antigravity-auth 取得)。
    // 實際值放在不進版控的 Secrets.swift(見 Secrets.example.swift)。
    static let clientID = Secrets.geminiClientID
    static let clientSecret = Secrets.geminiClientSecret
    // Antigravity 官方 UI 與 agy CLI 走 daily channel；stable host 的 Gemini 池會與官方不符
    //（3p 池兩邊一致，只有 Gemini 池不同），故跟官方用同一個 host。
    static let base = "https://daily-cloudcode-pa.googleapis.com"
    static let userAgent = "antigravity/windows/amd64"
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    /// 舊版曾把 token 放 Keychain（每次 refresh 易彈密碼）；改存 Application Support 檔案。
    static let cacheKeychainService = "com.mike.usagemeter.gemini"
    static let cacheKeychainAccount = "antigravity"
    private static let credsFileName = "gemini-creds.json"

    struct Creds { var accessToken: String; var refreshToken: String?; var expiry: Date? }
    private struct CachedCreds: Codable { var accessToken: String; var refreshToken: String?; var expiry: String? }

    private static var cachedCreds: Creds?     // 記憶體快取,避免重複讀 keychain
    private static var cachedProjectID: String?

    /// 讀 Antigravity 的 keychain(會觸發權限詢問)。診斷用;一般流程請走 loadCreds()。
    static func loadCredsFromKeychain() throws -> Creds {
        guard let data = Keychain.genericPassword(service: keychainService, account: keychainAccount) else {
            throw ProviderError.noCredentials("Keychain『gemini/antigravity』(需允許存取)")
        }
        return try decodeAntigravityCreds(data)
    }

    private static func loadCreds() throws -> Creds {
        if let creds = loadCredsFromCache() { return creds }
        let creds = try loadCredsFromKeychain()
        saveCredsToCache(creds)
        return creds
    }

    private static func loadCredsFromCache() -> Creds? {
        // 1) 檔案快取（不碰 Keychain）
        if let data = AppSupportCache.readData(credsFileName) {
            if let creds = decodeCachedCreds(data) { return creds }
            AppSupportCache.remove(credsFileName)
        }
        // 2) 遷移舊 Keychain 快取 → 檔案後刪除 keychain 項
        if let data = Keychain.genericPassword(service: cacheKeychainService, account: cacheKeychainAccount) {
            if let creds = decodeCachedCreds(data) {
                saveCredsToCache(creds)
                Keychain.deleteGenericPassword(service: cacheKeychainService, account: cacheKeychainAccount)
                return creds
            }
            Keychain.deleteGenericPassword(service: cacheKeychainService, account: cacheKeychainAccount)
        }
        return nil
    }

    private static func decodeCachedCreds(_ data: Data) -> Creds? {
        guard let cached = try? JSONDecoder().decode(CachedCreds.self, from: data),
              !cached.accessToken.isEmpty else { return nil }
        return Creds(accessToken: cached.accessToken,
                     refreshToken: cached.refreshToken,
                     expiry: Date.fromISO(cached.expiry))
    }

    private static func saveCredsToCache(_ creds: Creds) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cached = CachedCreds(accessToken: creds.accessToken,
                                 refreshToken: creds.refreshToken,
                                 expiry: creds.expiry.map { f.string(from: $0) })
        guard let data = try? JSONEncoder().encode(cached) else { return }
        AppSupportCache.writeData(data, name: credsFileName)
        // 清掉舊 keychain 快取，避免之後再被讀到而彈窗
        Keychain.deleteGenericPassword(service: cacheKeychainService, account: cacheKeychainAccount)
    }

    private static func invalidateCredsCache() {
        cachedCreds = nil
        AppSupportCache.remove(credsFileName)
        Keychain.deleteGenericPassword(service: cacheKeychainService, account: cacheKeychainAccount)
    }

    private static func decodeAntigravityCreds(_ data: Data) throws -> Creds {
        guard var str = String(data: data, encoding: .utf8) else {
            throw ProviderError.parse("Antigravity 憑證不是 UTF-8")
        }
        let prefix = "go-keyring-base64:"
        if str.hasPrefix(prefix) { str.removeFirst(prefix.count) }
        guard let decoded = Data(base64Encoded: str.trimmingCharacters(in: .whitespacesAndNewlines)),
              let obj = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let tok = obj["token"] as? [String: Any],
              let access = tok["access_token"] as? String else {
            throw ProviderError.parse("Antigravity 憑證格式非預期")
        }
        return Creds(accessToken: access,
                     refreshToken: tok["refresh_token"] as? String,
                     expiry: Date.fromISO(tok["expiry"] as? String))
    }

    /// 用 refresh token 換新 access token(走網路,不碰 keychain)。
    static func refresh(_ refreshToken: String) async throws -> (String, Date?) {
        let (code, body) = try await Net.postForm("https://oauth2.googleapis.com/token", form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
        ])
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let at = obj["access_token"] as? String else {
            throw ProviderError.http(code)
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3000
        return (at, Date().addingTimeInterval(expiresIn - 60))
    }

    /// 取得可用 token:優先用記憶體快取;過期才用 refresh token 換新。
    /// Keychain 只在「沒有任何快取(首次)」或「refresh 失敗需重讀 Antigravity」時才讀,
    /// 暫時性錯誤(如剛睡醒網路未就緒)一律不碰 keychain,以免重複跳權限詢問。
    ///
    /// 若 refresh 失敗但 Antigravity keychain 內 access token 仍未過期,直接沿用,
    /// 避免 Secrets 暫錯或 Google 短暫拒絕時整段 Gemini 失敗。
    static func ensureCreds(forceRefresh: Bool = false) async throws -> Creds {
        if cachedCreds == nil { cachedCreds = try loadCreds() }   // 僅首次
        var creds = cachedCreds!
        let needRefresh = forceRefresh || (creds.expiry.map { $0 <= Date().addingTimeInterval(60) } ?? true)
        guard needRefresh, let rt = creds.refreshToken else { return creds }
        do {
            let (at, exp) = try await refresh(rt)
            creds.accessToken = at; creds.expiry = exp
            cachedCreds = creds
            saveCredsToCache(creds)
            return creds
        } catch ProviderError.http(let code) where code == 400 || code == 401 {
            // refresh 失敗 → 丟掉自家快取,重讀 Antigravity 最新 token
            invalidateCredsCache()
            let fresh = try loadCredsFromKeychain()
            // Antigravity 剛登入時 access 可能仍有效,先用它
            if !forceRefresh, let exp = fresh.expiry, exp > Date().addingTimeInterval(60) {
                cachedCreds = fresh
                saveCredsToCache(fresh)
                return fresh
            }
            if let rt2 = fresh.refreshToken {
                do {
                    let (at, exp) = try await refresh(rt2)
                    var updated = fresh
                    updated.accessToken = at
                    updated.expiry = exp
                    cachedCreds = updated
                    saveCredsToCache(updated)
                    return updated
                } catch {
                    // refresh 仍失敗:若 access 尚未過期就硬用,否則丟錯
                    if let exp = fresh.expiry, exp > Date() {
                        cachedCreds = fresh
                        saveCredsToCache(fresh)
                        return fresh
                    }
                    throw error
                }
            }
            return fresh
        }
        // 其他(網路/逾時/5xx)往外丟 → 本輪視為暫時失敗,下輪重試,不碰 keychain
    }

    static func authHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "User-Agent": userAgent]
    }

    static func loadProjectID(_ token: String) async throws -> String {
        let (code, body) = try await Net.postJSON("\(base)/v1internal:loadCodeAssist",
                                                  headers: authHeaders(token),
                                                  body: ["metadata": ["ideType": "ANTIGRAVITY"]])
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ""
        }
        if let p = obj["cloudaicompanionProject"] as? String { return p }
        if let p = obj["cloudaicompanionProject"] as? [String: Any], let id = p["id"] as? String { return id }
        return ""
    }

    static func fetch() async throws -> ProviderUsage {
        var creds = try await ensureCreds()

        func callSummary() async throws -> (Int, Data) {
            // 空 body 即可；與官方 Model Quota 同源
            try await Net.postJSON("\(base)/v1internal:retrieveUserQuotaSummary",
                                   headers: authHeaders(creds.accessToken),
                                   body: [:])
        }

        func callModels() async throws -> (Int, Data) {
            var pid = cachedProjectID ?? ""
            if pid.isEmpty { pid = (try? await loadProjectID(creds.accessToken)) ?? "" }
            if !pid.isEmpty { cachedProjectID = pid }
            return try await Net.postJSON("\(base)/v1internal:fetchAvailableModels",
                                          headers: authHeaders(creds.accessToken),
                                          body: pid.isEmpty ? [:] : ["project": pid])
        }

        // 1) 優先完整四窗 summary
        var (code, body) = try await callSummary()
        if code == 401 {
            creds = try await ensureCreds(forceRefresh: true)
            (code, body) = try await callSummary()
        }
        if code == 429 { throw ProviderError.rateLimited }
        if code == 200, let usage = try? parseQuotaSummaryResponse(body), !usage.buckets.isEmpty {
            return usage
        }

        // 2) 退回 models（通常只有 5h 池，無週）
        (code, body) = try await callModels()
        if code == 401 {
            creds = try await ensureCreds(forceRefresh: true)
            (code, body) = try await callModels()
        }
        if code == 429 { throw ProviderError.rateLimited }
        guard code == 200 else { throw ProviderError.http(code) }
        return try parseModelsResponse(body)
    }

    /// 官方 `retrieveUserQuotaSummary`：groups = Gemini Models / Claude and GPT models，
    /// 各含 weekly + 5h bucket（remainingFraction 為「剩餘」比例）。
    static func parseQuotaSummaryResponse(_ data: Data) throws -> ProviderUsage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = obj["groups"] as? [[String: Any]], !groups.isEmpty else {
            throw ProviderError.apiChanged("Gemini retrieveUserQuotaSummary 缺少 groups。")
        }

        var samples: [String: (used: Double, reset: Date?)] = [:]
        for group in groups {
            guard let family = familyFromGroup(group),
                  let groupBuckets = group["buckets"] as? [[String: Any]] else { continue }
            for raw in groupBuckets {
                guard let windowKey = windowKeyFromBucket(raw) else { continue }
                let remaining = number(raw["remainingFraction"]) ?? 1.0
                let used = max(0, min(100, (1 - remaining) * 100))
                let reset = Date.fromISO(raw["resetTime"] as? String)
                let key = "\(family.rawValue).\(windowKey)"
                if let existing = samples[key] {
                    samples[key] = (max(existing.used, used), earlierDate(existing.reset, reset))
                } else {
                    samples[key] = (used, reset)
                }
            }
        }
        if samples.isEmpty {
            throw ProviderError.apiChanged("Gemini quota summary 沒有可辨識的額度桶。")
        }
        return makeUsage(from: samples)
    }

    /// 舊路徑：`fetchAvailableModels` 依 modelProvider 歸兩池，再用 resetTime 推 5h/週。
    /// 多數帳號此路徑只看得到 5h（週在 summary 才完整）。
    static func parseModelsResponse(_ data: Data) throws -> ProviderUsage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [String: Any] else {
            throw ProviderError.apiChanged("Gemini fetchAvailableModels 回應缺少 models。")
        }
        var samples: [String: (used: Double, reset: Date?)] = [:]

        for (modelId, raw) in models {
            guard let info = raw as? [String: Any],
                  let q = info["quotaInfo"] as? [String: Any],
                  let family = familyForModel(id: modelId, info: info) else { continue }

            let remaining = number(q["remainingFraction"]) ?? 1.0
            let used = max(0, min(100, (1 - remaining) * 100))
            let reset = Date.fromISO(q["resetTime"] as? String)

            // 無 reset 且完全未用 → 通常是 tab/chat 等無限額內部模型，跳過
            if reset == nil, remaining >= 0.999 { continue }

            let window = windowIdentity(resetAt: reset)
            let key = "\(family.rawValue).\(window.key)"

            if let existing = samples[key] {
                samples[key] = (max(existing.used, used), earlierDate(existing.reset, reset))
            } else {
                samples[key] = (used, reset)
            }
        }

        if samples.isEmpty {
            throw ProviderError.apiChanged("Gemini 模型清單沒有可辨識的 Gemini / Claude·GPT 額度。")
        }
        return makeUsage(from: samples)
    }

    /// 官方 UI 順序：每組先 Weekly 再 Five Hour；Gemini 在前、Claude/GPT 在後。
    private static func makeUsage(from samples: [String: (used: Double, reset: Date?)]) -> ProviderUsage {
        let preferredOrder = [
            "gemini.week", "gemini.5h",
            "partner.week", "partner.5h",
        ]
        var buckets: [UsageBucket] = []
        var emitted = Set<String>()
        for key in preferredOrder {
            guard let s = samples[key] else { continue }
            buckets.append(makeBucket(key: key, usedPercent: s.used, resetsAt: s.reset))
            emitted.insert(key)
        }
        for key in samples.keys.sorted() where !emitted.contains(key) {
            let s = samples[key]!
            buckets.append(makeBucket(key: key, usedPercent: s.used, resetsAt: s.reset))
        }
        return ProviderUsage(provider: .gemini, buckets: buckets, plan: "Antigravity",
                             error: nil, updatedAt: Date())
    }

    private static func earlierDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return min(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    /// 從 summary group 的 displayName / bucketId 推家族。
    private static func familyFromGroup(_ group: [String: Any]) -> QuotaFamily? {
        let name = ((group["displayName"] as? String) ?? "").lowercased()
        if name.contains("claude") || name.contains("gpt") || name.contains("3p") {
            return .partner
        }
        if name.contains("gemini") {
            return .gemini
        }
        // 看第一個 bucketId
        if let buckets = group["buckets"] as? [[String: Any]],
           let id = (buckets.first?["bucketId"] as? String)?.lowercased() {
            if id.hasPrefix("3p") || id.contains("claude") || id.contains("gpt") { return .partner }
            if id.hasPrefix("gemini") { return .gemini }
        }
        return nil
    }

    /// summary bucket → window key（5h / week）。
    private static func windowKeyFromBucket(_ raw: [String: Any]) -> String? {
        if let w = (raw["window"] as? String)?.lowercased() {
            if w == "5h" || w.contains("hour") || w.contains("5") { return "5h" }
            if w.contains("week") { return "week" }
        }
        let id = ((raw["bucketId"] as? String) ?? "").lowercased()
        let display = ((raw["displayName"] as? String) ?? "").lowercased()
        if id.contains("5h") || id.contains("five") || display.contains("five hour") || display.contains("5-hour") || display.contains("5 hour") {
            return "5h"
        }
        if id.contains("week") || display.contains("week") {
            return "week"
        }
        // 最後靠 resetTime
        if let reset = Date.fromISO(raw["resetTime"] as? String) {
            return windowIdentity(resetAt: reset).key
        }
        return nil
    }

    // MARK: - Family / window helpers

    /// 額度家族：Gemini Models vs Claude and GPT models（官方 3p / partner 池）。
    enum QuotaFamily: String {
        case gemini
        case partner   // Claude + GPT 共用池（API bucketId 前綴 3p-）
    }

    /// 依 modelProvider / apiProvider / model id 歸類；內部 tab/chat 模型回傳 nil。
    static func familyForModel(id modelId: String, info: [String: Any]) -> QuotaFamily? {
        let lower = modelId.lowercased()
        if lower.hasPrefix("chat_") || lower.hasPrefix("tab_") { return nil }
        if lower.hasPrefix("rev19") { return nil }

        let provider = ((info["modelProvider"] as? String) ?? "").uppercased()
        let api = ((info["apiProvider"] as? String) ?? "").uppercased()
        let display = ((info["displayName"] as? String) ?? "").lowercased()

        let isPartner =
            provider.contains("ANTHROPIC") || provider.contains("OPENAI")
            || api.contains("ANTHROPIC") || api.contains("OPENAI")
            || lower.contains("claude") || lower.contains("opus")
            || lower.hasPrefix("gpt") || lower.contains("gpt-")
            || display.contains("claude") || display.contains("opus")
            || display.contains("gpt")
        if isPartner { return .partner }

        let isGemini =
            provider.contains("GOOGLE")
            || api.contains("GEMINI") || api.contains("GOOGLE")
            || lower.contains("gemini")
            || display.contains("gemini")
        if isGemini { return .gemini }

        return nil
    }

    /// 依距重置時間推窗口（API 不給 limit_window_seconds，只能看 resetTime）。
    /// 5h 窗最多約 5 小時；週窗通常 1–7 天。18h 切開，避免 5h 被誤標成週。
    static func windowIdentity(resetAt: Date?) -> (key: String, label: String) {
        guard let resetAt else {
            // 沒有 resetTime：當 session/5h 類（舊行為）
            return ("5h", "win.5h")
        }
        let secs = resetAt.timeIntervalSinceNow
        // 已過期也當 5h 顯示（formatReset 會標「重置中」）
        if secs <= 18 * 3600 {
            return ("5h", "win.5h")
        }
        if secs <= 10 * 86_400 {
            return ("week", "win.week")
        }
        // 更長 baseline 仍歸週（Antigravity 長窗常見 4–7 天）
        return ("week", "win.week")
    }

    private static func makeBucket(key: String, usedPercent: Double, resetsAt: Date?) -> UsageBucket {
        let labelKey: String
        switch key {
        case "gemini.5h":    labelKey = "gemini.bucket.gemini.5h"
        case "gemini.week":  labelKey = "gemini.bucket.gemini.week"
        case "partner.5h":   labelKey = "gemini.bucket.partner.5h"
        case "partner.week": labelKey = "gemini.bucket.partner.week"
        default:             labelKey = key
        }
        // 預設全開：兩池 × 兩窗都是使用者會在意的
        return UsageBucket(key: key, label: labelKey, usedPercent: usedPercent,
                           resetsAt: resetsAt, defaultOn: true)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
