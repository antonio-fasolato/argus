import Foundation
import Combine
import UserNotifications
import AppKit
import Security

enum DateFilter: String, CaseIterable {
    case today      = "Today"
    case sevenDays  = "7d"
    case thirtyDays = "30d"
    case all        = "All"
    case custom     = "Custom"

    static let presets: [DateFilter] = [.today, .sevenDays, .thirtyDays, .all]
}

class MetricsStore: ObservableObject {
    // Keychain reads trigger a macOS permission dialog on every access when
    // the app isn't persistently authorized. Cache the result for the session
    // so we hit the keychain only once (API keys don't change during a run).
    private var _keychainKeyCache: (attempted: Bool, key: String?) = (false, nil)

    @Published var stats: StatsCache?
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastRefresh: Date?
    @Published var dateFilter: DateFilter = .all
    @Published var customStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @Published var customEndDate: Date = Date()
    @Published var sessionSearchText: String = ""
    @Published var sessionDisplayLimit: Int = 100
    @Published var alertThreshold: Double = UserDefaults.standard.double(forKey: "argusai.alertThreshold") {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: "argusai.alertThreshold") }
    }
    @Published var currentAccount: AccountInfo?
    @Published var accountFilter: String? = nil {
        didSet { if oldValue != accountFilter { loadData(silent: true) } }
    }
    @Published var knownAccounts: [AccountInfo] = []
    @Published var projectFilter: String? = nil {
        didSet { if oldValue != projectFilter { loadData(silent: true) } }
    }
    @Published var knownProjects: [String] = []
    @Published var showingExport: Bool = false
    // Cumulative (per app session) counts of data skipped during ingestion —
    // shown as a warning in the sidebar footer so partial ingest isn't silent
    @Published var ingestSkippedLines: Int = 0
    @Published var ingestUnreadableFiles: Int = 0
    let drive = GoogleDriveService()
    @Published var projectAlertThresholds: [String: Double] = {
        guard let data = UserDefaults.standard.data(forKey: "argusai.projectAlertThresholds"),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return decoded
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(projectAlertThresholds) {
                UserDefaults.standard.set(data, forKey: "argusai.projectAlertThresholds")
            }
        }
    }

    private let projectsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects")

    private var refreshTimer: Timer?
    private var lastParseDate: Date = .distantPast
    private var parsing = false
    private var initialLoadDone = false
    private let parseQueue = DispatchQueue(label: "com.claudemetrics.parse", qos: .userInitiated)

    private let db: ArgusDB? = {
        let dbURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/argusai.db")
        return try? ArgusDB(path: dbURL.path)
    }()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        loadData()
        scheduleAutoRefresh()
    }

    deinit { refreshTimer?.invalidate() }

    private func scheduleAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkAndRefreshIfNeeded()
        }
    }

    private func checkAndRefreshIfNeeded() {
        let threshold = lastParseDate
        parseQueue.async { [weak self] in
            guard let self else { return }
            let changed = self.findJSONLFiles().contains { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate).map { $0 > threshold } ?? false
            }
            if changed {
                DispatchQueue.main.async { self.loadData(silent: true) }
            }
        }
    }

    func loadData(silent: Bool = false) {
        guard !parsing else { return }
        parsing = true
        if !silent || !initialLoadDone { isLoading = true }
        error = nil
        let startTime = Date()
        parseQueue.async { [weak self] in
            guard let self else { return }
            do {
                let cache = try self.buildStatsFromDB()
                DispatchQueue.main.async {
                    self.stats = cache
                    self.isLoading = false
                    self.lastRefresh = Date()
                    self.lastParseDate = startTime
                    self.parsing = false
                    self.initialLoadDone = true
                    self.checkAlerts()
                    self.scheduleWeeklySummaryIfNeeded()
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.isLoading = false
                    self.parsing = false
                }
            }
        }
    }

    // MARK: - File discovery

    private func findJSONLFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    // MARK: - Account

    // Mirrors Claude Code's actual auth priority order:
    // env ANTHROPIC_API_KEY > apiKeyHelper > Keychain API key > OAuth > fallback
    func readCurrentAccount() -> AccountInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. ANTHROPIC_API_KEY env var — highest priority, overrides everything including OAuth
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return apiKeyAccountInfo(from: key, source: "Env")
        }

        // 2. apiKeyHelper in ~/.claude/settings.json
        let settings = home.appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: settings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let helper = json["apiKeyHelper"] as? String, !helper.isEmpty {
            return AccountInfo(
                accountUuid: "api_key_helper_\(abs(helper.hash))",
                email: "",
                orgName: "",
                displayName: "API Key (helper)",
                authType: "api_key"
            )
        }

        // 3. API key stored in Keychain via /config (starts with "sk-ant-")
        if let key = readKeychainAPIKey(), !key.isEmpty {
            return apiKeyAccountInfo(from: key, source: "Keychain")
        }

        // 4. OAuth account from ~/.claude.json
        let claudeJson = home.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: claudeJson),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["oauthAccount"] as? [String: Any],
           let uuid = oauth["accountUuid"] as? String, !uuid.isEmpty {
            return AccountInfo(
                accountUuid: uuid,
                email: oauth["emailAddress"] as? String ?? "",
                orgName: oauth["organizationName"] as? String ?? "",
                displayName: oauth["displayName"] as? String ?? "",
                authType: "oauth"
            )
        }

        // 5. Fallback — no auth detected
        return AccountInfo(
            accountUuid: "api_key_user",
            email: "",
            orgName: "",
            displayName: "API Key",
            authType: "api_key"
        )
    }

    private func readKeychainAPIKey() -> String? {
        if _keychainKeyCache.attempted { return _keychainKeyCache.key }
        var found: String? = nil
        for service in ["Claude Code", "Claude Code-credentials"] {
            let query: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String:  true,
                kSecMatchLimit as String:  kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let key = String(data: data, encoding: .utf8),
               key.hasPrefix("sk-") {
                found = key
                break
            }
        }
        _keychainKeyCache = (true, found)
        return found
    }

    private func apiKeyAccountInfo(from key: String, source: String) -> AccountInfo {
        let suffix = String(key.suffix(8))
        // Stable UUID derived from key suffix (not reversible to the full key)
        let uuid = "api_key_\(suffix)"
        return AccountInfo(
            accountUuid: uuid,
            email: "",
            orgName: source,
            displayName: "API Key (…\(suffix))",
            authType: "api_key"
        )
    }

    // MARK: - DB-backed build

    private func buildStatsFromDB() throws -> StatsCache {
        guard let db = db else { throw NSError(domain: "ArgusDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database unavailable"]) }
        let account = readCurrentAccount()
        let currentFilter = accountFilter
        DispatchQueue.main.async { self.currentAccount = account }
        let files = findJSONLFiles().map { url in
            (url: url, isSubagent: url.pathComponents.contains("subagents"))
        }
        // One-shot: claim all historical NULL messages for the current account
        let claimKey = "argusai.historicalClaimDone"
        if !UserDefaults.standard.bool(forKey: claimKey), let uuid = account?.accountUuid {
            try db.claimHistoricalMessages(for: uuid)
            UserDefaults.standard.set(true, forKey: claimKey)
        }

        let ingestReport = try db.ingestFiles(files, account: account)
        if !ingestReport.isEmpty {
            DispatchQueue.main.async {
                self.ingestSkippedLines += ingestReport.malformedLines
                self.ingestUnreadableFiles += ingestReport.unreadableFiles
            }
        }
        let feedbackURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/argusai_feedback.jsonl")
        try? db.ingestFeedback(at: feedbackURL)
        // One-shot: backfill ai_lines (v2 = includes Bash heredoc writes)
        let aiBackfillKey = "argusai.aiLinesBackfillDone.v2"
        if !UserDefaults.standard.bool(forKey: aiBackfillKey) {
            try? db.backfillAiLines()
            UserDefaults.standard.set(true, forKey: aiBackfillKey)
        }
        db.accountFilter = currentFilter
        db.projectFilter = projectFilter
        let cache = try db.buildStatsCache()
        if let accounts = cache.knownAccountsList {
            DispatchQueue.main.async { self.knownAccounts = accounts }
        }
        if let projects = cache.knownProjectsList {
            DispatchQueue.main.async { self.knownProjects = projects }
        }
        return cache
    }

    // MARK: - LEGACY (unused — DB path is authoritative)
    /* keeping Accumulator + buildStatsFromJSONL below for reference only
    private struct Accumulator {
        // Token stats per model
        var modelTokens: [String: (input: Int, output: Int, cacheRead: Int, cacheCreate: Int, webSearch: Int)] = [:]
        // Daily activity
        var dailyMessages: [String: Int] = [:]
        var dailySessions: [String: Set<String>] = [:]
        var dailyToolCalls: [String: Int] = [:]
        // Per-day per-model full tokens — tuple: (input, output, cr, cc, ws)
        var dailyModelFull: [String: [String: (input: Int, output: Int, cr: Int, cc: Int, ws: Int)]] = [:]
        // Hour distribution
        var hourCounts: [Int: Int] = [:]
        // Session tracking
        var allSessions: Set<String> = []
        var sessionMsgCounts: [String: Int] = [:]
        var sessionOutputTokens: [String: Int] = [:]
        var sessionCwds: [String: String] = [:]
        // Project tracking: project → model → tokens
        var projectModelTokens: [String: [String: (input: Int, output: Int, cr: Int, cc: Int, ws: Int)]] = [:]
        var projectSessions: [String: Set<String>] = [:]
        var projectMessages: [String: Int] = [:]
        // Work hours per day
        var dailyWorkHours: [String: (first: Int, last: Int)] = [:]
        // Per-day hourly counts: day -> hour -> count
        var dailyHours: [String: [Int: Int]] = [:]
        // Per-day per-project data
        var dailyProjOutput:     [String: [String: Int]]    = [:]
        var dailyProjCost:       [String: [String: Double]] = [:]
        var dailyProjMessages:   [String: [String: Int]]    = [:]
        var dailyProjWebSearches:[String: [String: Int]]    = [:]
        // Subagent vs direct
        var subagentSessions: Set<String> = []
        var directSessions: Set<String> = []
        // Timestamps
        var firstDate: Date?
        var lastDay: String?
    }

    private func buildStatsFromJSONL() throws -> StatsCache {
        let files = findJSONLFiles()
        var acc = Accumulator()
        let cal = Calendar.current

        let isoFrac  = ISO8601DateFormatter(); isoFrac.formatOptions  = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

        for fileURL in files {
            let isSubagent = fileURL.pathComponents.contains("subagents")

            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }

                let type      = obj["type"]      as? String ?? ""
                let sessionId = obj["sessionId"] as? String ?? ""
                let tsStr     = obj["timestamp"] as? String ?? ""
                let day       = tsStr.isEmpty ? nil : String(tsStr.prefix(10))

                // Record cwd for session (first occurrence wins)
                if acc.sessionCwds[sessionId] == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    acc.sessionCwds[sessionId] = cwd
                }

                if type == "assistant", let msg = obj["message"] as? [String: Any] {
                    let model  = msg["model"] as? String ?? "unknown"
                    let usage  = msg["usage"] as? [String: Any] ?? [:]
                    let input  = usage["input_tokens"]                as? Int ?? 0
                    let output = usage["output_tokens"]               as? Int ?? 0
                    let cr     = usage["cache_read_input_tokens"]     as? Int ?? 0
                    let cc     = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let wsTool = usage["server_tool_use"]             as? [String: Any]
                    let ws     = wsTool?["web_search_requests"]       as? Int ?? 0

                    guard input + output + cr + cc > 0 else { continue }

                    // Model-level aggregates
                    var t = acc.modelTokens[model] ?? (0, 0, 0, 0, 0)
                    t.input += input; t.output += output
                    t.cacheRead += cr; t.cacheCreate += cc; t.webSearch += ws
                    acc.modelTokens[model] = t

                    if let d = day {
                        // Daily messages + sessions
                        acc.dailyMessages[d] = (acc.dailyMessages[d] ?? 0) + 1
                        if acc.dailySessions[d] == nil { acc.dailySessions[d] = [] }
                        acc.dailySessions[d]!.insert(sessionId)
                        // Daily model full tokens
                        if acc.dailyModelFull[d] == nil { acc.dailyModelFull[d] = [:] }
                        var dm = acc.dailyModelFull[d]![model] ?? (0, 0, 0, 0, 0)
                        dm.0 += input; dm.1 += output; dm.2 += cr; dm.3 += cc; dm.4 += ws
                        acc.dailyModelFull[d]![model] = dm
                        if acc.lastDay == nil || d > acc.lastDay! { acc.lastDay = d }
                    }

                    if let date = parseDate(tsStr) {
                        let h = cal.component(.hour, from: date)
                        acc.hourCounts[h] = (acc.hourCounts[h] ?? 0) + 1
                        if acc.firstDate == nil || date < acc.firstDate! { acc.firstDate = date }
                        if let d = day {
                            if let existing = acc.dailyWorkHours[d] {
                                acc.dailyWorkHours[d] = (first: min(existing.first, h), last: max(existing.last, h))
                            } else {
                                acc.dailyWorkHours[d] = (first: h, last: h)
                            }
                            if acc.dailyHours[d] == nil { acc.dailyHours[d] = [:] }
                            acc.dailyHours[d]![h] = (acc.dailyHours[d]![h] ?? 0) + 1
                        }
                    }

                    // Session aggregates
                    acc.allSessions.insert(sessionId)
                    acc.sessionMsgCounts[sessionId]    = (acc.sessionMsgCounts[sessionId] ?? 0) + 1
                    acc.sessionOutputTokens[sessionId] = (acc.sessionOutputTokens[sessionId] ?? 0) + output
                    if isSubagent { acc.subagentSessions.insert(sessionId) }
                    else          { acc.directSessions.insert(sessionId) }

                    // Project aggregates
                    let proj = projectName(cwd: acc.sessionCwds[sessionId], fileURL: fileURL)
                    if acc.projectModelTokens[proj] == nil { acc.projectModelTokens[proj] = [:] }
                    var pm = acc.projectModelTokens[proj]![model] ?? (0, 0, 0, 0, 0)
                    pm.0 += input; pm.1 += output; pm.2 += cr; pm.3 += cc; pm.4 += ws
                    acc.projectModelTokens[proj]![model] = pm
                    if acc.projectSessions[proj] == nil { acc.projectSessions[proj] = [] }
                    acc.projectSessions[proj]!.insert(sessionId)
                    acc.projectMessages[proj] = (acc.projectMessages[proj] ?? 0) + 1

                    // Daily project data
                    if let d = day {
                        let msgCost = ModelPricingTable.price(for: model).cost(input: input, output: output, cr: cr, cc: cc)
                        if acc.dailyProjOutput[d]      == nil { acc.dailyProjOutput[d]      = [:] }
                        if acc.dailyProjCost[d]        == nil { acc.dailyProjCost[d]        = [:] }
                        if acc.dailyProjMessages[d]    == nil { acc.dailyProjMessages[d]    = [:] }
                        if acc.dailyProjWebSearches[d] == nil { acc.dailyProjWebSearches[d] = [:] }
                        acc.dailyProjOutput[d]![proj]      = (acc.dailyProjOutput[d]![proj]      ?? 0) + output
                        acc.dailyProjCost[d]![proj]        = (acc.dailyProjCost[d]![proj]        ?? 0) + msgCost
                        acc.dailyProjMessages[d]![proj]    = (acc.dailyProjMessages[d]![proj]    ?? 0) + 1
                        acc.dailyProjWebSearches[d]![proj] = (acc.dailyProjWebSearches[d]![proj] ?? 0) + ws
                    }
                }

                if type == "user", let msg = obj["message"] as? [String: Any], let d = day {
                    if let arr = msg["content"] as? [[String: Any]] {
                        let toolCount = arr.filter { $0["type"] as? String == "tool_result" }.count
                        if toolCount > 0 {
                            acc.dailyToolCalls[d] = (acc.dailyToolCalls[d] ?? 0) + toolCount
                        }
                    }
                }
            }
        }

        // MARK: Build StatsCache

        let modelUsage: [String: ModelTokenStats] = acc.modelTokens.mapValues {
            ModelTokenStats(inputTokens: $0.input, outputTokens: $0.output,
                            cacheReadInputTokens: $0.cacheRead, cacheCreationInputTokens: $0.cacheCreate,
                            webSearchRequests: $0.webSearch, costUSD: nil)
        }

        let allDays = Set(acc.dailyMessages.keys).union(acc.dailySessions.keys).union(acc.dailyToolCalls.keys)
        let dailyActivity: [DailyActivity] = allDays.map { d in
            DailyActivity(date: d,
                          messageCount: acc.dailyMessages[d] ?? 0,
                          sessionCount: acc.dailySessions[d]?.count ?? 0,
                          toolCallCount: acc.dailyToolCalls[d] ?? 0)
        }.sorted { $0.date < $1.date }

        let dailyModelTokens: [DailyModelTokens] = acc.dailyModelFull.map { d, modelMap in
            DailyModelTokens(date: d, tokensByModel: modelMap.mapValues { $0.1 })
        }.sorted { $0.date < $1.date }

        let hourCounts = Dictionary(uniqueKeysWithValues: acc.hourCounts.map { ("\($0.key)", $0.value) })

        let longestSession: LongestSessionInfo? = acc.sessionMsgCounts
            .max(by: { $0.value < $1.value })
            .map { LongestSessionInfo(sessionId: $0.key, duration: nil, messageCount: $0.value, timestamp: nil) }

        let firstDateStr: String? = acc.firstDate.map {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: $0)
        }

        // Daily costs + full daily token totals (enables date-filtered KPIs)
        let dailyCosts: [String: Double] = acc.dailyModelFull.mapValues { modelMap in
            modelMap.reduce(0.0) { cost, pair in
                cost + ModelPricingTable.price(for: pair.key).cost(
                    input: pair.value.0, output: pair.value.1, cr: pair.value.2, cc: pair.value.3)
            }
        }

        let dailyTotals: [DailyTokenTotals] = acc.dailyModelFull.map { d, modelMap in
            let totInput  = modelMap.values.reduce(0) { $0 + $1.0 }
            let totOutput = modelMap.values.reduce(0) { $0 + $1.1 }
            let totCR     = modelMap.values.reduce(0) { $0 + $1.2 }
            let totCC     = modelMap.values.reduce(0) { $0 + $1.3 }
            let totWS     = modelMap.values.reduce(0) { $0 + $1.4 }
            let cost    = dailyCosts[d] ?? 0
            let savings = modelMap.reduce(0.0) { s, pair in
                let price = ModelPricingTable.price(for: pair.key)
                let cr = Double(pair.value.2)
                return s + max(0, cr * (price.inputPerMTok - price.cacheReadPerMTok) / 1_000_000)
            }
            return DailyTokenTotals(date: d, inputTokens: totInput, outputTokens: totOutput,
                                    cacheReadTokens: totCR, cacheCreateTokens: totCC,
                                    webSearchCount: totWS, estimatedCostUSD: cost, cacheSavingsUSD: savings)
        }.sorted { $0.date < $1.date }

        // Project stats
        let projectStats: [ProjectStats] = acc.projectModelTokens.map { proj, modelMap in
            let totInput  = modelMap.values.reduce(0) { $0 + $1.0 }
            let totOutput = modelMap.values.reduce(0) { $0 + $1.1 }
            let totCR     = modelMap.values.reduce(0) { $0 + $1.2 }
            let totCC     = modelMap.values.reduce(0) { $0 + $1.3 }
            let totWS     = modelMap.values.reduce(0) { $0 + $1.4 }
            let cost = modelMap.reduce(0.0) { c, pair in
                c + ModelPricingTable.price(for: pair.key).cost(
                    input: pair.value.0, output: pair.value.1, cr: pair.value.2, cc: pair.value.3)
            }
            return ProjectStats(project: proj,
                                inputTokens: totInput, outputTokens: totOutput,
                                cacheReadInputTokens: totCR, cacheCreationInputTokens: totCC,
                                webSearchRequests: totWS,
                                sessionCount: acc.projectSessions[proj]?.count ?? 0,
                                messageCount: acc.projectMessages[proj] ?? 0,
                                estimatedCostUSD: cost)
        }.sorted { $0.estimatedCostUSD > $1.estimatedCostUSD }

        // Daily work hours
        let dailyWorkHours: [DailyWorkHours] = acc.dailyWorkHours.map { d, range in
            DailyWorkHours(date: d, firstHour: range.first, lastHour: range.last)
        }.sorted { $0.date < $1.date }

        // Avg output tokens per session
        let avgOut = acc.allSessions.isEmpty ? 0 :
            acc.sessionOutputTokens.values.reduce(0, +) / acc.allSessions.count

        let totalMessages = dailyActivity.reduce(0) { $0 + $1.messageCount }

        // Daily model breakdown (for filtered model KPIs)
        let dailyModelBreakdown: [DailyModelBreakdown] = acc.dailyModelFull.map { d, modelMap in
            let modelTokens = modelMap.mapValues { t in
                ModelTokenStats(inputTokens: t.0, outputTokens: t.1,
                                cacheReadInputTokens: t.2, cacheCreationInputTokens: t.3,
                                webSearchRequests: t.4, costUSD: nil)
            }
            return DailyModelBreakdown(date: d, modelTokens: modelTokens)
        }.sorted { $0.date < $1.date }

        // Daily hour counts (for filtered schedule KPIs)
        let dailyHourCounts: [String: [String: Int]] = acc.dailyHours.mapValues { hourMap in
            Dictionary(uniqueKeysWithValues: hourMap.map { ("\($0.key)", $0.value) })
        }

        // Daily project costs (for filtered project KPIs)
        let dailyProjectCosts: [DailyProjectCosts] = acc.dailyProjCost.keys.map { d in
            DailyProjectCosts(
                date: d,
                costs:       acc.dailyProjCost[d]        ?? [:],
                outputs:     acc.dailyProjOutput[d]       ?? [:],
                messages:    acc.dailyProjMessages[d]     ?? [:],
                webSearches: acc.dailyProjWebSearches[d]  ?? [:]
            )
        }.sorted { $0.date < $1.date }

        return StatsCache(
            version: nil,
            lastComputedDate: acc.lastDay,
            dailyActivity: dailyActivity,
            dailyModelTokens: dailyModelTokens,
            modelUsage: modelUsage.isEmpty ? nil : modelUsage,
            totalSessions: acc.allSessions.count,
            totalMessages: totalMessages,
            longestSession: longestSession,
            firstSessionDate: firstDateStr,
            hourCounts: hourCounts.isEmpty ? nil : hourCounts,
            totalSpeculationTimeSavedMs: nil,
            dailyCosts: dailyCosts.isEmpty ? nil : dailyCosts,
            projectStats: projectStats.isEmpty ? nil : projectStats,
            dailyWorkHours: dailyWorkHours.isEmpty ? nil : dailyWorkHours,
            subagentSessionCount: acc.subagentSessions.count,
            directSessionCount: acc.directSessions.count,
            avgOutputTokensPerSession: avgOut,
            dailyTotals: dailyTotals.isEmpty ? nil : dailyTotals,
            dailyModelBreakdown: dailyModelBreakdown.isEmpty ? nil : dailyModelBreakdown,
            dailyHourCounts: dailyHourCounts.isEmpty ? nil : dailyHourCounts,
            dailyProjectCosts: dailyProjectCosts.isEmpty ? nil : dailyProjectCosts
        )
    }
    */

    // MARK: - Computed properties

    var totalEstimatedCost: Double {
        (stats?.modelUsage ?? [:]).reduce(0) { sum, pair in
            sum + ModelPricingTable.price(for: pair.key).cost(for: pair.value)
        }
    }
    var totalOutputTokens: Int  { stats?.modelUsage?.values.reduce(0) { $0 + $1.outputTokens } ?? 0 }
    var totalInputTokens:  Int  { stats?.modelUsage?.values.reduce(0) { $0 + $1.inputTokens  } ?? 0 }
    var totalCacheTokens:  Int  {
        stats?.modelUsage?.values.reduce(0) { $0 + $1.cacheReadInputTokens + $1.cacheCreationInputTokens } ?? 0
    }

    var sortedModels: [(model: String, stats: ModelTokenStats)] {
        (stats?.modelUsage ?? [:]).map { (model: $0.key, stats: $0.value) }
            .sorted { $0.stats.outputTokens > $1.stats.outputTokens }
    }

    var recentActivity: [DailyActivity] {
        (stats?.dailyActivity ?? []).sorted { $0.date < $1.date }
    }

    // MARK: - Date filter window

    /// Half-open [start, end) window for the current date filter; nil = no filtering (.all).
    /// Single source of truth for every `filtered*` property — when adding a new
    /// filter-aware property, slice with `slice(_:in:day:)` instead of switching on `dateFilter`.
    private var dateFilterWindow: Range<Date>? {
        let cal = Calendar.current
        switch dateFilter {
        case .all:
            return nil
        case .today:
            return cal.startOfDay(for: Date())..<Date.distantFuture
        case .sevenDays:
            return cal.date(byAdding: .day, value: -7, to: Date())!..<Date.distantFuture
        case .thirtyDays:
            return cal.date(byAdding: .day, value: -30, to: Date())!..<Date.distantFuture
        case .custom:
            let start = cal.startOfDay(for: customStartDate)
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEndDate))!
            return start..<end
        }
    }

    /// Current window shifted back by one period, for week-over-week deltas;
    /// nil for .all and .custom (no delta badge).
    private var previousPeriodWindow: Range<Date>? {
        let cal = Calendar.current
        let now = Date()
        switch dateFilter {
        case .all, .custom:
            return nil
        case .today:
            let yStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now)!)
            return yStart..<cal.startOfDay(for: now)
        case .sevenDays:
            return cal.date(byAdding: .day, value: -14, to: now)!..<cal.date(byAdding: .day, value: -7, to: now)!
        case .thirtyDays:
            return cal.date(byAdding: .day, value: -60, to: now)!..<cal.date(byAdding: .day, value: -30, to: now)!
        }
    }

    /// Keeps elements whose "yyyy-MM-dd" day string falls inside the window (nil = keep all).
    private func slice<T>(_ items: [T], in window: Range<Date>?, day: (T) -> String) -> [T] {
        guard let window else { return items }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return items.filter { window.contains(fmt.date(from: day($0)) ?? .distantPast) }
    }

    /// Same, for dictionaries keyed by "yyyy-MM-dd" day strings.
    private func slice<V>(_ dict: [String: V], in window: Range<Date>?) -> [String: V] {
        guard let window else { return dict }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return dict.filter { window.contains(fmt.date(from: $0.key) ?? .distantPast) }
    }

    var filteredActivity: [DailyActivity] {
        slice(recentActivity, in: dateFilterWindow) { $0.date }
    }

    var filteredTotalMessages: Int {
        dateFilter == .all ? (stats?.totalMessages ?? 0)
                           : filteredActivity.reduce(0) { $0 + $1.messageCount }
    }
    var filteredTotalSessions: Int {
        dateFilter == .all ? (stats?.totalSessions ?? 0)
                           : filteredActivity.reduce(0) { $0 + $1.sessionCount }
    }

    var hourlyData: [(hour: Int, count: Int)] {
        let counts = stats?.hourCounts ?? [:]
        return (0..<24).map { h in (hour: h, count: counts["\(h)"] ?? 0) }
    }

    var modelCosts: [(model: String, cost: Double)] {
        (stats?.modelUsage ?? [:])
            .map { (model: $0.key, cost: ModelPricingTable.price(for: $0.key).cost(for: $0.value)) }
            .sorted { $0.cost > $1.cost }
    }

    var peakHour: Int? {
        hourlyData.max(by: { $0.count < $1.count }).flatMap { $0.count > 0 ? $0.hour : nil }
    }

    // Cache
    var cacheHitRate: Double {
        let read  = stats?.modelUsage?.values.reduce(0) { $0 + $1.cacheReadInputTokens  } ?? 0
        let write = stats?.modelUsage?.values.reduce(0) { $0 + $1.cacheCreationInputTokens } ?? 0
        let total = read + write
        guard total > 0 else { return 0 }
        return Double(read) / Double(total)
    }

    var cacheSavingsUSD: Double {
        (stats?.modelUsage ?? [:]).reduce(0.0) { sum, pair in
            let price = ModelPricingTable.price(for: pair.key)
            let cr = Double(pair.value.cacheReadInputTokens)
            return sum + max(0, cr * (price.inputPerMTok - price.cacheReadPerMTok) / 1_000_000)
        }
    }

    // Streak
    var currentStreak: Int {
        let days = Set(recentActivity.map(\.date))
        let cal  = Calendar.current
        let fmt  = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var date = Date()
        if !days.contains(fmt.string(from: date)) {
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        var streak = 0
        while days.contains(fmt.string(from: date)) {
            streak += 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        return streak
    }

    var longestStreak: Int {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let sorted = recentActivity.compactMap { fmt.date(from: $0.date) }
            .map { cal.startOfDay(for: $0) }.sorted()
        var maxStreak = 0, streak = 0
        var prev: Date? = nil
        for day in sorted {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == day {
                streak += 1
            } else {
                streak = 1
            }
            if streak > maxStreak { maxStreak = streak }
            prev = day
        }
        return maxStreak
    }

    var hasRecentActivity: Bool {
        guard let ts = stats?.latestMessageTimestamp else { return false }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = fmt.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        guard let d else { return false }
        return Date().timeIntervalSince(d) < 60
    }

    var totalWebSearches: Int {
        stats?.modelUsage?.values.reduce(0) { $0 + ($1.webSearchRequests ?? 0) } ?? 0
    }

    // MARK: - Date-filtered aggregates

    private var filteredDailyTotals: [DailyTokenTotals] {
        slice(stats?.dailyTotals ?? [], in: dateFilterWindow) { $0.date }
    }

    var filteredTotalCost:    Double { filteredDailyTotals.reduce(0) { $0 + $1.estimatedCostUSD } }
    var filteredOutputTokens: Int    { filteredDailyTotals.reduce(0) { $0 + $1.outputTokens } }
    var filteredInputTokens:  Int    { filteredDailyTotals.reduce(0) { $0 + $1.inputTokens } }
    var filteredCacheTokens:  Int    { filteredDailyTotals.reduce(0) { $0 + $1.cacheReadTokens + $1.cacheCreateTokens } }
    var filteredWebSearches:  Int    { filteredDailyTotals.reduce(0) { $0 + $1.webSearchCount } }
    var filteredCacheSavings: Double { filteredDailyTotals.reduce(0) { $0 + $1.cacheSavingsUSD } }

    var filteredCacheHitRate: Double {
        let read  = filteredDailyTotals.reduce(0) { $0 + $1.cacheReadTokens }
        let write = filteredDailyTotals.reduce(0) { $0 + $1.cacheCreateTokens }
        let total = read + write
        guard total > 0 else { return 0 }
        return Double(read) / Double(total)
    }

    var filteredDailyCostData: [(date: String, cost: Double)] {
        filteredDailyTotals.map { (date: $0.date, cost: $0.estimatedCostUSD) }
    }

    // MARK: - Daily cost explanation (for chart click-to-explain popover)

    struct DailyCostExplanation {
        struct ModelLine: Identifiable {
            var id: String { model }
            let model: String
            let displayName: String
            let inputTokens: Int
            let outputTokens: Int
            let cacheReadTokens: Int
            let cacheCreateTokens: Int
            let price: ModelPricingTable.Price
            let costInput: Double
            let costOutput: Double
            let costCacheRead: Double
            let costCacheCreate: Double
            var costTotal: Double { costInput + costOutput + costCacheRead + costCacheCreate }
        }
        struct ProjectLine: Identifiable {
            var id: String { project }
            let project: String
            let costUSD: Double
            let messageCount: Int
        }
        let date: String
        let totalCost: Double
        let totalMessages: Int
        let modelLines: [ModelLine]
        let projectLines: [ProjectLine]
        let accountFilter: String?
        let projectFilter: String?
    }

    func dailyCostExplanation(for date: String) -> DailyCostExplanation? {
        guard let totals = stats?.dailyTotals?.first(where: { $0.date == date }) else { return nil }
        let breakdown = stats?.dailyModelBreakdown?.first(where: { $0.date == date })
        let modelLines: [DailyCostExplanation.ModelLine] = (breakdown?.modelTokens ?? [:])
            .sorted { ($0.value.outputTokens + $0.value.inputTokens) > ($1.value.outputTokens + $1.value.inputTokens) }
            .map { (model, s) in
                let p = ModelPricingTable.price(for: model)
                return .init(
                    model: model,
                    displayName: modelDisplayName(model),
                    inputTokens: s.inputTokens,
                    outputTokens: s.outputTokens,
                    cacheReadTokens: s.cacheReadInputTokens,
                    cacheCreateTokens: s.cacheCreationInputTokens,
                    price: p,
                    costInput:       Double(s.inputTokens)              * p.inputPerMTok     / 1_000_000,
                    costOutput:      Double(s.outputTokens)             * p.outputPerMTok    / 1_000_000,
                    costCacheRead:   Double(s.cacheReadInputTokens)     * p.cacheReadPerMTok / 1_000_000,
                    costCacheCreate: Double(s.cacheCreationInputTokens) * p.cacheWritePerMTok / 1_000_000
                )
            }
        let projectDay = stats?.dailyProjectCosts?.first(where: { $0.date == date })
        let projectLines: [DailyCostExplanation.ProjectLine] = (projectDay?.costs ?? [:])
            .sorted { $0.value > $1.value }
            .map { (proj, cost) in
                .init(project: proj, costUSD: cost, messageCount: projectDay?.messages[proj] ?? 0)
            }
        let totalMessages = (projectDay?.messages ?? [:]).values.reduce(0, +)
        return .init(
            date: date,
            totalCost: totals.estimatedCostUSD,
            totalMessages: totalMessages,
            modelLines: modelLines,
            projectLines: projectLines,
            accountFilter: accountFilter,
            projectFilter: projectFilter
        )
    }

    // MARK: - Filtered model stats

    private var filteredModelBreakdownDays: [DailyModelBreakdown] {
        slice(stats?.dailyModelBreakdown ?? [], in: dateFilterWindow) { $0.date }
    }

    var filteredModelUsage: [String: ModelTokenStats] {
        var merged: [String: (Int, Int, Int, Int, Int)] = [:]
        for day in filteredModelBreakdownDays {
            for (model, s) in day.modelTokens {
                var t = merged[model] ?? (0, 0, 0, 0, 0)
                t.0 += s.inputTokens; t.1 += s.outputTokens
                t.2 += s.cacheReadInputTokens; t.3 += s.cacheCreationInputTokens
                t.4 += s.webSearchRequests ?? 0
                merged[model] = t
            }
        }
        return merged.mapValues { t in
            ModelTokenStats(inputTokens: t.0, outputTokens: t.1,
                            cacheReadInputTokens: t.2, cacheCreationInputTokens: t.3,
                            webSearchRequests: t.4, costUSD: nil)
        }
    }

    var filteredSortedModels: [(model: String, stats: ModelTokenStats)] {
        filteredModelUsage.map { (model: $0.key, stats: $0.value) }
            .sorted { $0.stats.outputTokens > $1.stats.outputTokens }
    }

    var filteredModelCosts: [(model: String, cost: Double)] {
        filteredModelUsage
            .map { (model: $0.key, cost: ModelPricingTable.price(for: $0.key).cost(for: $0.value)) }
            .sorted { $0.cost > $1.cost }
    }

    // MARK: - Filtered hourly data

    private var filteredDailyHourCounts: [String: [String: Int]] {
        slice(stats?.dailyHourCounts ?? [:], in: dateFilterWindow)
    }

    var filteredHourlyData: [(hour: Int, count: Int)] {
        var counts = [Int: Int]()
        for (_, hourMap) in filteredDailyHourCounts {
            for (hStr, c) in hourMap {
                if let h = Int(hStr) { counts[h] = (counts[h] ?? 0) + c }
            }
        }
        return (0..<24).map { h in (hour: h, count: counts[h] ?? 0) }
    }

    var filteredPeakHour: Int? {
        filteredHourlyData.max(by: { $0.count < $1.count }).flatMap { $0.count > 0 ? $0.hour : nil }
    }

    // MARK: - Filtered project stats

    private var filteredDailyProjCosts: [DailyProjectCosts] {
        slice(stats?.dailyProjectCosts ?? [], in: dateFilterWindow) { $0.date }
    }

    var filteredSortedProjects: [ProjectStats] {
        var costs:    [String: Double] = [:]
        var outputs:  [String: Int]    = [:]
        var messages: [String: Int]    = [:]
        var webSearches: [String: Int] = [:]
        for day in filteredDailyProjCosts {
            for (proj, v) in day.costs       { costs[proj]       = (costs[proj]       ?? 0) + v }
            for (proj, v) in day.outputs     { outputs[proj]     = (outputs[proj]     ?? 0) + v }
            for (proj, v) in day.messages    { messages[proj]    = (messages[proj]    ?? 0) + v }
            for (proj, v) in day.webSearches { webSearches[proj] = (webSearches[proj] ?? 0) + v }
        }
        // AI code stats are all-time (git history + cumulative writes), indexed by project name
        let aiStats: [String: (Int, Int)] = Dictionary(uniqueKeysWithValues:
            (stats?.projectStats ?? []).map { ($0.project, ($0.aiLinesWritten, $0.gitLinesAdded)) }
        )
        return costs.keys.map { proj in
            let (aiLines, gitLines) = aiStats[proj] ?? (0, 0)
            return ProjectStats(project: proj,
                                inputTokens: 0, outputTokens: outputs[proj] ?? 0,
                                cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
                                webSearchRequests: webSearches[proj] ?? 0,
                                sessionCount: 0, messageCount: messages[proj] ?? 0,
                                estimatedCostUSD: costs[proj] ?? 0,
                                aiLinesWritten: aiLines, gitLinesAdded: gitLines)
        }.sorted { $0.estimatedCostUSD > $1.estimatedCostUSD }
    }

    var filteredAICodePct: Double? {
        let projects = filteredSortedProjects.filter { $0.gitLinesAdded > 0 }
        guard !projects.isEmpty else { return nil }
        let ai  = projects.reduce(0) { $0 + $1.aiLinesWritten }
        let git = projects.reduce(0) { $0 + $1.gitLinesAdded }
        guard git > 0 else { return nil }
        return min(1.0, Double(ai) / Double(git))
    }

    // Daily costs (all-time, for all-time charts in Models tab)
    var dailyCostData: [(date: String, cost: Double)] {
        (stats?.dailyCosts ?? [:]).map { (date: $0.key, cost: $0.value) }.sorted { $0.date < $1.date }
    }

    // Projects (all-time)
    var sortedProjects: [ProjectStats] { stats?.projectStats ?? [] }

    // Day of week — uses filteredActivity so it responds to the filter
    var dayOfWeekData: [(day: String, count: Int)] {
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var counts = [Int: Int]()
        for a in filteredActivity {
            guard let d = fmt.date(from: a.date) else { continue }
            let dow = cal.component(.weekday, from: d)
            counts[dow] = (counts[dow] ?? 0) + a.messageCount
        }
        // Mon=2..Sun=1, display Mon-Sun
        let order = [2, 3, 4, 5, 6, 7, 1]
        let names = [2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat", 1: "Sun"]
        return order.map { (day: names[$0]!, count: counts[$0] ?? 0) }
    }

    // Work hours
    var workHoursData: [DailyWorkHours] {
        slice(stats?.dailyWorkHours?.sorted { $0.date < $1.date } ?? [], in: dateFilterWindow) { $0.date }
    }

    var avgStartHour: Double? {
        let h = workHoursData.map { Double($0.firstHour) }
        return h.isEmpty ? nil : h.reduce(0, +) / Double(h.count)
    }
    var avgEndHour: Double? {
        let h = workHoursData.map { Double($0.lastHour) }
        return h.isEmpty ? nil : h.reduce(0, +) / Double(h.count)
    }

    var avgOutputTokensPerSession: Int { stats?.avgOutputTokensPerSession ?? 0 }
    var subagentSessionCount:      Int { stats?.subagentSessionCount ?? 0 }
    var directSessionCount:        Int { stats?.directSessionCount  ?? 0 }

    // MARK: - Sessions

    var filteredSessions: [SessionSummary] {
        slice(stats?.sessions ?? [], in: dateFilterWindow) { $0.firstDay }
    }

    var filteredAvgRating: Double? {
        let ratings = filteredSessions.compactMap { $0.rating }
        guard !ratings.isEmpty else { return nil }
        return Double(ratings.reduce(0, +)) / Double(ratings.count)
    }

    // MARK: - Menu bar

    var menuBarLabel: String {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let todayCost = (stats?.dailyTotals ?? [])
            .filter { (fmt.date(from: $0.date) ?? .distantPast) >= todayStart }
            .reduce(0.0) { $0 + $1.estimatedCostUSD }
        if todayCost == 0 && stats == nil { return "$-.--" }
        return formatCost(todayCost)
    }

    // MARK: - Burn rate / forecast

    var burnRatePerDay: Double {
        let last7 = (stats?.dailyTotals ?? []).suffix(7)
        guard !last7.isEmpty else { return 0 }
        return last7.reduce(0.0) { $0 + $1.estimatedCostUSD } / Double(last7.count)
    }

    var currentMonthCost: Double {
        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return (stats?.dailyTotals ?? []).filter { day in
            guard let d = fmt.date(from: day.date) else { return false }
            return cal.isDate(d, equalTo: now, toGranularity: .month)
        }.reduce(0.0) { $0 + $1.estimatedCostUSD }
    }

    var daysLeftInMonth: Int {
        let cal = Calendar.current
        let now = Date()
        let range = cal.range(of: .day, in: .month, for: now)!
        let today = cal.component(.day, from: now)
        return range.count - today
    }

    var projectedMonthCost: Double {
        currentMonthCost + burnRatePerDay * Double(daysLeftInMonth)
    }

    // MARK: - Week-over-week comparison

    private var previousPeriodDailyTotals: [DailyTokenTotals] {
        guard let window = previousPeriodWindow else { return [] }
        return slice(stats?.dailyTotals ?? [], in: window) { $0.date }
    }

    var previousPeriodCost: Double { previousPeriodDailyTotals.reduce(0) { $0 + $1.estimatedCostUSD } }

    var costDeltaPct: Double? {
        let prev = previousPeriodCost
        guard prev > 0 else { return nil }
        return (filteredTotalCost - prev) / prev
    }

    var previousPeriodMessages: Int {
        guard let window = previousPeriodWindow else { return 0 }
        return slice(stats?.dailyActivity ?? [], in: window) { $0.date }
            .reduce(0) { $0 + $1.messageCount }
    }

    var messagesDeltaPct: Double? {
        let prev = Double(previousPeriodMessages)
        guard prev > 0 else { return nil }
        return (Double(filteredTotalMessages) - prev) / prev
    }

    // MARK: - Subagent analytics

    var filteredSubagentCost: Double {
        filteredSessions.filter { $0.isSubagent }.reduce(0) { $0 + $1.costUSD }
    }

    var filteredDirectCost: Double {
        filteredSessions.filter { !$0.isSubagent }.reduce(0) { $0 + $1.costUSD }
    }

    // MARK: - Platform KPIs

    var platformDailyTotals: [DailyTokenTotals] { filteredDailyTotals }

    var filteredHourlyCosts: [(hour: Int, cost: Double)] {
        let filtered = slice(stats?.dailyHourCosts ?? [:], in: dateFilterWindow)
        var totals = [Int: Double]()
        for (_, hourMap) in filtered {
            for (hStr, cost) in hourMap { if let h = Int(hStr) { totals[h, default: 0] += cost } }
        }
        return (0..<24).map { h in (hour: h, cost: totals[h] ?? 0) }
    }

    var filteredEfficiencyTrend: [(date: String, ratio: Double)] {
        filteredDailyTotals.compactMap { day in
            let ctx = day.inputTokens + day.cacheReadTokens + day.cacheCreateTokens
            guard ctx > 0 else { return nil }
            return (date: day.date, ratio: Double(day.outputTokens) / Double(ctx))
        }.sorted { $0.date < $1.date }
    }

    var visibleSessions: [SessionSummary] {
        let base = filteredSessions
        let searched = sessionSearchText.isEmpty ? base : base.filter {
            $0.project.localizedCaseInsensitiveContains(sessionSearchText) ||
            $0.sessionId.localizedCaseInsensitiveContains(sessionSearchText)
        }
        return Array(searched.prefix(sessionDisplayLimit))
    }

    var totalFilteredSessionCount: Int {
        let base = filteredSessions
        guard !sessionSearchText.isEmpty else { return base.count }
        return base.filter {
            $0.project.localizedCaseInsensitiveContains(sessionSearchText) ||
            $0.sessionId.localizedCaseInsensitiveContains(sessionSearchText)
        }.count
    }

    private var filteredDailyAccountCosts: [DailyAccountCosts] {
        slice(stats?.dailyAccountCosts ?? [], in: dateFilterWindow) { $0.date }
    }

    var filteredAccountCosts: [AccountCostBreakdown] {
        var totalCosts: [String: Double] = [:]
        var totalMsgs:  [String: Int]    = [:]
        for d in filteredDailyAccountCosts {
            for (uuid, cost) in d.costs { totalCosts[uuid, default: 0] += cost }
            for (uuid, msgs) in d.messages { totalMsgs[uuid, default: 0] += msgs }
        }
        let accounts = knownAccounts
        return totalCosts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .compactMap { (uuid, cost) in
                guard let acct = accounts.first(where: { $0.accountUuid == uuid }) else { return nil }
                return AccountCostBreakdown(accountUuid: uuid, label: acct.label,
                                           subtitle: acct.subtitle, authType: acct.authType,
                                           costUSD: cost, messageCount: totalMsgs[uuid] ?? 0)
            }
    }

    var platformChartData: [TokenChartPoint] {
        let daily = platformDailyTotals
        guard daily.count > 1 else { return [] }

        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        let labelFmt = DateFormatter()

        if daily.count <= 14 {
            labelFmt.dateFormat = "MMM d"
            return daily.map { d in
                let date = dayFmt.date(from: d.date) ?? Date()
                return TokenChartPoint(label: labelFmt.string(from: date),
                                       inputTokens: d.inputTokens, outputTokens: d.outputTokens,
                                       costUSD: d.estimatedCostUSD)
            }
        } else if daily.count <= 90 {
            // Weekly: group by ISO week, label = first day of group
            labelFmt.dateFormat = "MMM d"
            let isoCal = Calendar(identifier: .iso8601)
            var weekDict: [String: (label: String, input: Int, output: Int, cost: Double)] = [:]
            for d in daily {
                guard let date = dayFmt.date(from: d.date) else { continue }
                let y = isoCal.component(.yearForWeekOfYear, from: date)
                let w = isoCal.component(.weekOfYear, from: date)
                let key = String(format: "%04d-W%02d", y, w)
                if let ex = weekDict[key] {
                    weekDict[key] = (ex.label, ex.input + d.inputTokens, ex.output + d.outputTokens, ex.cost + d.estimatedCostUSD)
                } else {
                    weekDict[key] = (labelFmt.string(from: date), d.inputTokens, d.outputTokens, d.estimatedCostUSD)
                }
            }
            return weekDict.sorted { $0.key < $1.key }.map { _, v in
                TokenChartPoint(label: v.label, inputTokens: v.input, outputTokens: v.output, costUSD: v.cost)
            }
        } else {
            // Monthly: group by "yyyy-MM"
            var monthDict: [String: (input: Int, output: Int, cost: Double)] = [:]
            for d in daily {
                let key = String(d.date.prefix(7))
                let ex = monthDict[key] ?? (0, 0, 0)
                monthDict[key] = (ex.0 + d.inputTokens, ex.1 + d.outputTokens, ex.2 + d.estimatedCostUSD)
            }
            let years = Set(monthDict.keys.map { String($0.prefix(4)) })
            labelFmt.dateFormat = years.count > 1 ? "MMM ''yy" : "MMM"
            return monthDict.sorted { $0.key < $1.key }.map { key, val in
                let parts = key.split(separator: "-")
                var date = Date()
                if parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) {
                    var c = DateComponents(); c.year = y; c.month = m; c.day = 1
                    date = Calendar.current.date(from: c) ?? Date()
                }
                return TokenChartPoint(label: labelFmt.string(from: date),
                                       inputTokens: val.0, outputTokens: val.1, costUSD: val.2)
            }
        }
    }

    // Total context per request: input + all cache tokens (more stable than bare input_tokens
    // which drops to near-zero in cache-heavy sessions)
    var filteredAvgContextTokensPerRequest: Double {
        let msgs = filteredTotalMessages
        guard msgs > 0 else { return 0 }
        return Double(filteredInputTokens + filteredCacheTokens) / Double(msgs)
    }

    var filteredAvgOutputTokensPerRequest: Double {
        let msgs = filteredTotalMessages
        guard msgs > 0 else { return 0 }
        return Double(filteredOutputTokens) / Double(msgs)
    }

    var filteredAvgCostPerRequest: Double {
        let msgs = filteredTotalMessages
        guard msgs > 0 else { return 0 }
        return filteredTotalCost / Double(msgs)
    }

    var filteredDailyResponseTimes: [(date: String, avgSec: Double)] {
        slice(stats?.dailyAvgResponseTimeSec ?? [:], in: dateFilterWindow)
            .map { (date: $0.key, avgSec: $0.value) }.sorted { $0.date < $1.date }
    }

    var filteredAvgResponseTimeSec: Double? {
        let vals = filteredDailyResponseTimes.map { $0.avgSec }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Alerts

    private func checkAlerts() {
        let threshold = alertThreshold
        guard threshold > 0 else { return }
        let todayCost = filteredTotalCostToday
        guard todayCost >= threshold else { return }

        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let todayStr = fmt.string(from: Date())
        let lastAlertDay = UserDefaults.standard.string(forKey: "argusai.lastAlertDay") ?? ""
        guard lastAlertDay != todayStr else { return }

        UserDefaults.standard.set(todayStr, forKey: "argusai.lastAlertDay")
        let content = UNMutableNotificationContent()
        content.title = "ArgusAI Daily Limit Reached"
        content.body = String(format: "Today's cost %@ has reached your limit of %@",
                              formatCost(todayCost), formatCost(threshold))
        content.sound = .default
        let req = UNNotificationRequest(identifier: "argusai.dailylimit.\(todayStr)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)

        // Per-project monthly alerts
        let fmt2 = DateFormatter(); fmt2.dateFormat = "yyyy-MM"
        let thisMonth = fmt2.string(from: Date())
        for (project, limit) in projectAlertThresholds where limit > 0 {
            let projectCost = filteredProjectMonthlyCost(project: project)
            guard projectCost >= limit else { continue }
            let alertKey = "argusai.projectAlert.\(project).\(thisMonth)"
            guard UserDefaults.standard.string(forKey: alertKey) == nil else { continue }
            UserDefaults.standard.set(thisMonth, forKey: alertKey)
            let pc = UNMutableNotificationContent()
            pc.title = "ArgusAI: Project Budget Reached"
            pc.body = String(format: "Project \u{201C}%@\u{201D} has spent %@ this month (limit: %@)",
                             project, formatCost(projectCost), formatCost(limit))
            pc.sound = .default
            let preq = UNNotificationRequest(
                identifier: "argusai.projectlimit.\(project).\(thisMonth)",
                content: pc, trigger: nil)
            UNUserNotificationCenter.current().add(preq, withCompletionHandler: nil)
        }
    }

    private var filteredTotalCostToday: Double {
        let start = Calendar.current.startOfDay(for: Date())
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return (stats?.dailyTotals ?? [])
            .filter { (fmt.date(from: $0.date) ?? .distantPast) >= start }
            .reduce(0.0) { $0 + $1.estimatedCostUSD }
    }

    private func filteredProjectMonthlyCost(project: String) -> Double {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let rows: [DailyProjectCosts] = stats?.dailyProjectCosts ?? []
        return rows
            .filter { (fmt.date(from: $0.date) ?? .distantPast) >= start }
            .reduce(into: 0.0) { $0 += $1.costs[project] ?? 0.0 }
    }

    func loadSessionMessages(sessionId: String) -> [SessionMessageDetail] {
        guard let db else { return [] }
        let raw = (try? db.querySessionMessages(sessionId: sessionId)) ?? []
        return raw.map { m in
            SessionMessageDetail(
                timestamp: m.timestamp,
                model: m.model,
                inputTokens: m.inputTokens,
                outputTokens: m.outputTokens,
                cacheReadTokens: m.cacheReadTokens,
                cacheCreateTokens: m.cacheCreateTokens,
                webSearches: m.webSearches,
                costUSD: m.costUSD,
                aiLines: m.aiLines
            )
        }
    }

    // MARK: - Export (legacy quick-export, kept for backward compat)

    @MainActor func exportJSON() {
        guard let json = buildSessionsJSON(stats?.sessions ?? []) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "argusai-\(fmt.string(from: Date())).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? json.write(to: url)
        }
    }

    func scheduleWeeklySummaryIfNeeded() {
        let key = "argusai.weeklyNotifScheduled"
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-ww"
        let thisWeek = fmt.string(from: Date())
        guard UserDefaults.standard.string(forKey: key) != thisWeek else { return }
        UserDefaults.standard.set(thisWeek, forKey: key)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            var comps = DateComponents()
            comps.weekday = 2  // Monday
            comps.hour = 9
            comps.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let content = UNMutableNotificationContent()
            content.title = "ArgusAI Weekly Summary"
            let fmt2 = DateFormatter(); fmt2.dateFormat = "yyyy-MM-dd"
            let cut = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let weekCost = (self.stats?.dailyTotals ?? [])
                .filter { (fmt2.date(from: $0.date) ?? .distantPast) >= cut }
                .reduce(0.0) { $0 + $1.estimatedCostUSD }
            let weekMsgs = (self.stats?.dailyActivity ?? [])
                .filter { $0.dateValue >= cut }
                .reduce(0) { $0 + $1.messageCount }
            content.body = String(format: "Last 7 days: %@ · %d messages", formatCost(weekCost), weekMsgs)
            content.sound = .default
            let req = UNNotificationRequest(identifier: "argusai.weekly.\(thisWeek)", content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }
    }

    @MainActor func exportCSV() {
        let csv = buildSessionsCSV(stats?.sessions ?? [])
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "argusai-\(dateFmt.string(from: Date())).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Filtered export (called by ExportView)

    @MainActor
    func performExport(
        project: String?,
        account: String?,
        startDate: Date?,
        endDate: Date?,
        formats: Set<ExportFormat>,
        destination: ExportDestination
    ) async throws {
        guard let db = db else { throw NSError(domain: "ArgusDB", code: 1) }

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let startDay = startDate.map { dayFmt.string(from: $0) }
        let endDay   = endDate.map   { dayFmt.string(from: $0) }

        // Query on background to avoid blocking main thread
        let sessions = try await Task.detached(priority: .userInitiated) {
            try db.queryFilteredSessions(
                account: account,
                project: project,
                startDay: startDay,
                endDay: endDay
            )
        }.value

        // Build file payloads
        var files: [(name: String, data: Data, mime: String)] = []
        let tag = buildExportTag(project: project, startDay: startDay, endDay: endDay)

        if formats.contains(.csv) {
            let csv = buildSessionsCSV(sessions)
            if let data = csv.data(using: .utf8) {
                files.append(("argusai-\(tag).csv", data, "text/csv"))
            }
        }
        if formats.contains(.json) {
            if let data = buildSessionsJSON(sessions) {
                files.append(("argusai-\(tag).json", data, "application/json"))
            }
        }
        guard !files.isEmpty else { return }

        switch destination {
        case .localFolder:
            await saveFilesLocally(files)
        case .googleDrive(let folderURL):
            guard let folderID = GoogleDriveService.folderID(from: folderURL) else {
                throw NSError(domain: "ArgusExport", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Link cartella Drive non valido"])
            }
            for file in files {
                try await drive.uploadFile(name: file.name, data: file.data,
                                           mimeType: file.mime, folderID: folderID)
            }
        }
    }

    private func buildExportTag(project: String?, startDay: String?, endDay: String?) -> String {
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
        var parts: [String] = []
        if let p = project, !p.isEmpty { parts.append(p.replacingOccurrences(of: "/", with: "-")) }
        if let s = startDay { parts.append(s) }
        if let e = endDay, e != startDay { parts.append(e) }
        if parts.isEmpty { parts.append(dateFmt.string(from: Date())) }
        return parts.joined(separator: "_")
    }

    @MainActor
    private func saveFilesLocally(_ files: [(name: String, data: Data, mime: String)]) async {
        if files.count == 1 {
            let file = files[0]
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.name
            if file.mime == "text/csv" { panel.allowedContentTypes = [.commaSeparatedText] }
            else                       { panel.allowedContentTypes = [.json] }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? file.data.write(to: url)
        } else {
            // Multiple files: pick a folder, write all
            let panel = NSOpenPanel()
            panel.message = "Scegli la cartella dove salvare i file di export"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Salva qui"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            for file in files {
                let dest = dir.appendingPathComponent(file.name)
                try? file.data.write(to: dest)
            }
        }
    }
}
