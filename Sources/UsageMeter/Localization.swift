import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHant = "zh-Hant", ja, en
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .system: return "system"
        case .zhHant: return "繁體中文"
        case .ja:     return "日本語"
        case .en:     return "English"
        }
    }
}

enum Loc {
    /// system → 依系統偏好語言對應到實際語言。
    static func resolve(_ lang: AppLanguage) -> AppLanguage {
        guard lang == .system else { return lang }
        for code in Locale.preferredLanguages {
            let c = code.lowercased()
            if c.hasPrefix("ja") { return .ja }
            if c.hasPrefix("zh") { return .zhHant }
            if c.hasPrefix("en") { return .en }
        }
        return .zhHant
    }

    static func tr(_ key: String, _ lang: AppLanguage) -> String {
        let l = resolve(lang)
        guard let row = table[key] else { return key }   // 未知 key 原樣回傳(如模型名)
        return row[l] ?? row[.en] ?? key
    }

    private static let table: [String: [AppLanguage: String]] = [
        "app.title":   [.zhHant: "AI 用量",   .ja: "AI 使用量",       .en: "AI Usage"],
        "win.5h":      [.zhHant: "5 小時",    .ja: "5時間",          .en: "5h"],
        "win.week":    [.zhHant: "週",        .ja: "週間",           .en: "Week"],
        "row.loading": [.zhHant: "讀取中…",   .ja: "読み込み中…",     .en: "Loading…"],
        "row.disabled":[.zhHant: "已停用",    .ja: "無効",           .en: "Disabled"],
        "row.noProviders":[.zhHant:"沒有啟用的來源", .ja:"有効な読み取り元なし", .en:"No enabled sources"],
        "status.refreshing":[.zhHant:"更新中…", .ja:"更新中…",       .en:"Refreshing…"],
        "status.noProviders":[.zhHant:"沒有啟用的來源", .ja:"有効な読み取り元なし", .en:"No sources enabled"],
        "status.errors":[.zhHant:"%d 個來源需要確認", .ja:"%d件の読み取り元を確認", .en:"%d sources need attention"],
        "status.updated":[.zhHant:"更新於 %@", .ja:"%@に更新",       .en:"Updated %@"],
        "status.next": [.zhHant:"下次 %@",     .ja:"次回 %@",        .en:"next %@"],
        "foot.updated":[.zhHant: "更新於",    .ja: "更新",           .en: "Updated"],
        "foot.never":  [.zhHant: "尚未更新",  .ja: "未更新",         .en: "Not updated"],
        "btn.refresh": [.zhHant: "重新整理",  .ja: "更新",           .en: "Refresh"],
        "btn.quit":    [.zhHant: "結束",      .ja: "終了",           .en: "Quit"],
        "btn.prefs":   [.zhHant: "偏好設定…", .ja: "環境設定…",      .en: "Preferences…"],
        "set.title":   [.zhHant: "偏好設定",  .ja: "環境設定",       .en: "Preferences"],
        "set.general": [.zhHant: "一般",      .ja: "一般",           .en: "General"],
        "set.language":[.zhHant: "語言",      .ja: "言語",           .en: "Language"],
        "set.launch":  [.zhHant: "開機自動啟動", .ja: "ログイン時に起動", .en: "Launch at login"],
        "set.providers":[.zhHant: "讀取來源", .ja: "読み取り元",      .en: "Providers"],
        "set.version": [.zhHant: "版本",      .ja: "バージョン",      .en: "Version"],
        "lang.system": [.zhHant: "跟隨系統",  .ja: "システムに従う",  .en: "System"],
        "reset.now":   [.zhHant: "重置中",    .ja: "リセット中",      .en: "resetting"],
        "set.interval":[.zhHant: "更新頻率",  .ja: "更新頻度",        .en: "Update interval"],
        "interval.10m":[.zhHant: "10 分鐘",   .ja: "10分",           .en: "10 min"],
        "interval.30m":[.zhHant: "30 分鐘",   .ja: "30分",           .en: "30 min"],
        "interval.manual":[.zhHant:"手動",    .ja: "手動",           .en: "Manual"],
        "set.menubar": [.zhHant: "選單列顯示",.ja: "メニューバー表示",.en: "Menu bar shows"],
        "menu.all":    [.zhHant: "全部(最高)",.ja: "すべて(最大)",   .en: "All (max)"],
        "menu.window": [.zhHant: "窗口",      .ja: "期間",           .en: "Window"],
        "bucket.max":  [.zhHant: "最高",      .ja: "最大",           .en: "Max"],
        "set.display": [.zhHant: "顯示細項",  .ja: "表示する項目",    .en: "Shown items"],
        "btn.checkUpdate":[.zhHant:"檢查更新…",.ja:"アップデートを確認…",.en:"Check for Updates…"],
        "grok.chat":   [.zhHant: "對話",      .ja: "チャット",       .en: "Chat"],
        "grok.build":  [.zhHant: "Grok Build",.ja: "Grok Build",     .en: "Grok Build"],
        "grok.imagine":[.zhHant: "Imagine",   .ja: "Imagine",        .en: "Imagine"],
        "grok.plugins":[.zhHant: "Plugins",   .ja: "Plugins",        .en: "Plugins"],
        "grok.other":  [.zhHant: "其他",     .ja: "その他",       .en: "Other"],
    ]
}
