import Foundation
import AppKit

/// Popover 布局回歸測試:不連網,用固定 fixture 驗證:
/// 1. 寬度固定、右側不被裁切
/// 2. header / 重新整理按鈕在面板內可見
/// 3. 取消細項後高度會變矮(不再留空白也不裁 header)
enum PanelLayoutSelfTests {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func run() throws -> [String] {
        // AppKit 布局需要 shared application。
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let prefsBackup = Prefs.shared.snapshotForTest()
        defer { Prefs.shared.restoreForTest(prefsBackup) }

        let store = UsageStore(skipInitialRefresh: true)
        let fixture = makeFixture()
        store.replaceResultsForTest(fixture)

        // 全部細項開啟
        Prefs.shared.applyTestDisplay(
            enabledProviders: ProviderID.allCases,
            buckets: fixture.mapValues { $0.buckets.map(\.key) }
        )
        Prefs.shared.language = .zhHant

        let panel = PanelViewController(store: store, openSettings: {})
        let full = panel.probeLayoutForTest()
        try assertBasicLayout(full, label: "full")

        // 只留每家一條 bucket → 高度必須明顯下降
        var leanBuckets: [ProviderID: [String]] = [:]
        for (p, usage) in fixture {
            leanBuckets[p] = usage.buckets.first.map { [$0.key] } ?? []
        }
        Prefs.shared.applyTestDisplay(enabledProviders: ProviderID.allCases, buckets: leanBuckets)
        let lean = panel.probeLayoutForTest()
        try assertBasicLayout(lean, label: "lean")

        let shrink = full.contentSize.height - lean.contentSize.height
        try expect(shrink >= 40,
                   "取消細項後高度應至少矮 40pt,實際 full=\(Int(full.contentSize.height)) lean=\(Int(lean.contentSize.height)) delta=\(Int(shrink))")

        // 再加回全部,高度應回升(防「只會長大不會縮小」或「卡住」)
        Prefs.shared.applyTestDisplay(
            enabledProviders: ProviderID.allCases,
            buckets: fixture.mapValues { $0.buckets.map(\.key) }
        )
        let fullAgain = panel.probeLayoutForTest()
        try assertBasicLayout(fullAgain, label: "full-again")
        try expect(abs(fullAgain.contentSize.height - full.contentSize.height) < 8,
                   "恢復全部細項後高度應回到接近原值 full=\(Int(full.contentSize.height)) again=\(Int(fullAgain.contentSize.height))")

        // formatReset 長度:確保 bar row 設計寬度夠放
        let resetSample = formatReset(Date().addingTimeInterval(6 * 86400 + 7 * 3600), lang: .zhHant)
        try expect(resetSample.count >= 4, "formatReset 應產出可顯示字串,得 \(resetSample)")

        return [
            "✓ Panel layout full \(Int(full.contentSize.width))×\(Int(full.contentSize.height))",
            "✓ Panel layout lean \(Int(lean.contentSize.width))×\(Int(lean.contentSize.height)) (Δ\(Int(shrink))pt)",
            "✓ Panel shrinks when buckets hidden",
            "✓ Header + refresh button inside bounds",
            "✓ Content width not clipped past panel",
        ]
    }

    @MainActor
    private static func assertBasicLayout(_ p: PanelLayoutProbe, label: String) throws {
        try expect(abs(p.contentSize.width - panelWidth) < 0.5,
                   "[\(label)] width 應為 \(Int(panelWidth)),得 \(Int(p.contentSize.width))")
        try expect(p.contentSize.height >= 120,
                   "[\(label)] height 過矮 \(Int(p.contentSize.height)) — header 可能被裁")
        try expect(p.headerHeight >= 42,
                   "[\(label)] header 高度異常 \(Int(p.headerHeight)) — 狀態列可能被擠扁")
        try expect(p.headerMinY >= -0.5,
                   "[\(label)] header 被裁到面板上方 minY=\(p.headerMinY)")
        // AppKit 座標:y 向上。標題應在狀態列「上面」→ titleMinY > statusMinY。
        // 兩者都必須落在 [0, contentSize.height] 內,否則 popover 會裁切。
        let contentH = p.contentSize.height
        try expect(p.titleMinY >= 0,
                   "[\(label)] 標題被裁到面板下方 titleMinY=\(p.titleMinY)")
        try expect(p.titleMinY + 12 <= contentH + 0.5,
                   "[\(label)] 標題被裁到面板上方 titleMinY=\(p.titleMinY) contentH=\(contentH)")
        try expect(p.statusMinY >= 0,
                   "[\(label)] 狀態列被裁到面板下方 statusMinY=\(p.statusMinY)")
        try expect(p.statusMinY + p.statusHeight <= contentH + 0.5,
                   "[\(label)] 狀態列被裁切 statusMaxY=\(p.statusMinY + p.statusHeight) contentH=\(contentH)")
        try expect(p.titleMinY > p.statusMinY,
                   "[\(label)] 標題應在狀態列上方(AppKit y↑) titleMinY=\(p.titleMinY) statusMinY=\(p.statusMinY)")
        try expect(p.statusHeight >= 10,
                   "[\(label)] 狀態列高度被擠扁 statusHeight=\(p.statusHeight)")
        try expect(p.headerMinY >= 0,
                   "[\(label)] header 底部應在面板內 headerMinY=\(p.headerMinY)")
        try expect(p.headerMinY + p.headerHeight <= contentH + 1,
                   "[\(label)] header 頂部超出 contentSize headerMaxY=\(p.headerMinY + p.headerHeight) contentH=\(contentH)")
        try expect(p.refreshVisible,
                   "[\(label)] 重新整理按鈕應可見")
        try expect(p.refreshMinY >= 0,
                   "[\(label)] 重新整理按鈕被裁到面板上方 minY=\(p.refreshMinY)")
        try expect(p.refreshMaxX <= p.panelWidth + 0.5,
                   "[\(label)] 重新整理超出右緣 maxX=\(p.refreshMaxX) width=\(p.panelWidth)")
        // 允許 scroller 等 1–2pt 誤差,但不可大段超出。
        try expect(p.rightmostContentX <= p.panelWidth + 2,
                   "[\(label)] 內容超出右緣 rightmost=\(p.rightmostContentX) width=\(p.panelWidth)")
    }

    private static func makeFixture() -> [ProviderID: ProviderUsage] {
        let reset = Date().addingTimeInterval(3 * 86400 + 6 * 3600)
        func buckets(_ items: [(String, String, Double)]) -> [UsageBucket] {
            items.map {
                UsageBucket(key: $0.0, label: $0.1, usedPercent: $0.2, resetsAt: reset, defaultOn: true)
            }
        }
        return [
            .claude: ProviderUsage(
                provider: .claude,
                buckets: buckets([
                    ("5h", "win.5h", 0),
                    ("week", "win.week", 2),
                    ("weekly.fable", "Fable", 3),
                ]),
                plan: "Pro", error: nil, updatedAt: Date()),
            .codex: ProviderUsage(
                provider: .codex,
                buckets: buckets([
                    ("5h", "win.5h", 100),
                    ("week", "win.week", 24),
                ]),
                plan: "team", error: nil, updatedAt: Date()),
            .gemini: ProviderUsage(
                provider: .gemini,
                buckets: buckets([
                    ("a", "Gemini A", 10),
                    ("b", "Gemini B", 20),
                    ("c", "Gemini C", 30),
                    ("d", "Gemini D", 40),
                ]),
                plan: "Antigravity", error: nil, updatedAt: Date()),
            .grok: ProviderUsage(
                provider: .grok,
                buckets: buckets([
                    ("week", "win.week", 26),
                    ("chat", "grok.chat", 12),
                    ("build", "grok.build", 9),
                    ("imagine", "grok.imagine", 4),
                ]),
                plan: "SuperGrok", error: nil, updatedAt: Date()),
        ]
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}

struct PanelLayoutProbe {
    var contentSize: NSSize
    var headerHeight: CGFloat
    var headerMinY: CGFloat
    var titleMinY: CGFloat
    var statusMinY: CGFloat
    var statusHeight: CGFloat
    var refreshVisible: Bool
    var refreshMaxX: CGFloat
    var refreshMinY: CGFloat
    var rightmostContentX: CGFloat
    var panelWidth: CGFloat
}
