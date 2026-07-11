import Foundation
import Sparkle

/// Sparkle 2 自動更新包裝。
/// - 啟動時由 `AppDelegate` 建立並 `startUpdater()`
/// - 偏好設定「檢查更新…」呼叫 `checkForUpdates()`
///
/// Feed / 簽章金鑰見 Info.plist:
/// - `SUFeedURL` → appcast(預設 main 分支 raw URL,見 package.sh)
/// - `SUPublicEDKey` → EdDSA 公鑰(generate_keys 產出)
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// 保留 controller 生命週期(否則更新檢查會立刻被釋放)。
    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
    }

    /// 啟動背景自動檢查(遵循 Info.plist `SUEnableAutomaticChecks`)。
    func start() {
        guard controller == nil else { return }
        // startingUpdater: true → 建立後立刻依排程檢查
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 使用者手動「檢查更新」。
    func checkForUpdates() {
        if controller == nil { start() }
        controller?.checkForUpdates(nil)
    }

    /// 目前 Sparkle 是否已就緒(測試 / 診斷用)。
    var isReady: Bool { controller != nil }
}
