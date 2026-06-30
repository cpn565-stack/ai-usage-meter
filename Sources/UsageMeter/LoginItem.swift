import Foundation
import ServiceManagement

/// 用 SMAppService 把 app 自己註冊為登入啟動項(macOS 13+)。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            NSLog("LoginItem 設定失敗: \(error.localizedDescription)")
            return false
        }
    }
}
