import Foundation
import Combine
import AppKit

/// 抓單一 provider 的官方用量(供 store 與 CLI 共用)。
func fetchProvider(_ p: ProviderID) async throws -> ProviderUsage {
    switch p {
    case .claude: return try await ClaudeProvider.fetch()
    case .codex:  return try await CodexProvider.fetch()
    case .gemini: return try await GeminiProvider.fetch()
    case .grok:   return try await GrokProvider.fetch()
    }
}

@MainActor
final class UsageStore: ObservableObject {
    /// 以 slotID 為鍵（Claude/Gemini/Grok 仍是 provider rawValue；Codex 多帳號是 `codex:<accountId>`）。
    @Published var results: [String: ProviderUsage] = [:]
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    @Published var lastSuccessfulRefresh: Date?
    @Published var codexDiscovery = CodexDiscovery(accounts: [], skipped: [])

    private var timer: Timer?
    private var backoffUntil: [String: Date] = [:]
    private var backoffStep: [String: TimeInterval] = [:]
    private var inFlightProviders = Set<ProviderID>()
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter skipInitialRefresh: self-test / 布局探測用,不連網。
    init(skipInitialRefresh: Bool = false) {
        for p in ProviderID.allCases { results[p.rawValue] = .empty(p) }
        if !skipInitialRefresh {
            seedCodexPlaceholders()
            Task { await refreshAll() }
        }
        // 更新頻率改變時重設計時器。
        Prefs.shared.$pollInterval
            .sink { [weak self] iv in self?.reschedule(iv) }
            .store(in: &cancellables)
        reschedule(Prefs.shared.pollInterval)

        // 電腦喚醒時重抓(睡眠期間 token 可能過期)。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    /// 測試用:寫入固定用量結果,不觸發網路。
    func replaceResultsForTest(_ map: [ProviderID: ProviderUsage]) {
        var next: [String: ProviderUsage] = [:]
        for (_, usage) in map { next[usage.slotID] = usage }
        results = next
        lastRefresh = Date()
        lastSuccessfulRefresh = Date()
        isRefreshing = false
    }

    func replaceResultsForTest(_ items: [ProviderUsage]) {
        var next: [String: ProviderUsage] = [:]
        for usage in items { next[usage.slotID] = usage }
        results = next
        lastRefresh = Date()
        lastSuccessfulRefresh = Date()
        isRefreshing = false
    }

    /// 資料過舊才重抓(用於打開選單時)。
    func refreshIfStale(_ minInterval: TimeInterval) async {
        if isRefreshing { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < minInterval { return }
        await refreshAll()
    }

    private func reschedule(_ iv: PollInterval) {
        timer?.invalidate()
        timer = nil
        guard let secs = iv.seconds else { return }   // 手動:不排程
        timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }

    func refreshAll() async {
        if isRefreshing { return }
        isRefreshing = true
        for p in ProviderID.allCases {
            if Prefs.shared.isProviderEnabled(p) {
                await refresh(p)
            } else {
                disableProvider(p)
            }
        }
        isRefreshing = false
        lastRefresh = Date()
    }

    func refresh(_ p: ProviderID) async {
        guard Prefs.shared.isProviderEnabled(p) else { return }
        if inFlightProviders.contains(p) { return }
        inFlightProviders.insert(p)
        defer { inFlightProviders.remove(p) }

        if p == .codex {
            await refreshCodex()
            return
        }

        let slot = p.rawValue
        if let until = backoffUntil[slot], Date() < until { return }
        do {
            results[slot] = try await fetchProvider(p)
            lastSuccessfulRefresh = Date()
            backoffStep[slot] = nil
            backoffUntil[slot] = nil
        } catch let e as ProviderError {
            applyFailure(slot: slot, provider: p, existing: results[slot] ?? .empty(p), error: e)
        } catch {
            var cur = results[slot] ?? .empty(p)
            cur.error = error.localizedDescription
            cur.updatedAt = Date()
            results[slot] = cur
        }
    }

    private func refreshCodex() async {
        let discovery = CodexProvider.discover()
        codexDiscovery = discovery
        let wanted = discovery.accounts.filter { Prefs.shared.isCodexAccountEnabled($0.accountId) }
        let wantedIDs = Set(wanted.map(\.accountId))

        for key in Array(results.keys) {
            guard results[key]?.provider == .codex else { continue }
            let accountKey = results[key]?.accountKey ?? ""
            if accountKey.isEmpty || !wantedIDs.contains(accountKey) {
                results[key] = nil
            }
        }

        if wanted.isEmpty {
            if discovery.accounts.isEmpty {
                var empty = ProviderUsage.empty(.codex)
                empty.error = ProviderError.noCredentials("~/.codex/auth.json").errorDescription
                empty.updatedAt = Date()
                results[ProviderID.codex.rawValue] = empty
            }
            return
        }

        for account in wanted {
            let usage = CodexProvider.placeholder(account)
            if results[usage.slotID] == nil {
                results[usage.slotID] = usage
            }
        }

        await withTaskGroup(of: (String, ProviderUsage, ProviderError?).self) { group in
            for account in wanted {
                let slot = CodexProvider.placeholder(account).slotID
                if let until = backoffUntil[slot], Date() < until { continue }
                group.addTask {
                    do {
                        return (slot, try await CodexProvider.fetch(account: account), nil)
                    } catch let error as ProviderError {
                        return (slot, CodexProvider.failed(account: account, message: error.errorDescription ?? "\(error)"), error)
                    } catch {
                        return (slot, CodexProvider.failed(account: account, message: error.localizedDescription), nil)
                    }
                }
            }
            for await (slot, usage, error) in group {
                if let error {
                    applyFailure(slot: slot, provider: .codex, existing: usage, error: error)
                } else {
                    results[slot] = usage
                    lastSuccessfulRefresh = Date()
                    backoffStep[slot] = nil
                    backoffUntil[slot] = nil
                }
            }
        }
    }

    private func seedCodexPlaceholders() {
        guard Prefs.shared.isProviderEnabled(.codex) else { return }
        let discovery = CodexProvider.discover()
        codexDiscovery = discovery
        let wanted = discovery.accounts.filter { Prefs.shared.isCodexAccountEnabled($0.accountId) }
        guard !wanted.isEmpty else { return }
        results.removeValue(forKey: ProviderID.codex.rawValue)
        for account in wanted {
            let usage = CodexProvider.placeholder(account)
            results[usage.slotID] = usage
        }
    }

    private func disableProvider(_ p: ProviderID) {
        for key in Array(results.keys) where results[key]?.provider == p {
            results[key] = nil
        }
        results[p.rawValue] = .empty(p)
        if p == .codex {
            for key in Array(backoffUntil.keys) where key.hasPrefix("codex") {
                backoffUntil[key] = nil
                backoffStep[key] = nil
            }
        } else {
            backoffUntil[p.rawValue] = nil
            backoffStep[p.rawValue] = nil
        }
    }

    private func applyFailure(slot: String, provider: ProviderID, existing: ProviderUsage, error: ProviderError) {
        if case .rateLimited = error {
            let step = min((backoffStep[slot] ?? 300) * 2, 3600)
            backoffStep[slot] = step
            backoffUntil[slot] = Date().addingTimeInterval(step)
        }
        MaintenanceNotifier.notifyIfNeeded(provider: provider, error: error)
        var cur = existing
        cur.error = error.errorDescription
        cur.updatedAt = Date()
        results[slot] = cur
    }

    func orderedUsages() -> [ProviderUsage] {
        var out: [ProviderUsage] = []
        for p in ProviderID.allCases {
            let items = results.values.filter { $0.provider == p }
            if p == .codex {
                out.append(contentsOf: items.sorted(by: Self.codexDisplayOrder))
            } else if let usage = items.first {
                out.append(usage)
            }
        }
        return out
    }

    var visibleCodexCount: Int {
        orderedUsages().filter { usage in
            usage.provider == .codex
                && Prefs.shared.isProviderEnabled(.codex)
                && (usage.accountKey.isEmpty || Prefs.shared.isCodexAccountEnabled(usage.accountKey))
        }.count
    }

    private static func codexDisplayOrder(_ a: ProviderUsage, _ b: ProviderUsage) -> Bool {
        func rank(_ usage: ProviderUsage) -> (Int, String) {
            if usage.accountLabel == "default" || usage.accountKey.isEmpty { return (0, "") }
            return (1, usage.accountLabel ?? usage.accountKey)
        }
        let ra = rank(a), rb = rank(b)
        if ra.0 != rb.0 { return ra.0 < rb.0 }
        return ra.1.localizedStandardCompare(rb.1) == .orderedAscending
    }

    /// 該家目前啟用(勾選)的 bucket。多帳號 Codex 會合併各 slot（選單列「窗口」在 provider 層級時用）。
    func enabledBuckets(_ p: ProviderID) -> [UsageBucket] {
        usages(for: p).flatMap { enabledBuckets(for: $0) }
    }

    func enabledBuckets(for usage: ProviderUsage) -> [UsageBucket] {
        guard Prefs.shared.isProviderEnabled(usage.provider) else { return [] }
        if usage.provider == .codex, !usage.accountKey.isEmpty,
           !Prefs.shared.isCodexAccountEnabled(usage.accountKey) {
            return []
        }
        let on = Prefs.shared.effectiveEnabled(usage.slotID, buckets: usage.buckets)
        return usage.buckets.filter { on.contains($0.key) }
    }

    func usages(for provider: ProviderID) -> [ProviderUsage] {
        orderedUsages().filter { $0.provider == provider }
    }

    func usage(slotID: String) -> ProviderUsage? {
        results[slotID]
    }

    struct MenuSource {
        var id: String
        var title: String
    }

    func menuSources(lang: AppLanguage) -> [MenuSource] {
        var out: [MenuSource] = [MenuSource(id: "all", title: Loc.tr("menu.all", lang))]
        for p in ProviderID.allCases where Prefs.shared.isProviderEnabled(p) {
            if p == .codex {
                let slots = usages(for: .codex).filter {
                    $0.accountKey.isEmpty || Prefs.shared.isCodexAccountEnabled($0.accountKey)
                }
                if slots.count <= 1 {
                    out.append(MenuSource(id: "codex", title: p.displayName))
                } else {
                    out.append(MenuSource(id: "codex", title: Loc.tr("menu.codex.max", lang)))
                    for usage in slots {
                        out.append(MenuSource(id: usage.slotID, title: usage.rowTitle(multiCodex: true, lang: lang)))
                    }
                }
            } else {
                out.append(MenuSource(id: p.rawValue, title: p.displayName))
            }
        }
        return out
    }

    /// menu bar 標題:依偏好顯示「全部最高」或指定家/指定細項。
    var menuBarText: String {
        let prefs = Prefs.shared
        let pct: Double?
        if prefs.menuProvider == "all" {
            pct = orderedUsages()
                .filter { Prefs.shared.isProviderEnabled($0.provider) }
                .flatMap { enabledBuckets(for: $0) }
                .map(\.usedPercent)
                .max()
        } else if prefs.menuProvider.hasPrefix("codex:"),
                  let usage = results[prefs.menuProvider] {
            if !prefs.menuBucketKey.isEmpty,
               let bucket = enabledBuckets(for: usage).first(where: { $0.key == prefs.menuBucketKey }) {
                pct = bucket.usedPercent
            } else {
                pct = enabledBuckets(for: usage).map(\.usedPercent).max()
            }
        } else if let p = ProviderID(rawValue: prefs.menuProvider) {
            let buckets = enabledBuckets(p)
            if p != .codex || visibleCodexCount <= 1,
               !prefs.menuBucketKey.isEmpty,
               let bucket = buckets.first(where: { $0.key == prefs.menuBucketKey }) {
                pct = bucket.usedPercent
            } else if p == .codex, visibleCodexCount > 1 {
                pct = buckets.map(\.usedPercent).max()
            } else {
                pct = buckets.map(\.usedPercent).max()
            }
        } else {
            pct = nil
        }
        if let pct { return "\(Int(pct.rounded()))%" }
        return "—"
    }

    var nextRefresh: Date? {
        guard let secs = Prefs.shared.pollInterval.seconds, let last = lastRefresh else { return nil }
        return last.addingTimeInterval(secs)
    }

    var activeErrorCount: Int {
        orderedUsages()
            .filter { Prefs.shared.isProviderEnabled($0.provider) }
            .filter { usage in
                if usage.provider == .codex, !usage.accountKey.isEmpty,
                   !Prefs.shared.isCodexAccountEnabled(usage.accountKey) {
                    return false
                }
                return usage.error != nil
            }
            .count
    }
}
