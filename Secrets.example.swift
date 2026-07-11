import Foundation

/// 複製到 Sources 後即可建置(複製目標已被 .gitignore 排除):
///   cp Secrets.example.swift Sources/UsageMeter/Secrets.swift
///
/// CI 預設也會 `cp` 本檔;正式 release 請在 GitHub Actions secrets 注入真實值
/// (見 README「Public release → Gemini」):
///   GEMINI_CLIENT_ID / GEMINI_CLIENT_SECRET
///
/// 這兩個字串是 Antigravity 桌面版的「公開」OAuth client(原生 OAuth 無法真正保密),
/// 可從本機 Antigravity IDE 安裝包的 oauthClient 模組取得 — **不是** 個人帳號密碼。
/// 請勿把個人 API key 或帳密寫進這個檔再 commit。
enum Secrets {
    static let geminiClientID = "YOUR_ANTIGRAVITY_OAUTH_CLIENT_ID.apps.googleusercontent.com"
    static let geminiClientSecret = "YOUR_ANTIGRAVITY_OAUTH_CLIENT_SECRET"
}
