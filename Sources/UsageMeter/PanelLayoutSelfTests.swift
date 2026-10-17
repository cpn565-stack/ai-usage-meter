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
        Prefs.shared.applyTestDisplay(enabledProviders: ProviderID.allCases, buckets: leanBuckets,
                                      seen: fixture.mapValues { $0.buckets.map(\.key) })
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

        // 0.2.8 回歸:Gemini 標籤(`Claude/GPT · 5 小時`約 106pt)曾被 74pt 欄寬截成 `...`
        try assertBarLabelsFit(fixture)

        // 回報案回歸:API 正常回 4 桶，但 enabledBuckets 存著 fallback 時代的舊子集，
        // 週額度被過濾掉。舊子集 + 新桶 → 新桶要自動顯示；親手關的 → 維持關閉。
        try testStaleSubsetReshowsNewBuckets()
        try testTwoCodexRowsLayout()

        return [
            "✓ Panel layout full \(Int(full.contentSize.width))×\(Int(full.contentSize.height))",
            "✓ Panel layout lean \(Int(lean.contentSize.width))×\(Int(lean.contentSize.height)) (Δ\(Int(shrink))pt)",
            "✓ Panel shrinks when buckets hidden",
            "✓ Header + refresh button inside bounds",
            "✓ Content width not clipped past panel",
            "✓ Bar labels fit label column",
            "✓ Stale bucket subset still shows new buckets",
            "✓ Two Codex account rows layout",
        ]
    }

    /// 所有語系下已知的 bucket 標籤都必須塞進 barLabelWidth，否則會被截成 `...`。
    @MainActor
    private static func assertBarLabelsFit(_ fixture: [ProviderID: ProviderUsage]) throws {
        let font = NSFont.systemFont(ofSize: 11)
        var keys = Set<String>()
        for usage in fixture.values { for b in usage.buckets { keys.insert(b.label) } }
        keys.formUnion(["win.5h", "win.week",
                        "gemini.bucket.gemini.5h", "gemini.bucket.gemini.week",
                        "gemini.bucket.argon.5h", "gemini.bucket.argon.week",
                        "gemini.bucket.partner.5h", "gemini.bucket.partner.week",
                        "grok.chat", "grok.build", "grok.imagine", "grok.other"])
        for lang in [AppLanguage.zhHant, AppLanguage.ja, AppLanguage.en] {
            for key in keys {
                let s = Loc.tr(key, lang)
                let w = (s as NSString).size(withAttributes: [.font: font]).width
                try expect(w <= barLabelWidth,
                           "標籤欄太窄:[\(lang.rawValue)]「\(s)」需 \(Int(ceil(w)))pt,欄寬僅 \(Int(barLabelWidth))")
            }
        }
    }

    /// 舊顯示子集 + API 新增桶 → 新桶自動顯示；親手關掉的維持關閉；
    /// fallback（桶不全）時開關不丟掉沒看到的桶的選擇。
    @MainActor
    private static func testStaleSubsetReshowsNewBuckets() throws {
        let reset = Date().addingTimeInterval(3600)
        func bucket(_ key: String) -> UsageBucket {
            UsageBucket(key: key, label: key, usedPercent: 10, resetsAt: reset, defaultOn: true)
        }
        let four = [bucket("gemini.week"), bucket("gemini.5h"),
                    bucket("partner.week"), bucket("partner.5h")]
        let fullKeys = Set(four.map(\.key))
        // 模擬回報案：存檔是 fallback 時代的舊子集，週額度從沒看過
        Prefs.shared.applyTestDisplay(enabledProviders: [.gemini],
                                      buckets: [.gemini: ["gemini.5h", "partner.5h"]])
        var eff = Prefs.shared.effectiveEnabled("gemini", buckets: four)
        try expect(eff == fullKeys, "舊子集 + 新桶應自動顯示新桶，得 \(eff.sorted())")
        // 親手關掉 partner.week → 下次刷新仍維持關閉
        Prefs.shared.toggle("gemini", "partner.week", on: false, buckets: four)
        eff = Prefs.shared.effectiveEnabled("gemini", buckets: four)
        try expect(eff == fullKeys.subtracting(["partner.week"]),
                   "親手關掉的桶應維持關閉，得 \(eff.sorted())")
        // fallback（桶不全）時開 "gemini.5h"，不應丟掉沒看到的 gemini.week
        Prefs.shared.toggle("gemini", "gemini.5h", on: true,
                            buckets: [bucket("gemini.5h"), bucket("partner.5h")])
        eff = Prefs.shared.effectiveEnabled("gemini", buckets: four)
        try expect(eff == fullKeys.subtracting(["partner.week"]),
                   "fallback 時開關不應丟失週額度，得 \(eff.sorted())")
    }

    /// 兩個獨立 Codex 帳號應並排成兩列，且不裁切。
    @MainActor
    private static func testTwoCodexRowsLayout() throws {
        let reset = Date().addingTimeInterval(3600)
        func buckets() -> [UsageBucket] {
            [
                UsageBucket(key: "5h", label: "win.5h", usedPercent: 10, resetsAt: reset, defaultOn: true),
                UsageBucket(key: "week", label: "win.week", usedPercent: 20, resetsAt: reset, defaultOn: true),
            ]
        }
        let plus = ProviderUsage(provider: .codex, accountKey: "acct-plus", accountLabel: "default",
                                 buckets: buckets(), plan: "Plus", error: nil, updatedAt: Date())
        let work = ProviderUsage(provider: .codex, accountKey: "acct-work", accountLabel: "work",
                                 buckets: buckets(), plan: "Business", error: nil, updatedAt: Date())
        let claude = ProviderUsage(provider: .claude, buckets: buckets(), plan: "Pro", error: nil, updatedAt: Date())
        let store = UsageStore(skipInitialRefresh: true)
        store.replaceResultsForTest([plus, work, claude])
        Prefs.shared.applyTestDisplay(enabledProviders: [.codex, .claude],
                                      buckets: [.codex: ["5h", "week"], .claude: ["5h", "week"]])
        Prefs.shared.language = .zhHant
        let panel = PanelViewController(store: store, openSettings: {})
        let probe = panel.probeLayoutForTest()
        try assertBasicLayout(probe, label: "two-codex")
        try expect(store.visibleCodexCount == 2, "visible Codex count should be 2")
        try expect(plus.rowTitle(multiCodex: true, lang: .zhHant) == "Codex · 預設",
                   "default account title")
        try expect(work.rowTitle(multiCodex: true, lang: .zhHant) == "Codex · work",
                   "work account title")
    }

    @MainActor
    private static func assertBasicLayout(_ p: PanelLayoutProbe, label: String) throws {
        try expect(abs(p.contentSize.width - panelWidth) < 0.5,
                   "[\(label)] width 應為 \(Int(panelWidth)),得 \(Int(p.contentSize.width))")
        try expect(p.contentSize.height >= 120,
                   "[\(label)] height 過矮 \(Int(p.contentSize.height)) — header 可能被裁")
        try expect(p.headerHeight >= 28,
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
                plan: "Business",
                planAccessory: "重置 ×2 · 7/26",
                error: nil, updatedAt: Date()),
            .gemini: ProviderUsage(
                provider: .gemini,
                buckets: buckets([
                    ("gemini.week", "gemini.bucket.gemini.week", 20),
                    ("gemini.5h", "gemini.bucket.gemini.5h", 10),
                    ("partner.week", "gemini.bucket.partner.week", 40),
                    ("partner.5h", "gemini.bucket.partner.5h", 30),
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
