import Foundation

/// Codex(ChatGPT 訂閱):讀 ~/.codex/auth.json,呼叫 backend-api/codex/usage。
/// access token 將過期時主動續期,並把新 token(含輪替後的 refresh token)寫回 auth.json。
/// 只在「真的快過期」時才續期(Codex token 約 10 天),避免與 Codex.app 互相輪替打架。
enum CodexProvider {
    static let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let usageURL = "https://chatgpt.com/backend-api/codex/usage"
    /// 手動重置額度明細（次數 + 到期日）；與 /codex/usage 同源帳號。
    static let resetCreditsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

    struct Auth { var root: [String: Any]; var tokens: [String: Any] }

    static func loadAuth() throws -> Auth {
        guard let data = FileManager.default.contents(atPath: authPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              tokens["access_token"] is String else {
            throw ProviderError.noCredentials("~/.codex/auth.json")
        }
        return Auth(root: root, tokens: tokens)
    }

    /// 解 JWT 的 exp(秒)。
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let exp = o["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// 用 refresh token 續期並寫回 auth.json(refresh token 會輪替,故必須寫回)。
    static func refreshAndPersist(_ auth: Auth) async throws -> (String, Auth) {
        guard let rt = auth.tokens["refresh_token"] as? String else { throw ProviderError.tokenExpired }
        let (code, body) = try await Net.postJSON(tokenURL,
            headers: ["User-Agent": "ai-usage-meter/0.1", "Accept": "application/json"],
            body: ["client_id": clientID, "grant_type": "refresh_token",
                   "refresh_token": rt, "scope": "openid profile email"])
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let at = obj["access_token"] as? String else {
            throw ProviderError.http(code)
        }
        var a = auth
        var tokens = a.tokens
        tokens["access_token"] = at
        if let nrt = obj["refresh_token"] as? String { tokens["refresh_token"] = nrt }
        if let idt = obj["id_token"] as? String { tokens["id_token"] = idt }
        a.tokens = tokens
        a.root["tokens"] = tokens
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        a.root["last_refresh"] = f.string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: a.root, options: [])
        try FileBackups.backupBeforeWrite(path: authPath, tag: "codex")
        try data.write(to: URL(fileURLWithPath: authPath), options: .atomic)
        return (at, a)
    }

    private static func apiHeaders(_ token: String, _ accountId: String) -> [String: String] {
        var h: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "ai-usage-meter/0.1",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop",
        ]
        if !accountId.isEmpty {
            h["ChatGPT-Account-Id"] = accountId
            h["ChatGPT-Account-ID"] = accountId
        }
        return h
    }

    static func callUsage(_ token: String, _ accountId: String) async throws -> (Int, Data) {
        try await Net.get(usageURL, headers: apiHeaders(token, accountId))
    }

    static func callResetCredits(_ token: String, _ accountId: String) async throws -> (Int, Data) {
        try await Net.get(resetCreditsURL, headers: apiHeaders(token, accountId))
    }

    static func fetch() async throws -> ProviderUsage {
        var auth = try loadAuth()
        var token = (auth.tokens["access_token"] as? String) ?? ""
        let accountId = (auth.tokens["account_id"] as? String) ?? ""
        let expired = token.isEmpty || (jwtExpiry(token).map { $0 <= Date().addingTimeInterval(300) } ?? true)
        if expired {   // 快過期 → 主動續期(Codex.app 沒幫忙時)
            (token, auth) = try await refreshAndPersist(auth)
        }

        var (code, body) = try await callUsage(token, accountId)
        if code == 401 {   // token 意外失效 → 續期一次重試
            (token, auth) = try await refreshAndPersist(auth)
            (code, body) = try await callUsage(token, accountId)
        }
        if code == 429 { throw ProviderError.rateLimited }
        if code == 401 { throw ProviderError.tokenExpired }
        guard code == 200 else { throw ProviderError.http(code) }

        var usage = try parseUsageResponse(body)

        // 手動重置：獨立端點有到期日；失敗時仍保留 usage 內的 available_count（無日期）
        if let (rc, rbody) = try? await callResetCredits(token, accountId), rc == 200 {
            let info = parseResetCredits(rbody)
            usage.planAccessory = formatResetAccessory(count: info.count, earliest: info.earliest)
        } else if usage.planAccessory == nil {
            // parseUsageResponse 可能已從 usage JSON 填了 count-only accessory
        }

        return usage
    }

    static func parseUsageResponse(_ data: Data) throws -> ProviderUsage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = obj["rate_limit"] as? [String: Any] else {
            throw ProviderError.apiChanged("Codex usage 回應缺少 rate_limit。")
        }

        // 不要硬編碼 primary=5h / secondary=week：OpenAI 會改窗口長度
        // （例如暫時取消 5 小時、只剩週限）。標籤一律由 limit_window_seconds 推導。
        var buckets: [UsageBucket] = []
        var seenKeys = Set<String>()

        func appendWindow(_ value: Any?, role: String, preferredLabel: String? = nil) {
            guard let bucket = parseWindow(value, role: role, preferredLabel: preferredLabel) else { return }
            var b = bucket
            if seenKeys.contains(b.key) {
                b.key = "\(role).\(b.key)"
            }
            seenKeys.insert(b.key)
            buckets.append(b)
        }

        appendWindow(rl["primary_window"], role: "primary")
        appendWindow(rl["secondary_window"], role: "secondary")

        // 未來可能出現的額外窗口（陣列或單一物件）
        if let extras = rl["additional_windows"] as? [[String: Any]]
            ?? obj["additional_rate_limits"] as? [[String: Any]] {
            for (i, w) in extras.enumerated() {
                appendWindow(w, role: "extra.\(i)")
            }
        } else if let extra = obj["additional_rate_limits"] as? [String: Any] {
            appendWindow(extra, role: "extra")
        }

        if rl["code_review_rate_limit"] != nil || obj["code_review_rate_limit"] != nil {
            appendWindow(rl["code_review_rate_limit"] ?? obj["code_review_rate_limit"],
                         role: "code_review",
                         preferredLabel: "Code review")
        }

        guard !buckets.isEmpty else {
            throw ProviderError.apiChanged("Codex usage 回應沒有任何可用的 rate limit 窗口。")
        }

        // usage 內常只有 available_count，無到期明細
        var accessory: String? = nil
        if let block = obj["rate_limit_reset_credits"] as? [String: Any],
           let n = number(block["available_count"]), n > 0 {
            accessory = formatResetAccessory(count: Int(n), earliest: nil)
        }

        return ProviderUsage(
            provider: .codex,
            buckets: buckets,
            plan: displayPlan(obj["plan_type"] as? String),
            planAccessory: accessory,
            error: nil,
            updatedAt: Date()
        )
    }

    /// API plan_type → 顯示名（team 已更名 Business）。
    static func displayPlan(_ planType: String?) -> String? {
        guard let raw = planType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "team", "business": return "Business"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "free": return "Free"
        case "enterprise": return "Enterprise"
        default: return raw
        }
    }

    struct ResetCreditsInfo: Equatable {
        var count: Int
        var earliest: Date?
    }

    static func parseResetCredits(_ data: Data) -> ResetCreditsInfo {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ResetCreditsInfo(count: 0, earliest: nil)
        }
        let count = Int(number(obj["available_count"]) ?? 0)
        var earliest: Date?
        if let credits = obj["credits"] as? [[String: Any]] {
            for c in credits {
                let status = (c["status"] as? String)?.lowercased() ?? ""
                // available / active 都算可用
                guard status == "available" || status == "active" else { continue }
                guard let exp = Date.fromISO(c["expires_at"] as? String) else { continue }
                if let cur = earliest {
                    if exp < cur { earliest = exp }
                } else {
                    earliest = exp
                }
            }
        }
        return ResetCreditsInfo(count: count, earliest: earliest)
    }

    /// 方案旁文案：「重置 ×2 · 7/26」；無數則 nil。
    static func formatResetAccessory(count: Int, earliest: Date?, lang: AppLanguage = .system) -> String? {
        guard count > 0 else { return nil }
        if let earliest {
            let f = DateFormatter()
            f.dateFormat = "M/d"
            let day = f.string(from: earliest)
            return String(format: Loc.tr("codex.reset.badge", lang), count, day)
        }
        return String(format: Loc.tr("codex.reset.count", lang), count)
    }

    /// 解析單一窗口。`value` 可為 null（略過）。
    private static func parseWindow(_ value: Any?, role: String, preferredLabel: String? = nil) -> UsageBucket? {
        guard let w = value as? [String: Any],
              let percent = number(w["used_percent"]) else { return nil }

        let windowSeconds = number(w["limit_window_seconds"])
        let identity = windowIdentity(seconds: windowSeconds, role: role)

        let reset: Date?
        if let t = number(w["reset_at"]) {
            reset = Date(timeIntervalSince1970: t)
        } else if let after = number(w["reset_after_seconds"]) {
            reset = Date().addingTimeInterval(after)
        } else {
            reset = nil
        }

        return UsageBucket(
            key: identity.key,
            label: preferredLabel ?? identity.label,
            usedPercent: percent,
            resetsAt: reset,
            defaultOn: true
        )
    }

    /// 依窗口長度推導穩定 key + localization label（或字面標籤）。
    /// 容忍秒數誤差（API 可能給 17999 / 604801 等近似值）。
    static func windowIdentity(seconds: Double?, role: String) -> (key: String, label: String) {
        guard let s = seconds, s > 0 else {
            // 舊回應沒有 limit_window_seconds：維持歷史假設 primary≈5h、secondary≈week
            switch role {
            case "primary": return ("5h", "win.5h")
            case "secondary": return ("week", "win.week")
            default: return (role, role)
            }
        }

        let hour: Double = 3600
        let day: Double = 86_400

        if s <= 6 * hour {
            // ~1–6 小時：session / 5h 類
            return ("5h", "win.5h")
        }
        if s <= 1.5 * day {
            return ("day", "win.day")
        }
        if s <= 10 * day {
            return ("week", "win.week")
        }
        if s <= 40 * day {
            return ("month", "win.month")
        }

        // 未知長窗口：顯示實際天數，避免再誤標成「5 小時」
        let days = max(1, Int((s / day).rounded()))
        return ("win-\(days)d", "\(days)d")
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
