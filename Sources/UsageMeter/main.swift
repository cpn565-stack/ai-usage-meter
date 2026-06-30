import Foundation
import AppKit

// `--refresh-claude`:一次性測試 Claude 續期+寫回(驗證 Swift 加密寫回正確)。
if CommandLine.arguments.contains("--refresh-claude") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let store = try ClaudeProvider.loadStore()
            let (tok, _) = try await ClaudeProvider.refreshAndPersist(store)
            print("✓ Swift 續期+寫回成功,新 token 前綴:", String(tok.prefix(14)))
            let s2 = try ClaudeProvider.loadStore()      // 用 app 自己的解密重讀
            let exp = (s2.entry["expiresAt"] as? Double ?? 0) / 1000
            print("✓ 重讀確認:剩 \(Int((exp - Date().timeIntervalSince1970) / 60)) 分,refreshToken 長度 \((s2.entry["refreshToken"] as? String)?.count ?? 0)")
        } catch { print("✗ 失敗:", error) }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// `--diagnose`:只讀檢查本機憑證狀態,不打 API、不刷新、不寫回。
if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--check") {
    for line in Diagnostics.runReadOnly() { print(line) }
    exit(0)
}

// `--self-test-parsers`:用固定 JSON 測三家 parser,不碰憑證、不連網。
if CommandLine.arguments.contains("--self-test-parsers") {
    do {
        for line in try ParserSelfTests.run() { print(line) }
        exit(0)
    } catch {
        print("✗ Parser self-test failed:", error.localizedDescription)
        exit(1)
    }
}

// `--once`:無頭模式,抓一次用量印出後結束(方便終端機驗證)。
if CommandLine.arguments.contains("--once") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        for p in ProviderID.allCases {
            do {
                let u = try await fetchProvider(p)
                func line(_ b: UsageBucket) -> String {
                    let label = Loc.tr(b.label, .zhHant)
                    var s = "\(label): \(Int(b.usedPercent.rounded()))%"
                    if !formatReset(b.resetsAt, lang: .zhHant).isEmpty {
                        s += " (\(formatReset(b.resetsAt, lang: .zhHant)))"
                    }
                    return s
                }
                let plan = u.plan.map { " [\($0)]" } ?? ""
                let cols = u.buckets.map(line).joined(separator: "  ")
                print("\(u.provider.displayName)\(plan)  \(cols)")
            } catch {
                print("\(p.displayName)  ✗ \(error.localizedDescription)")
            }
        }
        sem.signal()
    }
    sem.wait()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate          // NSApplication.delegate 是 weak,delegate 由本檔頂層 let 持有
    app.run()
}
