import Foundation

enum Diagnostics {
    static func runReadOnly() -> [String] {
        ProviderID.allCases.flatMap { diagnose($0) }
    }

    private static func diagnose(_ provider: ProviderID) -> [String] {
        do {
            switch provider {
            case .claude:
                let store = try ClaudeProvider.loadStore()
                let expMs = store.entry["expiresAt"] as? Double
                let plan = ClaudeProvider.parsePlan(tokenCache: store.tokenCache) ?? "unknown plan"
                return [ok(provider.displayName, "\(plan), access token \(expiryText(expMs.map { Date(timeIntervalSince1970: $0 / 1000) }))")]

            case .codex:
                return diagnoseCodex()

            case .gemini:
                return diagnoseGemini()

            case .grok:
                let store = try GrokProvider.loadStore()
                let hasRefresh = store.refreshToken?.isEmpty == false ? "refresh token present" : "no refresh token"
                let email = store.email.map { "\($0), " } ?? ""
                return [ok(provider.displayName, "\(email)\(hasRefresh), access token \(expiryText(store.expiresAt))")]
            }
        } catch {
            return [fail(provider.displayName, error.localizedDescription)]
        }
    }

    private static func diagnoseGemini() -> [String] {
        let discovery = GeminiProvider.discover()
        if discovery.accounts.isEmpty {
            do {
                let creds = try GeminiProvider.loadCredsFromKeychain()
                let hasRefresh = creds.refreshToken?.isEmpty == false ? "refresh token present" : "no refresh token"
                return [ok("Gemini", "\(hasRefresh), access token \(expiryText(creds.expiry))")]
            } catch {
                return [fail("Gemini", error.localizedDescription)]
            }
        }
        var lines: [String] = []
        for account in discovery.accounts {
            let label = "Gemini · \(account.profileName)"
            if let summary = GeminiProvider.credentialSummary(account) {
                let email = summary.email.map { "\($0), " } ?? ""
                let refresh = summary.hasRefresh ? "refresh token present" : "no refresh token"
                let active = account.isActive ? ", active in aisw" : ""
                lines.append(ok(label, "\(email)\(refresh), access token \(expiryText(summary.expiry))\(active)"))
            } else {
                lines.append(fail(label, "unreadable aisw profile"))
            }
        }
        for skipped in discovery.skipped {
            lines.append("· Gemini: skipped duplicate profile \(skipped.profileName) (same account as \(skipped.duplicateOf))")
        }
        return lines
    }

    private static func diagnoseCodex() -> [String] {
        let discovery = CodexProvider.discover()
        if discovery.accounts.isEmpty {
            return [fail("Codex", ProviderError.noCredentials("~/.codex/auth.json").errorDescription ?? "no credentials")]
        }
        var lines: [String] = []
        for account in discovery.accounts {
            do {
                let auth = try CodexProvider.loadAuth(path: account.authPath)
                let token = auth.tokens["access_token"] as? String ?? ""
                let label = account.homeLabel == "default" ? "Codex · default" : "Codex · \(account.homeLabel)"
                let email = account.email.map { "\($0), " } ?? ""
                let accountBit = account.accountId.isEmpty ? "no account id" : "account id present"
                lines.append(ok(label, "\(email)\(accountBit), access token \(expiryText(CodexProvider.jwtExpiry(token)))"))
            } catch {
                lines.append(fail("Codex · \(account.homeLabel)", error.localizedDescription))
            }
        }
        for skipped in discovery.skipped {
            lines.append("· Codex: skipped duplicate home \(skipped.homeLabel) (same account as \(skipped.duplicateOfLabel))")
        }
        return lines
    }

    private static func ok(_ name: String, _ detail: String) -> String {
        "✓ \(name): \(detail)"
    }

    private static func fail(_ name: String, _ detail: String) -> String {
        "✗ \(name): \(detail)"
    }

    private static func expiryText(_ date: Date?) -> String {
        guard let date else { return "expiry unknown" }
        let mins = Int(date.timeIntervalSinceNow / 60)
        if mins < 0 { return "expired \(abs(mins)) min ago" }
        if mins < 120 { return "expires in \(mins) min" }
        return "expires in \(mins / 60) h"
    }
}
