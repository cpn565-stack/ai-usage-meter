import Foundation

enum FileBackups {
    static func backupBeforeWrite(path: String, tag: String, keep: Int = 3) throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: path)
        guard fm.fileExists(atPath: source.path) else { return }

        let dir = source.deletingLastPathComponent().appendingPathComponent(".UsageMeterBackups", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = backupStamp()
        let prefix = "\(source.lastPathComponent).\(tag)."
        let backup = dir.appendingPathComponent("\(prefix)\(stamp).bak")
        try fm.copyItem(at: source, to: backup)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        pruneBackups(in: dir, prefix: prefix, keep: keep)
    }

    private static func backupStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    private static func pruneBackups(in dir: URL, prefix: String, keep: Int) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { return }
        let matches = urls.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(".bak") }
        guard matches.count > keep else { return }

        let sorted = matches.sorted {
            let l = ((try? $0.resourceValues(forKeys: keys).creationDate)
                     ?? (try? $0.resourceValues(forKeys: keys).contentModificationDate)) ?? .distantPast
            let r = ((try? $1.resourceValues(forKeys: keys).creationDate)
                     ?? (try? $1.resourceValues(forKeys: keys).contentModificationDate)) ?? .distantPast
            return l > r
        }
        for old in sorted.dropFirst(keep) {
            try? fm.removeItem(at: old)
        }
    }
}
