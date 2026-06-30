import Foundation
import Combine
import AppKit

/// 抓單一 provider 的官方用量(供 store 與 CLI 共用)。
func fetchProvider(_ p: ProviderID) async throws -> ProviderUsage {
    switch p {
    case .claude: return try await ClaudeProvider.fetch()
    case .codex:  return try await CodexProvider.fetch()
    case .gemini: return try await GeminiProvider.fetch()
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var results: [ProviderID: ProviderUsage] = [:]
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?

    private var timer: Timer?
    private var backoffUntil: [ProviderID: Date] = [:]
    private var backoffStep: [ProviderID: TimeInterval] = [:]
    private var cancellables = Set<AnyCancellable>()

    init() {
        for p in ProviderID.allCases { results[p] = .empty(p) }
        Task { await refreshAll() }
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
        isRefreshing = true
        for p in ProviderID.allCases { await refresh(p) }
        isRefreshing = false
        lastRefresh = Date()
    }

    func refresh(_ p: ProviderID) async {
        if let until = backoffUntil[p], Date() < until { return }   // 退避期間略過
        do {
            results[p] = try await fetchProvider(p)
            backoffStep[p] = nil
            backoffUntil[p] = nil
        } catch let e as ProviderError {
            if case .rateLimited = e {
                let step = min((backoffStep[p] ?? 300) * 2, 3600)
                backoffStep[p] = step
                backoffUntil[p] = Date().addingTimeInterval(step)
            }
            var cur = results[p] ?? .empty(p)
            cur.error = e.errorDescription
            cur.updatedAt = Date()
            results[p] = cur
        } catch {
            var cur = results[p] ?? .empty(p)
            cur.error = error.localizedDescription
            cur.updatedAt = Date()
            results[p] = cur
        }
    }

    /// 該家目前啟用(勾選)的 bucket。
    func enabledBuckets(_ p: ProviderID) -> [UsageBucket] {
        let all = results[p]?.buckets ?? []
        let on = Prefs.shared.effectiveEnabled(p.rawValue, buckets: all)
        return all.filter { on.contains($0.key) }
    }

    /// menu bar 標題:依偏好顯示「全部最高」或指定家/指定細項。
    var menuBarText: String {
        let prefs = Prefs.shared
        let pct: Double?
        if let p = ProviderID(rawValue: prefs.menuProvider) {
            let bs = enabledBuckets(p)
            if !prefs.menuBucketKey.isEmpty, let b = bs.first(where: { $0.key == prefs.menuBucketKey }) {
                pct = b.usedPercent
            } else {
                pct = bs.map { $0.usedPercent }.max()
            }
        } else {   // "all"
            pct = ProviderID.allCases.flatMap { enabledBuckets($0) }.map { $0.usedPercent }.max()
        }
        if let pct { return "\(Int(pct.rounded()))%" }
        return "—"
    }
}
