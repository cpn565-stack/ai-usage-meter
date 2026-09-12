import Foundation

/// 一個用量「桶」:可能是 5 小時窗、7 天窗、某個 Claude 子限額,或 Gemini 家族池(Gemini / Opus·GPT)。
struct UsageBucket: Equatable, Identifiable {
    var key: String           // 穩定識別碼(供勾選用),例:"5h"、"design"、"gemini-3-flash"
    var label: String         // 顯示字串(可為 localization key 或字面值)
    var usedPercent: Double    // 0...100
    var resetsAt: Date?
    var defaultOn: Bool = true // 首次預設是否顯示
    var id: String { key }
}

enum ProviderID: String, CaseIterable, Identifiable {
    case claude, codex, gemini, grok
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .grok:   return "Grok"
        }
    }
}

/// 本機一個獨立的 Codex ChatGPT 帳號（已依 account_id 去重）。
struct CodexAccount: Equatable {
    var accountId: String
    var email: String?
    var planHint: String?
    var homePath: String
    var homeLabel: String
    var isDefault: Bool
    var lastRefresh: Date

    var authPath: String {
        (homePath as NSString).appendingPathComponent("auth.json")
    }
}

struct CodexSkippedHome: Equatable {
    var homePath: String
    var homeLabel: String
    var duplicateOfLabel: String
}

struct CodexDiscovery: Equatable {
    var accounts: [CodexAccount]
    var skipped: [CodexSkippedHome]
}

/// 單一 provider 的最新用量結果(成功或失敗)。
struct ProviderUsage: Equatable {
    var provider: ProviderID
    /// Codex 多帳號：ChatGPT account id。其他家為空。
    var accountKey: String = ""
    /// CODEX_HOME 短名：`default` / `work` / `personal`。
    var accountLabel: String? = nil
    var accountEmail: String? = nil
    var buckets: [UsageBucket]
    var plan: String?
    /// 方案旁的補充資訊（例如 Codex 手動重置「×2 · 7/26」）。
    var planAccessory: String? = nil
    var error: String?
    var updatedAt: Date?

    static func empty(_ p: ProviderID) -> ProviderUsage {
        ProviderUsage(provider: p, buckets: [], plan: nil, planAccessory: nil, error: nil, updatedAt: nil)
    }

    /// 偏好設定 / 結果表的穩定鍵。單帳號 Codex 仍是 `codex`。
    var slotID: String {
        if provider == .codex, !accountKey.isEmpty { return "codex:\(accountKey)" }
        return provider.rawValue
    }

    /// 給 menu bar 用的「最緊繃」百分比。
    var worstPercent: Double? { buckets.map { $0.usedPercent }.max() }

    func rowTitle(multiCodex: Bool, lang: AppLanguage) -> String {
        guard provider == .codex, multiCodex else { return provider.displayName }
        let label = localizedAccountLabel(lang)
        if label.isEmpty { return provider.displayName }
        return "\(provider.displayName) · \(label)"
    }

    func localizedAccountLabel(_ lang: AppLanguage) -> String {
        guard let accountLabel, !accountLabel.isEmpty else { return "" }
        if accountLabel == "default" { return Loc.tr("codex.home.default", lang) }
        return accountLabel
    }
}

enum ProviderError: LocalizedError {
    case noCredentials(String)
    case rateLimited            // 429
    case tokenExpired           // 401
    case http(Int)
    case decrypt(String)
    case parse(String)
    case apiChanged(String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .noCredentials(let s): return "找不到憑證或尚未授權:\(s)"
        case .rateLimited:          return "被限流 (429)"
        case .tokenExpired:         return "Token 過期"
        case .http(let c):          return "HTTP \(c)"
        case .decrypt(let s):       return "解密失敗:\(s)"
        case .parse(let s):         return "解析失敗:\(s)"
        case .apiChanged(let s):    return "API 格式可能已改變:\(s)"
        case .notImplemented:       return "尚未接入"
        }
    }

    var maintenanceHint: String? {
        switch self {
        case .apiChanged(let s):
            return s
        case .http(let c) where [404, 410, 422].contains(c):
            return "endpoint 回傳 HTTP \(c)。"
        default:
            return nil
        }
    }
}
