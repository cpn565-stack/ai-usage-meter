import Foundation

enum Net {
    /// 非同步 GET,回傳 (狀態碼, body)。
    static func get(_ urlString: String, headers: [String: String]) async throws -> (Int, Data) {
        try await send(urlString, method: "GET", headers: headers, body: nil)
    }

    /// 非同步 POST(JSON),回傳 (狀態碼, body)。
    static func postJSON(_ urlString: String, headers: [String: String], body: [String: Any]) async throws -> (Int, Data) {
        var h = headers
        h["Content-Type"] = "application/json"
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(urlString, method: "POST", headers: h, body: data)
    }

    /// 非同步 POST(x-www-form-urlencoded)。
    static func postForm(_ urlString: String, form: [String: String]) async throws -> (Int, Data) {
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = (comps.percentEncodedQuery ?? "").data(using: .utf8)
        return try await send(urlString, method: "POST",
                              headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body)
    }

    private static func send(_ urlString: String, method: String, headers: [String: String], body: Data?) async throws -> (Int, Data) {
        guard let url = URL(string: urlString) else { throw ProviderError.parse("URL 無效") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 25
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return (code, data)
    }
}

extension Date {
    /// 解析 ISO8601(含小數秒)字串。
    static func fromISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
