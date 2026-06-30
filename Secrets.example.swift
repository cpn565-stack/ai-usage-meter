import Foundation

/// 範本。複製到 Sources 後填入真實值即可建置(複製目標已被 .gitignore 排除):
///   cp Secrets.example.swift Sources/UsageMeter/Secrets.swift
///
/// 本檔放在 Sources 之外,不會被 SwiftPM 編譯,只當文件/範本用。
///
/// geminiClientID / geminiClientSecret 是 Antigravity 桌面版的「公開」OAuth client
/// (原生 OAuth client 無法真正保密),由社群逆向 opencode-antigravity-auth 取得;
/// 非個人帳號憑證。Gemini provider 用它向 Google 換取 access token。
enum Secrets {
    static let geminiClientID = "YOUR_ANTIGRAVITY_OAUTH_CLIENT_ID.apps.googleusercontent.com"
    static let geminiClientSecret = "YOUR_ANTIGRAVITY_OAUTH_CLIENT_SECRET"
}
