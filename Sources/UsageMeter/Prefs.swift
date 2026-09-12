import Foundation
import Combine

enum PollInterval: String, CaseIterable, Identifiable {
    case tenMin, thirtyMin, manual
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .tenMin:    return 600
        case .thirtyMin: return 1800
        case .manual:    return nil
        }
    }
    var locKey: String {
        switch self {
        case .tenMin:    return "interval.10m"
        case .thirtyMin: return "interval.30m"
        case .manual:    return "interval.manual"
        }
    }
}

/// 使用者偏好(語言、更新頻率、選單列顯示來源、各家要顯示哪些細項)。
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var language: AppLanguage {
        didSet { d.set(language.rawValue, forKey: "language") }
    }
    @Published var pollInterval: PollInterval {
        didSet { d.set(pollInterval.rawValue, forKey: "pollInterval") }
    }
    /// 選單列顯示哪一家:"all"(全部取最高)或 ProviderID 的 rawValue。
    @Published var menuProvider: String {
        didSet { d.set(menuProvider, forKey: "menuProvider") }
    }
    /// 選單列顯示該家哪個 bucket 的 key;""=該家最高。
    @Published var menuBucketKey: String {
        didSet { d.set(menuBucketKey, forKey: "menuBucketKey") }
    }
    /// 暫停讀取的 provider rawValue 清單。
    @Published private var disabledProviders: [String] {
        didSet { d.set(disabledProviders, forKey: "disabledProviders") }
    }
    /// 各家要顯示的 bucket key 清單(nil/未設 = 用各 bucket 的 defaultOn)。
    @Published private var enabled: [String: [String]] {
        didSet {
            if let data = try? JSONSerialization.data(withJSONObject: enabled) {
                d.set(data, forKey: "enabledBuckets")
            }
        }
    }
    /// 各家曾經看過的 bucket key。用來分辨「API 新增的桶」vs「使用者親手關掉的桶」：
    /// 沒看過的新桶走 defaultOn（自動顯示），看過但不在 enabled 的維持關閉。
    /// 0.2.8 前沒有這個欄位，升級上來是空的 → 目前桶一律視為新桶顯示一次。
    @Published private var seenBuckets: [String: [String]] {
        didSet {
            if let data = try? JSONSerialization.data(withJSONObject: seenBuckets) {
                d.set(data, forKey: "seenBucketKeys")
            }
        }
    }
    /// Codex 方案旁的「重置 ×N · M/d」徽章；預設顯示。
    @Published var showCodexResetCredits: Bool {
        didSet { d.set(showCodexResetCredits, forKey: "showCodexResetCredits") }
    }
    /// 停用的 Codex account_id。空 = 發現到的帳號都讀。
    @Published private var disabledCodexAccounts: [String] {
        didSet { d.set(disabledCodexAccounts, forKey: "disabledCodexAccounts") }
    }

    private init() {
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        pollInterval = PollInterval(rawValue: d.string(forKey: "pollInterval") ?? "") ?? .tenMin
        menuProvider = d.string(forKey: "menuProvider") ?? "all"
        menuBucketKey = d.string(forKey: "menuBucketKey") ?? ""
        disabledProviders = d.stringArray(forKey: "disabledProviders") ?? []
        if let data = d.data(forKey: "enabledBuckets"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            enabled = obj
        } else {
            enabled = [:]
        }
        if let data = d.data(forKey: "seenBucketKeys"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            seenBuckets = obj
        } else {
            seenBuckets = [:]
        }
        // 未寫過 key 時預設 true（維持 0.2.6 起的行為）
        if d.object(forKey: "showCodexResetCredits") == nil {
            showCodexResetCredits = true
        } else {
            showCodexResetCredits = d.bool(forKey: "showCodexResetCredits")
        }
        disabledCodexAccounts = d.stringArray(forKey: "disabledCodexAccounts") ?? []
    }

    func isProviderEnabled(_ provider: ProviderID) -> Bool {
        !disabledProviders.contains(provider.rawValue)
    }

    func setProvider(_ provider: ProviderID, enabled isEnabled: Bool) {
        var set = Set(disabledProviders)
        if isEnabled { set.remove(provider.rawValue) } else { set.insert(provider.rawValue) }
        disabledProviders = Array(set).sorted()
        if !isEnabled, menuProvider == provider.rawValue || (provider == .codex && menuProvider.hasPrefix("codex:")) {
            menuProvider = "all"
            menuBucketKey = ""
        }
    }

    func isCodexAccountEnabled(_ accountId: String) -> Bool {
        guard !accountId.isEmpty else { return true }
        return !disabledCodexAccounts.contains(accountId)
    }

    func setCodexAccount(_ accountId: String, enabled isEnabled: Bool) {
        guard !accountId.isEmpty else { return }
        var set = Set(disabledCodexAccounts)
        if isEnabled { set.remove(accountId) } else { set.insert(accountId) }
        disabledCodexAccounts = Array(set).sorted()
        if !isEnabled, menuProvider == "codex:\(accountId)" {
            menuProvider = "all"
            menuBucketKey = ""
        }
    }

    /// `codex:<accountId>` 沒存過時沿用舊的 `codex` 細項選擇。
    private func legacyPrefsKey(_ provider: String) -> String {
        if let idx = provider.firstIndex(of: ":") {
            return String(provider[..<idx])
        }
        return provider
    }

    /// 該家目前實際啟用的 bucket key 集合(沒存過就用 defaultOn)。
    /// 若存過的 key 與目前 API 桶完全不重疊（schema 變更，例如 Gemini 從 per-model 改成家族池），
    /// 回退 defaultOn，避免細項全部消失。
    /// 部分重疊時沿用舊選擇，但「沒看過的新桶」走 defaultOn（例如 0.2.8 新增的 Gemini 週額度），
    /// 避免 fallback 時代存下的舊子集把新桶永久隱藏；使用者親手關掉的（看過但不在存檔）維持關閉。
    func effectiveEnabled(_ provider: String, buckets: [UsageBucket]) -> Set<String> {
        let available = Set(buckets.map(\.key))
        let legacy = legacyPrefsKey(provider)
        var seen = Set(seenBuckets[provider] ?? seenBuckets[legacy] ?? [])
        let fresh = available.subtracting(seen)
        if !fresh.isEmpty {
            seen.formUnion(available)
            seenBuckets[provider] = Array(seen)
        }
        let defaults = Set(buckets.filter { $0.defaultOn }.map { $0.key })
        guard let saved = enabled[provider] ?? enabled[legacy] else { return defaults }
        let kept = Set(saved).intersection(available)
        if kept.isEmpty {
            // 存過的 key 與目前完全不重疊（schema 變更）→ 回 defaultOn 並清掉舊存檔
            enabled[provider] = Array(defaults)
            return defaults
        }
        let newcomers = fresh.intersection(defaults)
        if !newcomers.isEmpty {
            // 沒看過的新桶自動顯示一次，並寫回存檔；之後的開關都基於這份完整選擇
            let migrated = kept.union(newcomers)
            enabled[provider] = Array(migrated)
            return migrated
        }
        return kept
    }

    func isOn(_ provider: String, _ key: String, buckets: [UsageBucket]) -> Bool {
        effectiveEnabled(provider, buckets: buckets).contains(key)
    }

    func toggle(_ provider: String, _ key: String, on: Bool, buckets: [UsageBucket]) {
        // 與之前存的聯集：fallback（桶不全）時開關一次，不丟掉當下沒看到的桶的選擇。
        var set = Set(enabled[provider] ?? []).union(effectiveEnabled(provider, buckets: buckets))
        if on { set.insert(key) } else { set.remove(key) }
        enabled[provider] = Array(set)
    }

    /// 測試用快照(避免 self-test 弄髒使用者偏好)。
    struct Snapshot {
        var language: AppLanguage
        var pollInterval: PollInterval
        var menuProvider: String
        var menuBucketKey: String
        var disabledProviders: [String]
        var enabled: [String: [String]]
        var seenBuckets: [String: [String]]
        var showCodexResetCredits: Bool
        var disabledCodexAccounts: [String]
    }

    func snapshotForTest() -> Snapshot {
        Snapshot(language: language, pollInterval: pollInterval,
                 menuProvider: menuProvider, menuBucketKey: menuBucketKey,
                 disabledProviders: disabledProviders, enabled: enabled,
                 seenBuckets: seenBuckets,
                 showCodexResetCredits: showCodexResetCredits,
                 disabledCodexAccounts: disabledCodexAccounts)
    }

    func restoreForTest(_ s: Snapshot) {
        language = s.language
        pollInterval = s.pollInterval
        menuProvider = s.menuProvider
        menuBucketKey = s.menuBucketKey
        disabledProviders = s.disabledProviders
        enabled = s.enabled
        seenBuckets = s.seenBuckets
        showCodexResetCredits = s.showCodexResetCredits
        disabledCodexAccounts = s.disabledCodexAccounts
    }

    /// 測試用:啟用全部 provider,並覆寫各家顯示的 bucket keys。
    /// seen 預設等於顯示的 keys（「只看過這些」）；要模擬「看過全部再關掉幾個」時請傳完整集合。
    func applyTestDisplay(enabledProviders: [ProviderID], buckets: [ProviderID: [String]],
                          seen: [ProviderID: [String]]? = nil) {
        disabledCodexAccounts = []
        disabledProviders = ProviderID.allCases
            .filter { !enabledProviders.contains($0) }
            .map(\.rawValue)
        var next: [String: [String]] = [:]
        for (p, keys) in buckets { next[p.rawValue] = keys }
        enabled = next
        var nextSeen: [String: [String]] = [:]
        for (p, keys) in (seen ?? buckets) { nextSeen[p.rawValue] = keys }
        seenBuckets = nextSeen
    }
}

/// 重置倒數的共用格式:>1 天用「6d22h」、>1 小時用「3h26m」、否則「45m」。
func formatReset(_ date: Date?, lang: AppLanguage) -> String {
    guard let date else { return "" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "↻" + Loc.tr("reset.now", lang) }
    let dys = secs / 86400
    let h = (secs % 86400) / 3600
    let m = (secs % 3600) / 60
    if dys >= 1 { return "↻\(dys)d\(h)h" }
    if h >= 1 { return "↻\(h)h\(m)m" }
    return "↻\(m)m"
}
