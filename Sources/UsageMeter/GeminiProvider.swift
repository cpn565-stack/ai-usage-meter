import Foundation

/// Gemini / Antigravity:讀 Antigravity 在 Keychain 的 Google OAuth token(go-keyring 格式)。
/// 若裝了 aisw，改掃 `~/.aisw/profiles/antigravity/<name>/keyring-secret.json`（同一格式），
/// 每個 profile 一列；新增 profile 下一輪掃描就會出現。續期只寫 UsageMeter 自己的快取，
/// 不寫回 aisw 檔案、也不寫回共用 Keychain（那格是 agy 當下帳號）。
/// 沒有 aisw profile 時維持舊行為：只讀 Keychain `gemini` / `antigravity`。
/// 優先 `v1internal:retrieveUserQuotaSummary`（官方 Model Quota：Gemini Models、Gemini 4 Argon、
/// Claude and GPT models）；失敗再退回 `fetchAvailableModels` 依 modelProvider 歸池推斷。
/// Keychain 只在首次(或刷新失敗)時讀取,之後 token 在記憶體快取、靠 refresh token 換新,避免每次更新都跳權限詢問。
enum GeminiProvider {
    // Antigravity 的公開 OAuth client(由社群逆向 opencode-antigravity-auth 取得)。
    // 實際值放在不進版控的 Secrets.swift(見 Secrets.example.swift)。
    static let clientID = Secrets.geminiClientID
    static let clientSecret = Secrets.geminiClientSecret
    // Antigravity 官方 UI 與 agy CLI 走 daily channel；stable host 的 Gemini 池會與官方不符
    //（3p 池兩邊一致，只有 Gemini 池不同），故跟官方用同一個 host。
    static let base = "https://daily-cloudcode-pa.googleapis.com"
    // 2026-10-17 起，daily 的 retrieveUserQuotaSummary 依 User-Agent 的 subclient 過濾群組。
    // 舊的 `antigravity/windows/amd64` 只回 Claude/GPT；`cli`（或 `hub`）才回 Gemini Models
    // 與 Gemini 4 Argon。路徑裡要有 cli/hub，版本號本身不是門檻。
    static let userAgent = "antigravity/cli/1.4.0 (aidev_client; os_type=darwin; arch=arm64)"
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    /// 舊版曾把 token 放 Keychain（每次 refresh 易彈密碼）；改存 Application Support 檔案。
    static let cacheKeychainService = "com.mike.usagemeter.gemini"
    static let cacheKeychainAccount = "antigravity"
    private static let credsFileName = "gemini-creds.json"

    struct Creds { var accessToken: String; var refreshToken: String?; var expiry: Date? }
    private struct CachedCreds: Codable { var accessToken: String; var refreshToken: String?; var expiry: String? }

    private static var cachedCreds: Creds?     // 單帳號 Keychain 路徑的記憶體快取
    private static let memLock = NSLock()
    /// aisw 各帳號的 access token 快取。鍵是 accountKey。不寫回 aisw / Keychain。
    private static var accountCreds: [String: Creds] = [:]
    private static var projectIDs: [String: String] = [:]
    private static let liveProjectKey = "__live__"

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

    private struct AntigravityPayload {
        var creds: Creds
        var email: String?
    }

    private static func decodeAntigravityCreds(_ data: Data) throws -> Creds {
        try decodeAntigravityPayload(data).creds
    }

    private static func decodeAntigravityPayload(_ data: Data) throws -> AntigravityPayload {
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
        let email = (obj["id_token_email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AntigravityPayload(
            creds: Creds(accessToken: access,
                         refreshToken: tok["refresh_token"] as? String,
                         expiry: Date.fromISO(tok["expiry"] as? String)),
            email: (email?.isEmpty == false) ? email : nil
        )
    }

    // MARK: - aisw multi-account

    /// 掃 aisw 的 Antigravity profiles。純讀檔，不碰 Keychain。
    /// 同一 email 只留一筆：作用中的 profile 優先，否則留較新的那份。
    static func discover(homeDirectory: String = NSHomeDirectory(),
                         fileManager: FileManager = .default) -> GeminiDiscovery {
        let root = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let profilesRoot = root
            .appendingPathComponent(".aisw", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
        let activeName = activeProfileName(home: root, fileManager: fileManager)
        var groups: [String: [GeminiAccount]] = [:]

        let items = (try? fileManager.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in items {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let account = readAccount(profileDir: url, activeName: activeName, fileManager: fileManager) else {
                continue
            }
            groups[account.accountKey, default: []].append(account)
        }

        var accounts: [GeminiAccount] = []
        var skipped: [GeminiSkippedProfile] = []
        for (_, group) in groups {
            let canonical = pickCanonical(group)
            accounts.append(canonical)
            for extra in group where extra.profileName != canonical.profileName {
                skipped.append(GeminiSkippedProfile(profileName: extra.profileName, duplicateOf: canonical.profileName))
            }
        }
        accounts.sort { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.profileName.localizedStandardCompare(b.profileName) == .orderedAscending
        }
        skipped.sort { $0.profileName.localizedStandardCompare($1.profileName) == .orderedAscending }
        return GeminiDiscovery(accounts: accounts, skipped: skipped)
    }

    static func discoverAccounts(homeDirectory: String = NSHomeDirectory(),
                                 fileManager: FileManager = .default) -> [GeminiAccount] {
        discover(homeDirectory: homeDirectory, fileManager: fileManager).accounts
    }

    static func placeholder(_ account: GeminiAccount) -> ProviderUsage {
        ProviderUsage(
            provider: .gemini,
            accountKey: account.accountKey,
            accountLabel: account.profileName,
            accountEmail: account.email,
            buckets: [],
            plan: "Antigravity",
            planAccessory: nil,
            error: nil,
            updatedAt: nil
        )
    }

    static func failed(account: GeminiAccount, message: String) -> ProviderUsage {
        var usage = placeholder(account)
        usage.error = message
        usage.updatedAt = Date()
        return usage
    }

    /// 診斷用：只回 email / 是否有 refresh / access 到期，不回 token。
    static func credentialSummary(_ account: GeminiAccount, fileManager: FileManager = .default) -> (email: String?, hasRefresh: Bool, expiry: Date?)? {
        guard let data = fileManager.contents(atPath: account.secretPath),
              let payload = try? decodeAntigravityPayload(data) else { return nil }
        let hasRefresh = payload.creds.refreshToken?.isEmpty == false
        return (payload.email ?? account.email, hasRefresh, payload.creds.expiry)
    }

    private static func activeProfileName(home: URL, fileManager: FileManager) -> String? {
        let path = home.appendingPathComponent(".aisw").appendingPathComponent("config.json").path
        guard let data = fileManager.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = obj["active"] as? [String: Any],
              let name = active["antigravity"] as? String,
              !name.isEmpty else { return nil }
        return name
    }

    private static func readAccount(profileDir: URL, activeName: String?, fileManager: FileManager) -> GeminiAccount? {
        let secret = profileDir.appendingPathComponent("keyring-secret.json")
        guard let data = fileManager.contents(atPath: secret.path),
              let payload = try? decodeAntigravityPayload(data) else { return nil }
        let hasRefresh = payload.creds.refreshToken?.isEmpty == false
        guard hasRefresh || !payload.creds.accessToken.isEmpty else { return nil }
        let name = profileDir.lastPathComponent
        let email = payload.email
        let key = email?.lowercased() ?? name
        guard !key.isEmpty else { return nil }
        let modified = (try? fileManager.attributesOfItem(atPath: secret.path)[.modificationDate] as? Date) ?? .distantPast
        return GeminiAccount(
            accountKey: key,
            email: email,
            profileName: name,
            secretPath: secret.path,
            isActive: name == activeName,
            secretModified: modified
        )
    }

    private static func pickCanonical(_ group: [GeminiAccount]) -> GeminiAccount {
        if let active = group.first(where: \.isActive) { return active }
        return group.max(by: { $0.secretModified < $1.secretModified }) ?? group[0]
    }

    private static func accountCacheFile(_ accountKey: String) -> String {
        let slug = String(accountKey.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }.prefix(64))
        return "gemini-acct-\(slug).json"
    }

    private static func memoryCreds(_ key: String) -> Creds? {
        memLock.lock(); defer { memLock.unlock() }
        return accountCreds[key]
    }

    private static func storeMemory(_ key: String, _ creds: Creds) {
        memLock.lock(); defer { memLock.unlock() }
        accountCreds[key] = creds
    }

    private static func clearMemory(_ key: String) {
        memLock.lock(); defer { memLock.unlock() }
        accountCreds[key] = nil
        projectIDs[key] = nil
    }

    private static func projectID(for key: String) -> String {
        memLock.lock(); defer { memLock.unlock() }
        return projectIDs[key] ?? ""
    }

    private static func setProjectID(_ id: String, for key: String) {
        guard !id.isEmpty else { return }
        memLock.lock(); defer { memLock.unlock() }
        projectIDs[key] = id
    }

    private static func readAccountCache(_ accountKey: String) -> Creds? {
        guard let data = AppSupportCache.readData(accountCacheFile(accountKey)) else { return nil }
        return decodeCachedCreds(data)
    }

    private static func saveAccountCache(_ creds: Creds, _ accountKey: String) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cached = CachedCreds(accessToken: creds.accessToken,
                                 refreshToken: creds.refreshToken,
                                 expiry: creds.expiry.map { f.string(from: $0) })
        guard let data = try? JSONEncoder().encode(cached) else { return }
        AppSupportCache.writeData(data, name: accountCacheFile(accountKey))
    }

    private static func loadSnapshot(_ account: GeminiAccount) throws -> Creds {
        guard let data = FileManager.default.contents(atPath: account.secretPath) else {
            throw ProviderError.noCredentials(account.secretPath)
        }
        return try decodeAntigravityCreds(data)
    }

    /// 快取的 access 還有效、且 refresh token 仍跟 aisw 檔案相同，就用快取。
    /// aisw 重寫過該 profile（refresh token 變了）則改信檔案。
    private static func loadAccountCreds(_ account: GeminiAccount) throws -> Creds {
        let snapshot = try loadSnapshot(account)
        if let cached = readAccountCache(account.accountKey),
           cached.refreshToken == snapshot.refreshToken,
           let exp = cached.expiry, exp > Date().addingTimeInterval(60) {
            return cached
        }
        return snapshot
    }

    /// 用 aisw 那份 refresh token 換 access。失敗時若這是作用中帳號，再試共用 Keychain（email 須相符）。
    /// 新 access 只進 UsageMeter 快取。
    static func ensureAccountCreds(_ account: GeminiAccount, forceRefresh: Bool = false) async throws -> Creds {
        if !forceRefresh, let cached = memoryCreds(account.accountKey),
           let exp = cached.expiry, exp > Date().addingTimeInterval(60) {
            return cached
        }
        var creds = try loadAccountCreds(account)
        let needRefresh = forceRefresh || (creds.expiry.map { $0 <= Date().addingTimeInterval(60) } ?? true)
        guard needRefresh else {
            storeMemory(account.accountKey, creds)
            return creds
        }
        guard let rt = creds.refreshToken, !rt.isEmpty else {
            throw ProviderError.noCredentials(account.profileName)
        }
        do {
            let (at, exp) = try await refresh(rt)
            creds.accessToken = at
            creds.expiry = exp
            storeMemory(account.accountKey, creds)
            saveAccountCache(creds, account.accountKey)
            return creds
        } catch ProviderError.http(let code) where code == 400 || code == 401 {
            clearMemory(account.accountKey)
            AppSupportCache.remove(accountCacheFile(account.accountKey))
            let reread = try loadSnapshot(account)
            if let rt2 = reread.refreshToken, !rt2.isEmpty, rt2 != rt {
                let (at, exp) = try await refresh(rt2)
                var updated = reread
                updated.accessToken = at
                updated.expiry = exp
                storeMemory(account.accountKey, updated)
                saveAccountCache(updated, account.accountKey)
                return updated
            }
            if account.isActive, let rescued = try? await rescueFromLiveKeychain(matching: account) {
                return rescued
            }
            throw ProviderError.tokenExpired
        }
    }

    /// agy 可能已把作用中帳號的 token 輪替進共用 Keychain，而 aisw 檔還是加入當下的快照。
    private static func rescueFromLiveKeychain(matching account: GeminiAccount) async throws -> Creds {
        guard let data = Keychain.genericPassword(service: keychainService, account: keychainAccount) else {
            throw ProviderError.noCredentials("Keychain『gemini/antigravity』(需允許存取)")
        }
        let payload = try decodeAntigravityPayload(data)
        if let want = account.email?.lowercased(),
           let got = payload.email?.lowercased(), want != got {
            throw ProviderError.tokenExpired
        }
        var creds = payload.creds
        if let exp = creds.expiry, exp > Date().addingTimeInterval(60) {
            storeMemory(account.accountKey, creds)
            saveAccountCache(creds, account.accountKey)
            return creds
        }
        guard let rt = creds.refreshToken, !rt.isEmpty else { throw ProviderError.tokenExpired }
        let (at, exp) = try await refresh(rt)
        creds.accessToken = at
        creds.expiry = exp
        storeMemory(account.accountKey, creds)
        saveAccountCache(creds, account.accountKey)
        return creds
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
        let found = discoverAccounts()
        if let account = found.first(where: \.isActive) ?? found.first {
            return try await fetch(account: account)
        }
        return try await fetchLive()
    }

    static func fetchAll(accounts: [GeminiAccount]? = nil) async -> [ProviderUsage] {
        let list = accounts ?? discoverAccounts()
        if list.isEmpty {
            do {
                return [try await fetchLive()]
            } catch let error as ProviderError {
                var empty = ProviderUsage.empty(.gemini)
                empty.error = error.errorDescription
                empty.updatedAt = Date()
                return [empty]
            } catch {
                var empty = ProviderUsage.empty(.gemini)
                empty.error = error.localizedDescription
                empty.updatedAt = Date()
                return [empty]
            }
        }
        return await withTaskGroup(of: (Int, ProviderUsage).self) { group in
            for (index, account) in list.enumerated() {
                group.addTask {
                    do {
                        return (index, try await fetch(account: account))
                    } catch let error as ProviderError {
                        return (index, failed(account: account, message: error.errorDescription ?? "\(error)"))
                    } catch {
                        return (index, failed(account: account, message: error.localizedDescription))
                    }
                }
            }
            var gathered: [(Int, ProviderUsage)] = []
            for await item in group { gathered.append(item) }
            return gathered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func fetch(account: GeminiAccount) async throws -> ProviderUsage {
        let usage = try await performFetch(
            load: { force in try await ensureAccountCreds(account, forceRefresh: force) },
            projectKey: account.accountKey
        )
        var tagged = usage
        tagged.accountKey = account.accountKey
        tagged.accountLabel = account.profileName
        tagged.accountEmail = account.email
        return tagged
    }

    private static func fetchLive() async throws -> ProviderUsage {
        try await performFetch(
            load: { force in try await ensureCreds(forceRefresh: force) },
            projectKey: liveProjectKey
        )
    }

    private static func performFetch(load: (_ force: Bool) async throws -> Creds,
                                     projectKey: String) async throws -> ProviderUsage {
        var creds = try await load(false)

        func callSummary() async throws -> (Int, Data) {
            // 空 body 即可；與官方 Model Quota 同源
            try await Net.postJSON("\(base)/v1internal:retrieveUserQuotaSummary",
                                   headers: authHeaders(creds.accessToken),
                                   body: [:])
        }

        func callModels() async throws -> (Int, Data) {
            var pid = projectID(for: projectKey)
            if pid.isEmpty { pid = (try? await loadProjectID(creds.accessToken)) ?? "" }
            setProjectID(pid, for: projectKey)
            return try await Net.postJSON("\(base)/v1internal:fetchAvailableModels",
                                          headers: authHeaders(creds.accessToken),
                                          body: pid.isEmpty ? [:] : ["project": pid])
        }

        // 1) 優先完整四窗 summary
        var (code, body) = try await callSummary()
        if code == 401 {
            creds = try await load(true)
            (code, body) = try await callSummary()
        }
        if code == 429 { throw ProviderError.rateLimited }
        if code == 200, let usage = try? parseQuotaSummaryResponse(body), !usage.buckets.isEmpty {
            return usage
        }

        // 2) 退回 models（通常只有 5h 池，無週）
        (code, body) = try await callModels()
        if code == 401 {
            creds = try await load(true)
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

    /// 官方 UI 順序：每組先 Weekly 再 Five Hour；Gemini、Argon、Claude/GPT。
    private static func makeUsage(from samples: [String: (used: Double, reset: Date?)]) -> ProviderUsage {
        let preferredOrder = [
            "gemini.week", "gemini.5h",
            "argon.week", "argon.5h",
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
    /// Argon 的顯示名是「Gemini 4 Argon」，必須先於一般 Gemini 判斷，否則週額度會被 max 併進 Gemini 池。
    private static func familyFromGroup(_ group: [String: Any]) -> QuotaFamily? {
        let name = ((group["displayName"] as? String) ?? "").lowercased()
        if name.contains("argon") { return .argon }
        if name.contains("claude") || name.contains("gpt") || name.contains("3p") {
            return .partner
        }
        if name.contains("gemini") {
            return .gemini
        }
        // 看第一個 bucketId
        if let buckets = group["buckets"] as? [[String: Any]],
           let id = (buckets.first?["bucketId"] as? String)?.lowercased() {
            if id.contains("argon") { return .argon }
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

    /// 額度家族：Gemini Models、Gemini 4 Argon（獨立週額度）、Claude and GPT models（官方 3p / partner 池）。
    enum QuotaFamily: String {
        case gemini
        case argon
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

        if lower.contains("argon") || display.contains("argon") { return .argon }

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
        case "argon.5h":     labelKey = "gemini.bucket.argon.5h"
        case "argon.week":   labelKey = "gemini.bucket.argon.week"
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
