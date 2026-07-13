import Foundation

/// Application Support 檔案快取 — 避免每次 refresh 都碰 Keychain 彈密碼。
/// 僅存本機專用資料（UsageMeter 自己的 token 快取、Claude Safe Storage 金鑰副本）。
enum AppSupportCache {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("UsageMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func readData(_ name: String) -> Data? {
        let url = fileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func writeData(_ data: Data, name: String) {
        let url = fileURL(name)
        try? data.write(to: url, options: .atomic)
        // 僅擁有者可讀寫
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(name))
    }
}
