import Foundation

enum Diagnostics {
    static func runReadOnly() -> [String] {
        ProviderID.allCases.map { diagnose($0) }
    }

    private static func diagnose(_ provider: ProviderID) -> String {
        do {
            switch provider {
            case .claude:
                let store = try ClaudeProvider.loadStore()
                let expMs = store.entry["expiresAt"] as? Double
                let plan = ClaudeProvider.parsePlan(tokenCache: store.tokenCache) ?? "unknown plan"
                return ok(provider, "\(plan), access token \(expiryText(expMs.map { Date(timeIntervalSince1970: $0 / 1000) }))")

            case .codex:
                let auth = try CodexProvider.loadAuth()
                let token = auth.tokens["access_token"] as? String ?? ""
                let account = (auth.tokens["account_id"] as? String).map { $0.isEmpty ? "no account id" : "account id present" } ?? "no account id"
                return ok(provider, "\(account), access token \(expiryText(CodexProvider.jwtExpiry(token)))")

            case .gemini:
                let creds = try GeminiProvider.loadCredsFromKeychain()
                let hasRefresh = creds.refreshToken?.isEmpty == false ? "refresh token present" : "no refresh token"
                return ok(provider, "\(hasRefresh), access token \(expiryText(creds.expiry))")

            case .grok:
                let store = try GrokProvider.loadStore()
                let hasRefresh = store.refreshToken?.isEmpty == false ? "refresh token present" : "no refresh token"
                let email = store.email.map { "\($0), " } ?? ""
                return ok(provider, "\(email)\(hasRefresh), access token \(expiryText(store.expiresAt))")
            }
        } catch {
            return fail(provider, error.localizedDescription)
        }
    }

    private static func ok(_ provider: ProviderID, _ detail: String) -> String {
        "✓ \(provider.displayName): \(detail)"
    }

    private static func fail(_ provider: ProviderID, _ detail: String) -> String {
        "✗ \(provider.displayName): \(detail)"
    }

    private static func expiryText(_ date: Date?) -> String {
        guard let date else { return "expiry unknown" }
        let mins = Int(date.timeIntervalSinceNow / 60)
        if mins < 0 { return "expired \(abs(mins)) min ago" }
        if mins < 120 { return "expires in \(mins) min" }
        return "expires in \(mins / 60) h"
    }
}
