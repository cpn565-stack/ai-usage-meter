import Foundation

/// Codex(ChatGPT 訂閱):讀 ~/.codex/auth.json,呼叫 backend-api/codex/usage。
/// access token 將過期時主動續期,並把新 token(含輪替後的 refresh token)寫回 auth.json。
/// 只在「真的快過期」時才續期(Codex token 約 10 天),避免與 Codex.app 互相輪替打架。
enum CodexProvider {
    static let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let usageURL = "https://chatgpt.com/backend-api/codex/usage"

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

    static func callUsage(_ token: String, _ accountId: String) async throws -> (Int, Data) {
        try await Net.get(usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "ChatGPT-Account-Id": accountId,
            "Accept": "application/json",
            "User-Agent": "ai-usage-meter/0.1",
        ])
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
        return try parseUsageResponse(body)
    }

    static func parseUsageResponse(_ data: Data) throws -> ProviderUsage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = obj["rate_limit"] as? [String: Any] else {
            throw ProviderError.apiChanged("Codex usage 回應缺少 rate_limit。")
        }
        func bucket(_ jsonKey: String, _ key: String, _ label: String) -> UsageBucket? {
            guard let w = rl[jsonKey] as? [String: Any], let p = w["used_percent"] as? Double else { return nil }
            let reset = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return UsageBucket(key: key, label: label, usedPercent: p, resetsAt: reset)
        }
        let buckets = [bucket("primary_window", "5h", "win.5h"),
                       bucket("secondary_window", "week", "win.week")].compactMap { $0 }
        guard !buckets.isEmpty else {
            throw ProviderError.apiChanged("Codex usage 回應缺少 primary_window / secondary_window。")
        }
        return ProviderUsage(provider: .codex, buckets: buckets, plan: obj["plan_type"] as? String, error: nil, updatedAt: Date())
    }
}
