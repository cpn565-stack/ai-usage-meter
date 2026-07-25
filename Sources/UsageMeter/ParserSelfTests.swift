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
        // 經典：5h + week（無 limit_window_seconds 時依 role 回退）
        let classic = Data("""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {"used_percent": 55.2, "reset_at": 1780000000},
            "secondary_window": {"used_percent": 8.0, "reset_at": 1780500000}
          }
        }
        """.utf8)
        let usage = try CodexProvider.parseUsageResponse(classic)

        try expect(usage.provider == .codex, "Codex provider mismatch")
        try expect(usage.plan == "Plus", "Codex plus plan display")
        try expect(usage.buckets.map(\.key) == ["5h", "week"], "Codex classic keys mismatch")
        try expect(usage.buckets.map(\.label) == ["win.5h", "win.week"], "Codex classic labels mismatch")
        try expect(Int(usage.buckets[0].usedPercent) == 55, "Codex percent mismatch")

        // 2026-07 現況：primary 變成週限（604800s）、secondary 為 null、used_percent 為整數、team→Business
        let weeklyOnly = Data("""
        {
          "plan_type": "team",
          "rate_limit": {
            "allowed": true,
            "primary_window": {
              "used_percent": 68,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 600112,
              "reset_at": 1784526349
            },
            "secondary_window": null
          },
          "code_review_rate_limit": null,
          "additional_rate_limits": null,
          "rate_limit_reset_credits": { "available_count": 2 }
        }
        """.utf8)
        let weekly = try CodexProvider.parseUsageResponse(weeklyOnly)
        try expect(weekly.buckets.count == 1, "Codex weekly-only should skip null secondary")
        try expect(weekly.buckets[0].key == "week", "Codex weekly primary key should be week not 5h")
        try expect(weekly.buckets[0].label == "win.week", "Codex weekly primary label")
        try expect(Int(weekly.buckets[0].usedPercent) == 68, "Codex int used_percent")
        try expect(weekly.plan == "Business", "Codex team plan displays as Business")
        try expect(weekly.planAccessory != nil, "Codex reset count accessory from usage")
        try expect(weekly.planAccessory?.contains("2") == true, "Codex reset accessory has count 2")

        let creditsJSON = Data("""
        {
          "available_count": 2,
          "credits": [
            {
              "status": "available",
              "expires_at": "2026-07-26T23:42:57.315815Z"
            },
            {
              "status": "available",
              "expires_at": "2026-07-31T19:53:38.459744Z"
            },
            {
              "status": "redeemed",
              "expires_at": "2026-07-01T00:00:00Z"
            }
          ]
        }
        """.utf8)
        let info = CodexProvider.parseResetCredits(creditsJSON)
        try expect(info.count == 2, "reset credits count")
        try expect(info.earliest != nil, "earliest expiry present")
        let badge = CodexProvider.formatResetAccessory(count: info.count, earliest: info.earliest, lang: .en)
        try expect(badge?.contains("2") == true, "badge has count")
        // 本地時區顯示（UTC 7/26 23:42 在 +8 為 7/27）
        try expect(badge?.contains("/") == true, "badge has date M/d")
        try expect(info.earliest! < Date(timeIntervalSince1970: 1_785_500_000), "earliest is first available credit")

        // 窗口長度推導
        let id5h = CodexProvider.windowIdentity(seconds: 18_000, role: "primary")
        try expect(id5h.key == "5h" && id5h.label == "win.5h", "5h window identity")
        let idWeek = CodexProvider.windowIdentity(seconds: 604_800, role: "primary")
        try expect(idWeek.key == "week" && idWeek.label == "win.week", "week window identity")
        let idDay = CodexProvider.windowIdentity(seconds: 86_400, role: "primary")
        try expect(idDay.key == "day" && idDay.label == "win.day", "day window identity")
        try expect(CodexProvider.displayPlan("team") == "Business", "team→Business")
    }

    private static func testGeminiModelsParsing() throws {
        // 官方 retrieveUserQuotaSummary 形狀（與 Antigravity Model Quota UI 一致）
        let summary = Data("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "description": "Models within this group: Gemini Flash, Gemini Pro",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit",
                  "window": "weekly",
                  "resetTime": "2026-07-29T02:58:22Z",
                  "remainingFraction": 0.8560178
                },
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit",
                  "window": "5h",
                  "resetTime": "2026-07-25T11:29:45Z",
                  "remainingFraction": 0.203997
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
              "buckets": [
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit",
                  "window": "weekly",
                  "resetTime": "2026-08-01T06:16:39Z",
                  "remainingFraction": 0.76366746
                },
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit",
                  "window": "5h",
                  "resetTime": "2026-07-25T11:16:39Z",
                  "remainingFraction": 0.3064544
                }
              ]
            }
          ]
        }
        """.utf8)
        let usage = try GeminiProvider.parseQuotaSummaryResponse(summary)
        try expect(usage.provider == .gemini, "Gemini provider mismatch")
        try expect(usage.plan == "Antigravity", "Gemini plan mismatch")
        // 官方順序：每組先週再 5h
        try expect(usage.buckets.map(\.key) == [
            "gemini.week", "gemini.5h", "partner.week", "partner.5h",
        ], "Gemini summary keys mismatch: \(usage.buckets.map(\.key))")
        try expect(usage.buckets.map(\.label) == [
            "gemini.bucket.gemini.week", "gemini.bucket.gemini.5h",
            "gemini.bucket.partner.week", "gemini.bucket.partner.5h",
        ], "Gemini summary labels mismatch")
        try expect(Int(usage.buckets[0].usedPercent.rounded()) == 14, "Gemini week used% (1-0.856)")
        try expect(Int(usage.buckets[1].usedPercent.rounded()) == 80, "Gemini 5h used% (1-0.204)")
        try expect(Int(usage.buckets[2].usedPercent.rounded()) == 24, "Partner week used%")
        try expect(Int(usage.buckets[3].usedPercent.rounded()) == 69, "Partner 5h used%")
        try expect(usage.buckets.allSatisfy(\.defaultOn), "Gemini buckets should default on")

        // 退回路徑：fetchAvailableModels 歸兩池
        let fiveHourReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600))
        let modelsData = Data("""
        {
          "models": {
            "gemini-3-flash": {
              "displayName": "Gemini 3 Flash",
              "modelProvider": "MODEL_PROVIDER_GOOGLE",
              "apiProvider": "API_PROVIDER_GOOGLE_GEMINI",
              "quotaInfo": {"remainingFraction": 0.25, "resetTime": "\(fiveHourReset)"}
            },
            "claude-opus-4-6-thinking": {
              "displayName": "Claude Opus 4.6",
              "modelProvider": "MODEL_PROVIDER_ANTHROPIC",
              "apiProvider": "API_PROVIDER_ANTHROPIC_VERTEX",
              "quotaInfo": {"remainingFraction": 0.40, "resetTime": "\(fiveHourReset)"}
            },
            "tab_flash_lite_preview": {
              "displayName": "Tab",
              "modelProvider": "MODEL_PROVIDER_GOOGLE",
              "quotaInfo": {"remainingFraction": 1.0}
            }
          }
        }
        """.utf8)
        let fallback = try GeminiProvider.parseModelsResponse(modelsData)
        try expect(fallback.buckets.map(\.key) == ["gemini.5h", "partner.5h"],
                   "Gemini models fallback keys: \(fallback.buckets.map(\.key))")
        try expect(Int(fallback.buckets[0].usedPercent.rounded()) == 75, "fallback gemini %")
        try expect(Int(fallback.buckets[1].usedPercent.rounded()) == 60, "fallback partner %")
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
              {"product": "Other", "usagePercent": 2.0},
              {"product": "GrokPlugins"}
            ],
            "isUnifiedBillingUser": true
          }
        }
        """.utf8)
        let usage = try GrokProvider.parseBillingResponse(data)

        try expect(usage.provider == .grok, "Grok provider mismatch")
        try expect(usage.plan == "SuperGrok", "Grok plan mismatch")
        // GrokPlugins 省略 usagePercent → 0%，仍入 bucket（defaultOff）
        try expect(usage.buckets.map(\.key) == ["week", "chat", "build", "imagine", "other", "plugins"],
                   "Grok buckets mismatch")
        try expect(Int(usage.buckets[0].usedPercent) == 23, "Grok total percent mismatch")
        try expect(Int(usage.buckets[1].usedPercent) == 12, "Grok chat percent mismatch")
        try expect(Int(usage.buckets[2].usedPercent) == 7, "Grok build percent mismatch")
        try expect(Int(usage.buckets[3].usedPercent) == 4, "Grok imagine percent mismatch")
        try expect(Int(usage.buckets[4].usedPercent) == 2, "Grok other percent mismatch")
        try expect(usage.buckets[4].label == "grok.other", "Grok other label key mismatch")
        try expect(usage.buckets[4].defaultOn == false, "Grok other should default off")
        try expect(usage.buckets[5].usedPercent == 0, "Grok plugins missing % → 0")
        try expect(usage.buckets[0].resetsAt != nil, "Grok reset date missing")

        // 別名相容:API 若回 GrokOther 也應對到 other
        let alias = Data("""
        {
          "config": {
            "creditUsagePercent": 10.0,
            "productUsage": [
              {"product": "GrokOther", "usagePercent": 3.0}
            ]
          }
        }
        """.utf8)
        let aliased = try GrokProvider.parseBillingResponse(alias)
        try expect(aliased.buckets.map(\.key) == ["week", "other"], "GrokOther alias keys mismatch")
        try expect(Int(aliased.buckets[1].usedPercent) == 3, "GrokOther alias percent mismatch")

        // 產品省略 usagePercent；嵌套 config
        let sparse = Data("""
        {
          "config": {
            "creditUsagePercent": 1.0,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "end": "2026-07-21T09:45:40.978386+00:00"
            },
            "productUsage": [
              {"product": "GrokBuild", "usagePercent": 1.0},
              {"product": "GrokChat"}
            ],
            "isUnifiedBillingUser": true
          }
        }
        """.utf8)
        let sparseUsage = try GrokProvider.parseBillingResponse(sparse)
        try expect(sparseUsage.buckets.contains(where: { $0.key == "chat" && $0.usedPercent == 0 }),
                   "GrokChat missing usagePercent → 0")
        try expect(Int(sparseUsage.buckets.first(where: { $0.key == "week" })?.usedPercent ?? -1) == 1,
                   "nested config total percent")

        // API 空殼 null：仍顯示週 0%，不當 API 錯誤
        let nullShell = Data("""
        {
          "creditUsagePercent": null,
          "productUsage": null,
          "currentPeriod": {
            "type": "USAGE_PERIOD_TYPE_WEEKLY",
            "end": "2026-07-21T09:45:40.978386+00:00"
          },
          "isUnifiedBillingUser": true
        }
        """.utf8)
        let nullUsage = try GrokProvider.parseBillingResponse(nullShell)
        try expect(nullUsage.buckets.count == 1 && nullUsage.buckets[0].key == "week",
                   "null credits with period → week bucket")
        try expect(nullUsage.buckets[0].usedPercent == 0, "null credits → 0%")
        try expect(nullUsage.plan == "SuperGrok", "null shell still SuperGrok")
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
