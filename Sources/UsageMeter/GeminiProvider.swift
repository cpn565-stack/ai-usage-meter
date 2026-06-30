import Foundation

/// Gemini / Antigravity:讀 Antigravity 在 Keychain 的 Google OAuth token(go-keyring 格式),
/// 透過 cloudcode-pa 的 v1internal:fetchAvailableModels 取各模型群組額度。
/// Keychain 只在首次(或刷新失敗)時讀取,之後 token 在記憶體快取、靠 refresh token 換新,避免每次更新都跳權限詢問。
enum GeminiProvider {
    // Antigravity 的公開 OAuth client(由社群逆向 opencode-antigravity-auth 取得)。
    // 實際值放在不進版控的 Secrets.swift(見 Secrets.example.swift)。
    static let clientID = Secrets.geminiClientID
    static let clientSecret = Secrets.geminiClientSecret
    static let base = "https://cloudcode-pa.googleapis.com"
    static let userAgent = "antigravity/windows/amd64"
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"

    struct Creds { var accessToken: String; var refreshToken: String?; var expiry: Date? }

    private static var cachedCreds: Creds?     // 記憶體快取,避免重複讀 keychain
    private static var cachedProjectID: String?

    /// 讀 keychain(會觸發權限詢問)。只在沒快取或刷新失敗時呼叫。
    static func loadCredsFromKeychain() throws -> Creds {
        guard let data = Keychain.genericPassword(service: keychainService, account: keychainAccount),
              var str = String(data: data, encoding: .utf8) else {
            throw ProviderError.noCredentials("Keychain『gemini/antigravity』(需允許存取)")
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
    /// Keychain 只在「沒有任何快取(首次)」或「refresh token 確定失效(invalid_grant)」時才讀,
    /// 暫時性錯誤(如剛睡醒網路未就緒)一律不碰 keychain,以免重複跳權限詢問。
    static func ensureCreds(forceRefresh: Bool = false) async throws -> Creds {
        if cachedCreds == nil { cachedCreds = try loadCredsFromKeychain() }   // 僅首次
        var creds = cachedCreds!
        let needRefresh = forceRefresh || (creds.expiry.map { $0 <= Date().addingTimeInterval(60) } ?? true)
        guard needRefresh, let rt = creds.refreshToken else { return creds }
        do {
            let (at, exp) = try await refresh(rt)
            creds.accessToken = at; creds.expiry = exp
            cachedCreds = creds
            return creds
        } catch ProviderError.http(let code) where code == 400 || code == 401 {
            // refresh token 失效 → 重讀 keychain 取 Antigravity 最新,再試一次
            cachedCreds = try loadCredsFromKeychain()
            creds = cachedCreds!
            if let rt2 = creds.refreshToken {
                let (at, exp) = try await refresh(rt2)
                creds.accessToken = at; creds.expiry = exp; cachedCreds = creds
            }
            return creds
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

        func callModels() async throws -> (Int, Data) {
            var pid = cachedProjectID ?? ""
            if pid.isEmpty { pid = (try? await loadProjectID(creds.accessToken)) ?? "" }
            if !pid.isEmpty { cachedProjectID = pid }
            return try await Net.postJSON("\(base)/v1internal:fetchAvailableModels",
                                          headers: authHeaders(creds.accessToken),
                                          body: pid.isEmpty ? [:] : ["project": pid])
        }

        var (code, body) = try await callModels()
        if code == 401 {   // token 失效:強制刷新(invalid_grant 時才會去讀 keychain)
            creds = try await ensureCreds(forceRefresh: true)
            (code, body) = try await callModels()
        }
        if code == 429 { throw ProviderError.rateLimited }
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let models = obj["models"] as? [String: Any] else {
            throw ProviderError.http(code)
        }

        // 每個「使用者可見模型」(有 displayName + quotaInfo)各一個 bucket;依 displayName 去重。
        var buckets: [UsageBucket] = []
        var seenLabels = Set<String>()
        for (modelId, raw) in models {
            guard let info = raw as? [String: Any],
                  let displayName = info["displayName"] as? String, !displayName.isEmpty,
                  let q = info["quotaInfo"] as? [String: Any] else { continue }
            if seenLabels.contains(displayName) { continue }
            seenLabels.insert(displayName)
            let remaining = (q["remainingFraction"] as? Double) ?? 1.0
            let used = max(0, min(100, (1 - remaining) * 100))
            let reset = Date.fromISO(q["resetTime"] as? String)
            let recommended = (info["recommended"] as? Bool) ?? false
            buckets.append(UsageBucket(key: modelId, label: displayName, usedPercent: used,
                                       resetsAt: reset, defaultOn: recommended))
        }
        if buckets.isEmpty { throw ProviderError.parse("無 Gemini 模型額度資料") }
        // 依顯示名排序,讓清單穩定。
        buckets.sort { $0.label < $1.label }
        return ProviderUsage(provider: .gemini, buckets: buckets, plan: "Antigravity", error: nil, updatedAt: Date())
    }
}
