import Foundation
import UserNotifications

enum MaintenanceNotifier {
    private static let throttle: TimeInterval = 6 * 60 * 60
    private static let defaultsPrefix = "maintenanceNotice."

    @MainActor
    static func notifyIfNeeded(provider: ProviderID, error: ProviderError) {
        guard let hint = error.maintenanceHint else { return }

        let key = defaultsPrefix + provider.rawValue + "." + stableKey(hint)
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: key) as? Date,
           Date().timeIntervalSince(last) < throttle {
            return
        }
        defaults.set(Date(), forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "AI Usage Meter 需要更新"
        content.body = "\(provider.displayName) 用量讀取失敗，供應商 API 可能已變更。\(hint)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ai-usage-meter.\(provider.rawValue).maintenance.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    private static func stableKey(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
