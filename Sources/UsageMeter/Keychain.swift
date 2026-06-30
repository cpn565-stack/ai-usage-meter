import Foundation
import Security

enum Keychain {
    /// 讀取 generic password 的原始資料(找不到回 nil)。
    /// 注意:讀取屬於其他 app 的條目(如 "Claude Safe Storage")時,macOS 會跳權限詢問。
    static func genericPassword(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }
}
