import Foundation

enum ParserSelfTests {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func run() throws -> [String] {
        try testClaudeUsageParsing()
        try testClaudeLimitsListParsing()
        try testCodexUsageParsing()
        try testGeminiModelsParsing()
        try testGrokBillingParsing()
        try testUnexpectedShapeIsApiChanged()
        return [
            "✓ Claude parser fixture",
            "✓ Claude limits list fixture",
            "✓ Codex parser fixture",
            "✓ Gemini parser fixture",
            "✓ Grok billing fixture",
            "✓ Unexpected shape reports API change",
        ]
    }

    private static func testClaudeUsageParsing() throws {
        let data = Data("""
        {
          "five_hour": {"utilization": 42.4, "resets_at": "2026-06-30T12:00:00Z"},
          "seven_day": {"utilization": 12.0, "resets_at": "2026-07-01T12:00:00Z"}
        }
        """.utf8)
        let usage = try ClaudeProvider.parseUsageResponse(data, tokenCache: [
            "client:claude_code": ["rateLimitTier": "max_5x"]
        ])

        try expect(usage.provider == .claude, "Claude provider mismatch")
        try expect(usage.plan == "Max 5x", "Claude plan mismatch")
        try expect(usage.buckets.count == 2, "Claude bucket count mismatch")
        try expect(usage.buckets.first?.key == "5h", "Claude first bucket mismatch")
        try expect(Int(usage.buckets.first?.usedPercent ?? 0) == 42, "Claude percent mismatch")
    }

    private static func testClaudeLimitsListParsing() throws {
        let data = Data("""
        {
          "limits": [
            {
              "kind": "session",
              "group": "session",
              "percent": 16,
              "resets_at": "2026-07-02T04:30:00.262392+00:00",
              "scope": null
            },
            {
              "kind": "weekly_all",
              "group": "weekly",
              "percent": 2,
              "resets_at": "2026-07-03T10:00:00.262416+00:00",
              "scope": null
            },
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 3,
              "resets_at": "2026-07-03T10:00:00.262741+00:00",
              "scope": {
                "model": {"display_name": "Fable", "id": null},
                "surface": null
              }
            }
          ],
          "five_hour": {"utilization": 99, "resets_at": "2026-07-02T04:30:00Z"},
          "seven_day": {"utilization": 88, "resets_at": "2026-07-03T10:00:00Z"}
        }
        """.utf8)
        let usage = try ClaudeProvider.parseUsageResponse(data, tokenCache: [:])

        try expect(usage.buckets.map(\.key) == ["5h", "week", "weekly.fable"], "Claude limits keys mismatch")
        try expect(usage.buckets.map(\.label) == ["win.5h", "win.week", "Fable"], "Claude limits labels mismatch")
        try expect(Int(usage.buckets[2].usedPercent) == 3, "Claude Fable percent mismatch")
        try expect(usage.buckets[2].defaultOn, "Claude Fable should default on")
    }

    private static func testCodexUsageParsing() throws {
        let data = Data("""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {"used_percent": 55.2, "reset_at": 1780000000},
            "secondary_window": {"used_percent": 8.0, "reset_at": 1780500000}
          }
        }
        """.utf8)
        let usage = try CodexProvider.parseUsageResponse(data)

        try expect(usage.provider == .codex, "Codex provider mismatch")
        try expect(usage.plan == "plus", "Codex plan mismatch")
        try expect(usage.buckets.map(\.key) == ["5h", "week"], "Codex buckets mismatch")
        try expect(Int(usage.buckets[0].usedPercent) == 55, "Codex percent mismatch")
    }

    private static func testGeminiModelsParsing() throws {
        let data = Data("""
        {
          "models": {
            "gemini-a": {
              "displayName": "Gemini A",
              "recommended": true,
              "quotaInfo": {"remainingFraction": 0.25, "resetTime": "2026-06-30T12:00:00Z"}
            },
            "gemini-a-copy": {
              "displayName": "Gemini A",
              "recommended": false,
              "quotaInfo": {"remainingFraction": 0.10}
            },
            "gemini-b": {
              "displayName": "Gemini B",
              "quotaInfo": {"remainingFraction": 0.80}
            }
          }
        }
        """.utf8)
        let usage = try GeminiProvider.parseModelsResponse(data)

        try expect(usage.provider == .gemini, "Gemini provider mismatch")
        try expect(usage.plan == "Antigravity", "Gemini plan mismatch")
        try expect(usage.buckets.map(\.label) == ["Gemini A", "Gemini B"], "Gemini labels mismatch")
        try expect(Int(usage.buckets[0].usedPercent) == 75, "Gemini percent mismatch")
        try expect(usage.buckets[0].defaultOn, "Gemini recommended flag mismatch")
    }

    private static func testGrokBillingParsing() throws {
        let data = Data("""
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-07-07T09:45:40.978386+00:00",
              "end": "2026-07-14T09:45:40.978386+00:00"
            },
            "creditUsagePercent": 23.0,
            "productUsage": [
              {"product": "GrokChat", "usagePercent": 12.0},
              {"product": "GrokBuild", "usagePercent": 7.0},
              {"product": "GrokImagine", "usagePercent": 4.0},
              {"product": "GrokPlugins"}
            ],
            "isUnifiedBillingUser": true
          }
        }
        """.utf8)
        let usage = try GrokProvider.parseBillingResponse(data)

        try expect(usage.provider == .grok, "Grok provider mismatch")
        try expect(usage.plan == "SuperGrok", "Grok plan mismatch")
        try expect(usage.buckets.map(\.key) == ["week", "chat", "build", "imagine"], "Grok buckets mismatch")
        try expect(Int(usage.buckets[0].usedPercent) == 23, "Grok total percent mismatch")
        try expect(Int(usage.buckets[1].usedPercent) == 12, "Grok chat percent mismatch")
        try expect(Int(usage.buckets[2].usedPercent) == 7, "Grok build percent mismatch")
        try expect(Int(usage.buckets[3].usedPercent) == 4, "Grok imagine percent mismatch")
        try expect(usage.buckets[0].resetsAt != nil, "Grok reset date missing")
    }

    private static func testUnexpectedShapeIsApiChanged() throws {
        do {
            _ = try CodexProvider.parseUsageResponse(Data("{}".utf8))
        } catch ProviderError.apiChanged {
            return
        } catch {
            throw Failure(message: "Unexpected error type: \(error.localizedDescription)")
        }
        throw Failure(message: "Expected API changed error")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
