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
    }

    func isProviderEnabled(_ provider: ProviderID) -> Bool {
        !disabledProviders.contains(provider.rawValue)
    }

    func setProvider(_ provider: ProviderID, enabled isEnabled: Bool) {
        var set = Set(disabledProviders)
        if isEnabled { set.remove(provider.rawValue) } else { set.insert(provider.rawValue) }
        disabledProviders = Array(set).sorted()
        if !isEnabled, menuProvider == provider.rawValue {
            menuProvider = "all"
            menuBucketKey = ""
        }
    }

    /// 該家目前實際啟用的 bucket key 集合(沒存過就用 defaultOn)。
    func effectiveEnabled(_ provider: String, buckets: [UsageBucket]) -> Set<String> {
        if let saved = enabled[provider] { return Set(saved) }
        return Set(buckets.filter { $0.defaultOn }.map { $0.key })
    }

    func isOn(_ provider: String, _ key: String, buckets: [UsageBucket]) -> Bool {
        effectiveEnabled(provider, buckets: buckets).contains(key)
    }

    func toggle(_ provider: String, _ key: String, on: Bool, buckets: [UsageBucket]) {
        var set = effectiveEnabled(provider, buckets: buckets)
        if on { set.insert(key) } else { set.remove(key) }
        enabled[provider] = Array(set)
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
