// ArgusAI unit tests — pure logic only (pricing, export builders, formatters).
// Run with: bash Tests/run_tests.sh
// Compiled standalone with swiftc (no SPM/XCTest): keep dependencies limited to
// Models.swift + Theme.swift.

import Foundation

var failures = 0

func expect(_ condition: Bool, _ message: String,
            file: String = #file, line: Int = #line) {
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)  (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                               file: String = #file, line: Int = #line) {
    expect(actual == expected, "\(message) — expected \(expected), got \(actual)",
           file: file, line: line)
}

func expectClose(_ actual: Double, _ expected: Double, _ message: String,
                 tolerance: Double = 1e-9, file: String = #file, line: Int = #line) {
    expect(abs(actual - expected) < tolerance,
           "\(message) — expected \(expected), got \(actual)", file: file, line: line)
}

// MARK: - ModelPricingTable.Price.cost

print("Price.cost")
let sonnet = ModelPricingTable.Price(inputPerMTok: 3.0, outputPerMTok: 15.0,
                                     cacheReadPerMTok: 0.30, cacheWritePerMTok: 3.75)
expectClose(sonnet.cost(input: 1_000_000, output: 0, cr: 0, cc: 0), 3.0,
            "1M input tokens at $3/MTok")
expectClose(sonnet.cost(input: 0, output: 1_000_000, cr: 0, cc: 0), 15.0,
            "1M output tokens at $15/MTok")
expectClose(sonnet.cost(input: 0, output: 0, cr: 2_000_000, cc: 0), 0.60,
            "2M cache-read tokens at $0.30/MTok")
expectClose(sonnet.cost(input: 0, output: 0, cr: 0, cc: 400_000), 1.50,
            "400K cache-write tokens at $3.75/MTok")
expectClose(sonnet.cost(input: 100_000, output: 50_000, cr: 1_000_000, cc: 200_000),
            0.3 + 0.75 + 0.30 + 0.75, "mixed token cost")
expectClose(sonnet.cost(input: 0, output: 0, cr: 0, cc: 0), 0, "zero tokens cost zero")

let bigStats = ModelTokenStats(inputTokens: 1_000_000_000, outputTokens: 1_000_000_000,
                               cacheReadInputTokens: 1_000_000_000,
                               cacheCreationInputTokens: 1_000_000_000,
                               webSearchRequests: 0, costUSD: nil)
expectClose(sonnet.cost(for: bigStats), 1000 * (3.0 + 15.0 + 0.30 + 3.75),
            "1B tokens of each type — no overflow, both overloads agree",
            tolerance: 1e-6)
expectClose(sonnet.cost(for: bigStats),
            sonnet.cost(input: 1_000_000_000, output: 1_000_000_000,
                        cr: 1_000_000_000, cc: 1_000_000_000),
            "cost(for:) matches cost(input:output:cr:cc:)")

// MARK: - ModelPricingTable.price(for:) lookup

print("ModelPricingTable.price(for:)")
// Neutralize the user's ~/.claude/argus_pricing.json so lookups are deterministic
ModelPricingTable.externalOverrides = [:]

let exact = ModelPricingTable.price(for: "claude-sonnet-4-6")
expectClose(exact.inputPerMTok, 3.0, "exact table match: sonnet input price")

let prefixed = ModelPricingTable.price(for: "claude-opus-4-6-20260101")
expectClose(prefixed.outputPerMTok, 75.0, "prefix fallback: dated opus id resolves to opus price")

let unknown = ModelPricingTable.price(for: "some-future-model")
expectClose(unknown.inputPerMTok, 3.0, "unknown model falls back to sonnet-tier default")
expectClose(unknown.outputPerMTok, 15.0, "unknown model default output price")

ModelPricingTable.externalOverrides = ["claude-sonnet-4-6":
    ModelPricingTable.Price(inputPerMTok: 1.0, outputPerMTok: 2.0,
                            cacheReadPerMTok: 0.1, cacheWritePerMTok: 0.5)]
expectClose(ModelPricingTable.price(for: "claude-sonnet-4-6").inputPerMTok, 1.0,
            "external override takes precedence over built-in table")
ModelPricingTable.externalOverrides = [:]

// MARK: - Export builders

print("buildSessionsCSV / buildSessionsJSON")
let sessions = [
    SessionSummary(sessionId: "s1", project: "argus", firstDay: "2026-06-01",
                   messageCount: 10, outputTokens: 1234, costUSD: 0.5,
                   isSubagent: false, topModel: "claude-sonnet-4-6", rating: 4),
    SessionSummary(sessionId: "s2", project: "other", firstDay: "2026-06-02",
                   messageCount: 3, outputTokens: 99, costUSD: 0.01,
                   isSubagent: true, topModel: "claude-haiku-4-5-20251001", rating: nil),
]

let csv = buildSessionsCSV(sessions)
let csvLines = csv.split(separator: "\n")
expectEqual(csvLines.count, 3, "CSV has header + one row per session")
expectEqual(String(csvLines[0]),
            "session_id,project,date,messages,output_tokens,cost_usd,is_subagent,model",
            "CSV header")
expect(csvLines[1].contains("\"s1\",\"argus\",2026-06-01,10,1234,0.5,0"),
       "CSV row carries session fields")
expect(csvLines[2].contains(",1,"), "subagent flag serialized as 1")
expectEqual(buildSessionsCSV([]).split(separator: "\n").count, 1,
            "empty export still emits header")

if let jsonData = buildSessionsJSON(sessions),
   let decoded = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
    expectEqual(decoded.count, 2, "JSON has one object per session")
    expectEqual(decoded[0]["sessionId"] as? String, "s1", "JSON sessionId")
    expectEqual(decoded[0]["rating"] as? Int, 4, "JSON rating present when set")
    expect(decoded[1]["rating"] == nil || decoded[1]["rating"] is NSNull,
           "JSON rating omitted when nil")
    expectEqual(decoded[1]["isSubagent"] as? Bool, true, "JSON subagent flag")
} else {
    expect(false, "buildSessionsJSON produced decodable output")
}

// MARK: - Formatters

print("formatTokens / formatCost / modelDisplayName")
expectEqual(formatTokens(999), "999", "below 1K stays raw")
expectEqual(formatTokens(1_500), "1.5K", "thousands")
expectEqual(formatTokens(2_500_000), "2.5M", "millions")
expectEqual(formatTokens(1_200_000_000), "1.2B", "billions")

expectEqual(formatCost(5.0), "$5.00", "dollars with two decimals")
expectEqual(formatCost(0.5), "$0.500", "sub-dollar with three decimals")
expectEqual(formatCost(0.0005), "$0.0005", "sub-millidollar with four decimals")
expectEqual(formatCost(1500), "$1.5K", "thousands of dollars")

expectEqual(modelDisplayName("claude-sonnet-4-5-20250929"), "Sonnet 4 5",
            "date suffix stripped, words capitalized")
expectEqual(modelDisplayName("claude-opus-4-6"), "Opus 4 6", "plain model id")

// MARK: - Result

if failures > 0 {
    print("\n\(failures) test(s) FAILED")
    exit(1)
} else {
    print("\nAll tests passed ✓")
}
