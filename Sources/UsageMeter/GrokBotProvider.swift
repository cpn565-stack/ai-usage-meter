import Foundation

/// Grok Bot（`com.anysphere.sand`）的週用量。
///
/// 只讀 Grok Bot 自己寫下的本機快取，不打 API、不讀 `sand-secrets.json`、
/// 也不解密 Keychain「Grok Bot Safe Storage」。快取要等 Grok Bot 自己更新；
/// 過期仍顯示最後一次百分比。這條額度與 Grok CLI（`~/.grok/auth.json`）無關。
enum GrokBotProvider {
    static let persistenceDirectory = NSString(
        string: "~/Library/Application Support/Grok Bot/sand-client-persistence"
    ).expandingTildeInPath

    static let missingCacheHint = "請先開啟 Grok Bot，讓它寫下本機週用量"

    private static let accountSlotKey = "sand.client.slice.client-meta.account-slot"
    private static let accountKeyPrefix = "sand.client.slice.account."
    private static let cacheKeySuffix = ".weekly-usage.cache"

    struct Snapshot {
        var usage: ProviderUsage
        var readAtMs: Double
    }

    static func fetch() async throws -> ProviderUsage {
        try load(directory: persistenceDirectory)
    }

    /// 掃描 persistence 目錄裡 base32 檔名的 blob。
    /// 有 account slot 時只用那個帳號的 `*.weekly-usage.cache`；否則用 `readAtMs` 最新的一筆。
    static func load(directory: String) throws -> ProviderUsage {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ProviderError.noCredentials(missingCacheHint)
        }

        var slot: String?
        var caches: [(key: String, url: URL)] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "blob" else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard let key = decodePersistenceKey(stem) else { continue }
            if key == accountSlotKey {
                slot = readAccountSlot(url)
            } else if isWeeklyCacheKey(key) {
                caches.append((key, url))
            }
        }

        if let slot, !slot.isEmpty {
            caches = caches.filter { accountID(in: $0.key) == slot }
        }
        guard !caches.isEmpty else {
            throw ProviderError.noCredentials(missingCacheHint)
        }

        var best: Snapshot?
        var lastError: Error?
        for item in caches {
            do {
                let data = try Data(contentsOf: item.url)
                let snap = try parseWeeklyCache(data)
                if best == nil || snap.readAtMs >= best!.readAtMs {
                    best = snap
                }
            } catch {
                lastError = error
            }
        }
        if let best { return best.usage }
        throw lastError ?? ProviderError.noCredentials(missingCacheHint)
    }

    /// schemaVersion 2：`value.kind == present` 才有 `reading.usage`。
    /// `expiresAtMs` 過了仍回傳百分比；那只是 Grok Bot 下次會重抓的時間。
    static func parseWeeklyCache(_ data: Data) throws -> Snapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.apiChanged("Grok Bot 週用量快取不是 JSON。")
        }
        guard let value = root["value"] as? [String: Any] else {
            throw ProviderError.apiChanged("Grok Bot 週用量快取缺少 value。")
        }
        guard let kind = value["kind"] as? String else {
            throw ProviderError.apiChanged("Grok Bot 週用量快取缺少 kind。")
        }
        if kind != "present" {
            throw ProviderError.noCredentials(missingCacheHint)
        }
        guard let reading = value["reading"] as? [String: Any],
              let usageObj = reading["usage"] as? [String: Any] else {
            throw ProviderError.apiChanged("Grok Bot 週用量快取缺少 reading.usage。")
        }
        guard let percent = number(usageObj["percentUsed"]) else {
            throw ProviderError.apiChanged("Grok Bot 週用量快取缺少 percentUsed。")
        }

        let resetsAt = number(usageObj["nextResetMs"]).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        let readAt = number(reading["readAtMs"]) ?? 0
        let plan = (usageObj["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let measuredAt = readAt > 0 ? Date(timeIntervalSince1970: readAt / 1000) : Date()

        let usage = ProviderUsage(
            provider: .grokBot,
            buckets: [UsageBucket(
                key: "week",
                label: "win.week",
                usedPercent: clampPercent(percent),
                resetsAt: resetsAt,
                defaultOn: true
            )],
            plan: plan,
            error: nil,
            updatedAt: measuredAt
        )
        return Snapshot(usage: usage, readAtMs: readAt)
    }

    // MARK: - Persistence keys

    /// Grok Bot 用 RFC 4648 base32（無 padding、小寫）當 blob 檔名。
    static func encodePersistenceKey(_ key: String) -> String {
        base32Encode(Data(key.utf8))
    }

    static func decodePersistenceKey(_ stem: String) -> String? {
        guard let data = base32Decode(stem) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isWeeklyCacheKey(_ key: String) -> Bool {
        key.hasPrefix(accountKeyPrefix) && key.hasSuffix(cacheKeySuffix)
    }

    /// `sand.client.slice.account.grok%7C<id>.weekly-usage.cache` → `grok|<id>`。
    private static func accountID(in key: String) -> String? {
        guard isWeeklyCacheKey(key) else { return nil }
        let start = key.index(key.startIndex, offsetBy: accountKeyPrefix.count)
        let end = key.index(key.endIndex, offsetBy: -cacheKeySuffix.count)
        guard start < end else { return nil }
        let segment = String(key[start..<end])
        return segment.removingPercentEncoding ?? segment
    }

    private static func readAccountSlot(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["value"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func base32Encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt64 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = Int((buffer >> bits) & 0x1F)
                out.append(base32Alphabet[index])
            }
        }
        if bits > 0 {
            let index = Int((buffer << (5 - bits)) & 0x1F)
            out.append(base32Alphabet[index])
        }
        return out.lowercased()
    }

    private static func base32Decode(_ string: String) -> Data? {
        var map = [Character: UInt8](minimumCapacity: 32)
        for (i, c) in base32Alphabet.enumerated() {
            map[c] = UInt8(i)
        }
        var out = Data()
        var buffer: UInt64 = 0
        var bits = 0
        for ch in string.uppercased() where ch != "=" {
            guard let val = map[ch] else { return nil }
            buffer = (buffer << 5) | UInt64(val)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out
    }

    private static func number(_ value: Any?) -> Double? {
        if value == nil || value is NSNull { return nil }
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func clampPercent(_ p: Double) -> Double {
        max(0, min(100, p))
    }
}
