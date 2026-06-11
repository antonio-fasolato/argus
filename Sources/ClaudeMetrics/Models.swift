import Foundation

struct DailyActivity: Codable, Identifiable {
    var id: String { date }
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int

    var dateValue: Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date) ?? Date()
    }
}

struct ModelTokenStats: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let webSearchRequests: Int?
    let costUSD: Double?

    var totalTokens: Int { inputTokens + outputTokens }
    var totalWithCache: Int { totalTokens + cacheReadInputTokens + cacheCreationInputTokens }
}

struct DailyModelTokens: Codable, Identifiable {
    var id: String { date }
    let date: String
    let tokensByModel: [String: Int]

    var dateValue: Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date) ?? Date()
    }

    var totalTokens: Int { tokensByModel.values.reduce(0, +) }
}

struct LongestSessionInfo: Codable {
    let sessionId: String?
    let duration: Int?
    let messageCount: Int?
    let timestamp: String?
}

struct ProjectStats: Codable, Identifiable {
    var id: String { project }
    let project: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let webSearchRequests: Int
    let sessionCount: Int
    let messageCount: Int
    let estimatedCostUSD: Double
    let aiLinesWritten: Int    // lines written by AI via Write/Edit/MultiEdit tool_use
    let gitLinesAdded: Int     // total lines added in git history (all-time)

    var aiCodePct: Double {
        guard gitLinesAdded > 0 else { return 0 }
        return min(1.0, Double(aiLinesWritten) / Double(gitLinesAdded))
    }
}

struct DailyWorkHours: Codable, Identifiable {
    var id: String { date }
    let date: String
    let firstHour: Int
    let lastHour: Int
}

struct DailyModelBreakdown: Codable, Identifiable {
    var id: String { date }
    let date: String
    let modelTokens: [String: ModelTokenStats]
}

struct DailyProjectCosts: Codable, Identifiable {
    var id: String { date }
    let date: String
    let costs:       [String: Double]
    let outputs:     [String: Int]
    let messages:    [String: Int]
    let webSearches: [String: Int]
}

struct DailyAccountCosts: Codable, Identifiable {
    var id: String { date }
    let date: String
    let costs:    [String: Double]  // accountUuid → cost
    let messages: [String: Int]     // accountUuid → message count
}

struct DailySourceCosts: Codable, Identifiable {
    var id: String { date }
    let date: String
    let costs:    [String: Double]  // source ("claude_code" | "cowork") → cost
    let messages: [String: Int]     // source → message count
}

struct SourceCostBreakdown: Identifiable {
    var id: String { source }
    let source: String
    let costUSD: Double
    let messageCount: Int
}

struct DailyTokenTotals: Codable, Identifiable {
    var id: String { date }
    let date: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreateTokens: Int
    let webSearchCount: Int
    let estimatedCostUSD: Double
    let cacheSavingsUSD: Double
}

struct SessionSummary: Codable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let project: String
    let firstDay: String
    let messageCount: Int
    let outputTokens: Int
    let costUSD: Double
    let isSubagent: Bool
    let topModel: String
    let rating: Int?   // 1-5 from /rate skill, nil if not yet rated
}

struct SessionMessageDetail: Identifiable {
    var id: String { timestamp }
    let timestamp: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreateTokens: Int
    let webSearches: Int
    let costUSD: Double
    let aiLines: Int

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens }
    var formattedTime: String {
        guard timestamp.count >= 19 else { return timestamp }
        return String(timestamp[timestamp.index(timestamp.startIndex, offsetBy: 11)..<timestamp.index(timestamp.startIndex, offsetBy: 19)])
    }
}

struct StatsCache: Codable {
    let version: Int?
    let lastComputedDate: String?
    let dailyActivity: [DailyActivity]?
    let dailyModelTokens: [DailyModelTokens]?
    let modelUsage: [String: ModelTokenStats]?
    let totalSessions: Int?
    let totalMessages: Int?
    let longestSession: LongestSessionInfo?
    let firstSessionDate: String?
    let hourCounts: [String: Int]?
    let totalSpeculationTimeSavedMs: Int?
    // New fields
    let dailyCosts: [String: Double]?
    let projectStats: [ProjectStats]?
    let dailyWorkHours: [DailyWorkHours]?
    let subagentSessionCount: Int?
    let directSessionCount: Int?
    let avgOutputTokensPerSession: Int?
    let dailyTotals: [DailyTokenTotals]?
    let dailyModelBreakdown: [DailyModelBreakdown]?
    let dailyHourCounts: [String: [String: Int]]?
    let dailyProjectCosts: [DailyProjectCosts]?
    let sessions: [SessionSummary]?
    let subagentCostUSD: Double?
    let directCostUSD: Double?
    let accountCosts: [AccountCostBreakdown]?
    let knownAccountsList: [AccountInfo]?
    let knownProjectsList: [String]?
    let dailyAvgResponseTimeSec: [String: Double]?
    let dailyAccountCosts: [DailyAccountCosts]?
    let dailyHourCosts: [String: [String: Double]]?   // day → hour_str → cost_usd
    let latestMessageTimestamp: String?               // ISO8601 timestamp of most recent message
    let dailySourceCosts: [DailySourceCosts]?         // per-day cost/messages by ingestion source
    let knownSourcesList: [String]?                   // distinct sources seen in the DB
}

struct AccountInfo: Equatable, Codable, Identifiable {
    var id: String { accountUuid }
    let accountUuid: String
    let email: String
    let orgName: String
    let displayName: String
    let authType: String   // "oauth" | "api_key"

    var isOAuth: Bool { authType == "oauth" }
    var label: String { isOAuth ? (displayName.isEmpty ? email : displayName) : "API Key" }
    var subtitle: String { isOAuth ? orgName : "No OAuth account" }
}

struct AccountCostBreakdown: Codable, Identifiable {
    var id: String { accountUuid }
    let accountUuid: String
    let label: String
    let subtitle: String
    let authType: String
    let costUSD: Double
    let messageCount: Int
}

struct TokenChartPoint: Identifiable {
    var id: String { label }
    let label: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

struct ProjectAlertThreshold: Codable {
    let project: String
    var monthlyLimit: Double
}

// MARK: - Export

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv  = "CSV"
    case json = "JSON"
    var id: String { rawValue }
}

enum ExportDestination: Equatable {
    case localFolder
    case googleDrive(folderURL: String)
}

struct ModelPricingTable {
    struct Price {
        let inputPerMTok: Double
        let outputPerMTok: Double
        let cacheReadPerMTok: Double
        let cacheWritePerMTok: Double          // 5-minute ephemeral cache write (1.25× input)
        var cacheWrite1hPerMTok: Double? = nil // 1-hour ephemeral cache write; nil = API rule (2× input)

        var effectiveCacheWrite1hPerMTok: Double { cacheWrite1hPerMTok ?? inputPerMTok * 2.0 }

        func cost(for stats: ModelTokenStats) -> Double {
            Double(stats.inputTokens)                * inputPerMTok    / 1_000_000
            + Double(stats.outputTokens)             * outputPerMTok   / 1_000_000
            + Double(stats.cacheReadInputTokens)     * cacheReadPerMTok  / 1_000_000
            + Double(stats.cacheCreationInputTokens) * cacheWritePerMTok / 1_000_000
        }

        func cost(input: Int, output: Int, cr: Int, cc: Int) -> Double {
            Double(input)  * inputPerMTok    / 1_000_000
            + Double(output) * outputPerMTok   / 1_000_000
            + Double(cr)   * cacheReadPerMTok  / 1_000_000
            + Double(cc)   * cacheWritePerMTok / 1_000_000
        }

        func cost(input: Int, output: Int, cr: Int, cc5m: Int, cc1h: Int) -> Double {
            cost(input: input, output: output, cr: cr, cc: cc5m)
            + Double(cc1h) * effectiveCacheWrite1hPerMTok / 1_000_000
        }
    }

    static let table: [String: Price] = [
        "claude-fable-5":             Price(inputPerMTok: 10.0, outputPerMTok: 50.0, cacheReadPerMTok: 1.00,  cacheWritePerMTok: 12.50),
        "claude-opus-4-8":            Price(inputPerMTok: 5.0,  outputPerMTok: 25.0, cacheReadPerMTok: 0.50,  cacheWritePerMTok: 6.25),
        "claude-opus-4-7":            Price(inputPerMTok: 5.0,  outputPerMTok: 25.0, cacheReadPerMTok: 0.50,  cacheWritePerMTok: 6.25),
        "claude-opus-4-6":            Price(inputPerMTok: 5.0,  outputPerMTok: 25.0, cacheReadPerMTok: 0.50,  cacheWritePerMTok: 6.25),
        "claude-sonnet-4-6":          Price(inputPerMTok: 3.0,  outputPerMTok: 15.0, cacheReadPerMTok: 0.30,  cacheWritePerMTok: 3.75),
        "claude-sonnet-4-5-20250929": Price(inputPerMTok: 3.0,  outputPerMTok: 15.0, cacheReadPerMTok: 0.30,  cacheWritePerMTok: 3.75),
        "claude-haiku-4-5-20251001":  Price(inputPerMTok: 1.0,  outputPerMTok: 5.0,  cacheReadPerMTok: 0.10,  cacheWritePerMTok: 1.25),
    ]

    // External overrides loaded once from ~/.claude/argus_pricing.json
    // Format: { "model-id": { "inputPerMTok": 3.0, "outputPerMTok": 15.0, "cacheReadPerMTok": 0.30, "cacheWritePerMTok": 3.75 } }
    static var externalOverrides: [String: Price] = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/argus_pricing.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]]
        else { return [:] }
        var result: [String: Price] = [:]
        for (model, d) in json {
            guard let i = d["inputPerMTok"], let o = d["outputPerMTok"],
                  let cr = d["cacheReadPerMTok"], let cw = d["cacheWritePerMTok"]
            else { continue }
            result[model] = Price(inputPerMTok: i, outputPerMTok: o, cacheReadPerMTok: cr,
                                  cacheWritePerMTok: cw, cacheWrite1hPerMTok: d["cacheWrite1hPerMTok"])
        }
        return result
    }()

    static func price(for model: String) -> Price {
        if let p = externalOverrides[model] { return p }
        if let p = table[model] { return p }
        for (key, p) in externalOverrides {
            if model.hasPrefix(key.components(separatedBy: "-").prefix(3).joined(separator: "-")) { return p }
        }
        for (key, p) in table {
            if model.hasPrefix(key.components(separatedBy: "-").prefix(3).joined(separator: "-")) { return p }
        }
        return Price(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.30, cacheWritePerMTok: 3.75)
    }
}

// MARK: - Export builders (pure functions, shared by legacy + filtered export; unit-tested in Tests/)

func buildSessionsCSV(_ sessions: [SessionSummary]) -> String {
    var csv = "session_id,project,date,messages,output_tokens,cost_usd,is_subagent,model\n"
    for s in sessions {
        let row = "\"\(s.sessionId)\",\"\(s.project)\",\(s.firstDay),\(s.messageCount),\(s.outputTokens),\(s.costUSD),\(s.isSubagent ? 1 : 0),\"\(s.topModel)\"\n"
        csv += row
    }
    return csv
}

func buildSessionsJSON(_ sessions: [SessionSummary]) -> Data? {
    struct SessionExport: Encodable {
        let sessionId, project, firstDay, topModel: String
        let messageCount, outputTokens: Int
        let costUSD: Double
        let isSubagent: Bool
        let rating: Int?
    }
    let payload = sessions.map { s in
        SessionExport(sessionId: s.sessionId, project: s.project, firstDay: s.firstDay,
                      topModel: s.topModel, messageCount: s.messageCount,
                      outputTokens: s.outputTokens, costUSD: s.costUSD,
                      isSubagent: s.isSubagent, rating: s.rating)
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try? enc.encode(payload)
}
