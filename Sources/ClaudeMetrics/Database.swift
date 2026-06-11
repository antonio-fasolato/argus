import Foundation
import CSQLite

// MARK: - MessageDetail

struct MessageDetail {
    let timestamp: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreateTokens: Int
    let webSearches: Int
    let costUSD: Double
    let aiLines: Int
}

// MARK: - ArgusDB

final class ArgusDB {

    private var db: OpaquePointer?
    private typealias DestrType = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private let transient: DestrType = unsafeBitCast(-1 as Int, to: DestrType.self)

    enum Err: Error {
        case open(String), prepare(String), exec(String)
    }

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw Err.open(msg)
        }
        var pErr: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, &pErr)
        sqlite3_free(pErr)
        try execSQL(schema)
        // Migration: add account_uuid to existing messages tables (silently ignored if already present)
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN account_uuid TEXT DEFAULT NULL", nil, nil, nil)
        // Migration: add cwd to sessions and ai_lines to messages (silently ignored if already present)
        sqlite3_exec(db, "ALTER TABLE sessions ADD COLUMN cwd TEXT DEFAULT ''", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN ai_lines INTEGER DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN request_id TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        // Migration: tag every message with its ingestion source (claude_code | cowork).
        // Existing rows all came from ~/.claude/projects, so the default is correct.
        // Index created here (not in the schema string) so it runs after the ALTER on old DBs.
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN source TEXT NOT NULL DEFAULT 'claude_code'", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_msg_day_source ON messages(day, source)", nil, nil, nil)
        // Migration: track 1-hour ephemeral cache writes separately — they cost 2× input
        // vs 1.25× for the 5-minute tier (cache_create_tokens stays the total of both).
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN cache_create_1h_tokens INTEGER DEFAULT 0", nil, nil, nil)
        // Index for the request-level dedup (lookups/updates by request_id during ingest + backfill)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_msg_request ON messages(request_id)", nil, nil, nil)
        // One-time: remove duplicate rows caused by Claude Code writing the same requestId twice.
        // Uses (session_id, timestamp) to identify duplicates because request_id is empty on
        // existing rows (the column was just added). Future ingestions skip duplicates via
        // seenRequestIds in ingestFiles(), so this only needs to run once.
        if !UserDefaults.standard.bool(forKey: "argusai.dedupRequestIds.v1") {
            sqlite3_exec(db, """
                DELETE FROM messages
                WHERE rowid NOT IN (
                    SELECT MIN(rowid) FROM messages
                    WHERE timestamp != ''
                    GROUP BY session_id, timestamp
                )
                AND timestamp != ''
                """, nil, nil, nil)
            UserDefaults.standard.set(true, forKey: "argusai.dedupRequestIds.v1")
        }
        sqlite3_exec(db, "ALTER TABLE git_stats_cache ADD COLUMN since_date TEXT DEFAULT ''", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE git_stats_cache ADD COLUMN session_lines INTEGER DEFAULT 0", nil, nil, nil)
        // One-time: clear git_stats_cache to force recomputation with session-window-based numerator
        if !UserDefaults.standard.bool(forKey: "argusai.gitCacheReset.v1") {
            sqlite3_exec(db, "DELETE FROM git_stats_cache", nil, nil, nil)
            UserDefaults.standard.set(true, forKey: "argusai.gitCacheReset.v1")
        }
        backfillSessionCwds()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    private let schema = """
        CREATE TABLE IF NOT EXISTS ingested_files (
            path             TEXT PRIMARY KEY,
            lines_processed  INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS sessions (
            session_id  TEXT PRIMARY KEY,
            project     TEXT NOT NULL DEFAULT 'unknown',
            is_subagent INTEGER DEFAULT 0,
            cwd         TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS messages (
            file_path         TEXT NOT NULL,
            line_num          INTEGER NOT NULL,
            session_id        TEXT NOT NULL,
            timestamp         TEXT NOT NULL DEFAULT '',
            day               TEXT NOT NULL DEFAULT '',
            hour              INTEGER NOT NULL DEFAULT 0,
            model             TEXT NOT NULL DEFAULT 'unknown',
            input_tokens      INTEGER DEFAULT 0,
            output_tokens     INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_create_tokens INTEGER DEFAULT 0,
            cache_create_1h_tokens INTEGER DEFAULT 0,
            web_searches      INTEGER DEFAULT 0,
            cost_usd          REAL    DEFAULT 0,
            project           TEXT NOT NULL DEFAULT 'unknown',
            is_subagent       INTEGER DEFAULT 0,
            ai_lines          INTEGER DEFAULT 0,
            request_id        TEXT NOT NULL DEFAULT '',
            source            TEXT NOT NULL DEFAULT 'claude_code',
            PRIMARY KEY (file_path, line_num)
        );
        CREATE TABLE IF NOT EXISTS git_stats_cache (
            project      TEXT PRIMARY KEY,
            cwd          TEXT NOT NULL DEFAULT '',
            lines_added  INTEGER DEFAULT 0,
            session_lines INTEGER DEFAULT 0,
            head_hash    TEXT NOT NULL DEFAULT '',
            since_date   TEXT NOT NULL DEFAULT '',
            updated_at   TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS tool_events (
            file_path  TEXT NOT NULL,
            line_num   INTEGER NOT NULL,
            session_id TEXT NOT NULL,
            day        TEXT NOT NULL DEFAULT '',
            count      INTEGER DEFAULT 0,
            PRIMARY KEY (file_path, line_num)
        );
        CREATE TABLE IF NOT EXISTS account_timeline (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            account_uuid TEXT NOT NULL DEFAULT 'unknown',
            email        TEXT NOT NULL DEFAULT '',
            org_name     TEXT NOT NULL DEFAULT '',
            display_name TEXT NOT NULL DEFAULT '',
            auth_type    TEXT NOT NULL DEFAULT 'oauth',
            recorded_at  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_msg_day     ON messages(day);
        CREATE INDEX IF NOT EXISTS idx_msg_model   ON messages(model);
        CREATE INDEX IF NOT EXISTS idx_msg_project ON messages(project);
        CREATE INDEX IF NOT EXISTS idx_msg_session ON messages(session_id);
        CREATE INDEX IF NOT EXISTS idx_msg_day_hour ON messages(day, hour);
        CREATE INDEX IF NOT EXISTS idx_msg_day_acct ON messages(day, account_uuid);
        CREATE INDEX IF NOT EXISTS idx_tool_day    ON tool_events(day);
        CREATE TABLE IF NOT EXISTS user_turns (
            file_path  TEXT NOT NULL,
            line_num   INTEGER NOT NULL,
            session_id TEXT NOT NULL,
            timestamp  TEXT NOT NULL DEFAULT '',
            day        TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (file_path, line_num)
        );
        CREATE INDEX IF NOT EXISTS idx_ut_session_ts ON user_turns(session_id, timestamp);
        CREATE TABLE IF NOT EXISTS feedback (
            session_id  TEXT PRIMARY KEY,
            timestamp   TEXT NOT NULL DEFAULT '',
            rating      INTEGER NOT NULL DEFAULT 0,
            comment     TEXT NOT NULL DEFAULT ''
        );
    """

    // MARK: - Low-level helpers

    private func execSQL(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw Err.exec(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw Err.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt!
    }

    private func bindTxt(_ s: OpaquePointer, _ i: Int32, _ v: String) {
        sqlite3_bind_text(s, i, v, Int32(v.utf8.count), transient)
    }
    private func bindInt(_ s: OpaquePointer, _ i: Int32, _ v: Int) {
        sqlite3_bind_int64(s, i, Int64(v))
    }
    private func bindDbl(_ s: OpaquePointer, _ i: Int32, _ v: Double) {
        sqlite3_bind_double(s, i, v)
    }
    private func colTxt(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }
    private func colInt(_ s: OpaquePointer, _ i: Int32) -> Int {
        Int(sqlite3_column_int64(s, i))
    }
    private func colDbl(_ s: OpaquePointer, _ i: Int32) -> Double {
        sqlite3_column_double(s, i)
    }

    // MARK: - Project name

    private func resolvedProject(cwd: String?, fileURL: URL) -> String {
        if let cwd = cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? "unknown" : name
        }
        let parts = fileURL.pathComponents
        guard let idx = parts.firstIndex(of: "projects"), idx + 1 < parts.count else { return "unknown" }
        let segs = parts[idx + 1].split(separator: "-").filter { !$0.isEmpty }
        if let gi = segs.firstIndex(of: "git"), gi + 1 < segs.count {
            return segs[(gi + 1)...].joined(separator: "-")
        }
        return segs.suffix(2).joined(separator: "-")
    }

    // MARK: - Account + Project filters (set by MetricsStore before buildStatsCache)

    var accountFilter: String?
    var projectFilter: String?
    var sourceFilter: String?

    // SQL fragments appended to WHERE. Values come from our own DB, but project names
    // derive from directory names — escape quotes so an apostrophe can't break the query.
    private func sqlQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
    private var af: String {
        var parts: [String] = []
        if let f = accountFilter { parts.append("AND account_uuid = '\(sqlQuote(f))'") }
        if let p = projectFilter { parts.append("AND project = '\(sqlQuote(p))'") }
        if let s = sourceFilter  { parts.append("AND source = '\(sqlQuote(s))'") }
        return parts.joined(separator: " ")
    }
    private func af(_ alias: String) -> String {
        var parts: [String] = []
        if let f = accountFilter { parts.append("AND \(alias).account_uuid = '\(sqlQuote(f))'") }
        if let p = projectFilter { parts.append("AND \(alias).project = '\(sqlQuote(p))'") }
        if let s = sourceFilter  { parts.append("AND \(alias).source = '\(sqlQuote(s))'") }
        return parts.joined(separator: " ")
    }

    // MARK: - Account tracking

    func claimHistoricalMessages(for accountUuid: String) throws {
        let stmt = try prepare("UPDATE messages SET account_uuid = ? WHERE account_uuid IS NULL")
        bindTxt(stmt, 1, accountUuid)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func recordAccount(_ account: AccountInfo) throws {
        let checkStmt = try prepare("SELECT account_uuid FROM account_timeline ORDER BY id DESC LIMIT 1")
        var lastUuid = ""
        if sqlite3_step(checkStmt) == SQLITE_ROW { lastUuid = colTxt(checkStmt, 0) }
        sqlite3_finalize(checkStmt)
        guard lastUuid != account.accountUuid else { return }

        let now = ISO8601DateFormatter().string(from: Date())
        let stmt = try prepare(
            "INSERT INTO account_timeline(account_uuid,email,org_name,display_name,auth_type,recorded_at) VALUES(?,?,?,?,?,?)")
        bindTxt(stmt, 1, account.accountUuid)
        bindTxt(stmt, 2, account.email)
        bindTxt(stmt, 3, account.orgName)
        bindTxt(stmt, 4, account.displayName)
        bindTxt(stmt, 5, account.authType)
        bindTxt(stmt, 6, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Ingestion

    /// Counters for data silently skipped during an ingest run. Surfaced in the UI
    /// so partial ingestion (corrupt files, malformed lines) is visible to the user.
    struct IngestReport {
        var unreadableFiles = 0
        var malformedLines = 0
        var isEmpty: Bool { unreadableFiles == 0 && malformedLines == 0 }
    }

    /// Web searches + AI-written lines from a message's content blocks.
    /// server_tool_use.web_search_requests is always 0 in Claude Code JSONL; actual
    /// searches are tool_use blocks named "WebSearch". AI lines come from
    /// Write/Edit/MultiEdit payloads and Bash heredocs.
    private func contentMetrics(_ contentBlocks: [[String: Any]]) -> (webSearches: Int, aiLines: Int) {
        let ws = contentBlocks.filter {
            $0["type"] as? String == "tool_use" && $0["name"] as? String == "WebSearch"
        }.count
        let aiLines = contentBlocks.reduce(0) { sum, block -> Int in
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String,
                  let input = block["input"] as? [String: Any] else { return sum }
            switch name {
            case "Write":
                return sum + (input["content"] as? String ?? "").components(separatedBy: "\n").count
            case "Edit":
                return sum + (input["new_string"] as? String ?? "").components(separatedBy: "\n").count
            case "MultiEdit":
                let edits = input["edits"] as? [[String: Any]] ?? []
                return sum + edits.reduce(0) {
                    $0 + (($1["new_string"] as? String ?? "").components(separatedBy: "\n").count)
                }
            case "Bash":
                // Count lines inside heredoc blocks (most common pattern for large file writes via Bash)
                return sum + bashHeredocLineCount(input["command"] as? String ?? "")
            default: return sum
            }
        }
        return (ws, aiLines)
    }

    /// All requestIds already in the DB, with the row that owns each one.
    /// Used by the global dedup: a request seen again in the same file is a
    /// cumulative streaming update; in a different file it's a literal copy.
    private func loadSeenRequests() -> [String: (filePath: String, lineNum: Int)] {
        var result: [String: (filePath: String, lineNum: Int)] = [:]
        guard let q = try? prepare(
            "SELECT request_id, file_path, line_num FROM messages WHERE request_id != ''") else { return result }
        while sqlite3_step(q) == SQLITE_ROW {
            result[colTxt(q, 0)] = (colTxt(q, 1), colInt(q, 2))
        }
        sqlite3_finalize(q)
        return result
    }

    @discardableResult
    func ingestFiles(_ files: [(url: URL, isSubagent: Bool, source: String)], account: AccountInfo?) throws -> IngestReport {
        var report = IngestReport()
        // Load already-processed line counts
        var linesProcessed: [String: Int] = [:]
        do {
            let q = try prepare("SELECT path, lines_processed FROM ingested_files")
            while sqlite3_step(q) == SQLITE_ROW { linesProcessed[colTxt(q, 0)] = colInt(q, 1) }
            sqlite3_finalize(q)
        }

        // Load known sessions
        var sessionProjects: [String: String] = [:]
        do {
            let q = try prepare("SELECT session_id, project FROM sessions")
            while sqlite3_step(q) == SQLITE_ROW { sessionProjects[colTxt(q, 0)] = colTxt(q, 1) }
            sqlite3_finalize(q)
        }

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let cal = Calendar.current
        func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

        if let account { try recordAccount(account) }

        try execSQL("BEGIN")

        let sessInsert = try prepare(
            "INSERT OR IGNORE INTO sessions(session_id, project, is_subagent, cwd) VALUES(?,?,?,?)")
        let msgInsert  = try prepare("""
            INSERT OR REPLACE INTO messages
            (file_path,line_num,session_id,timestamp,day,hour,model,
             input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,
             web_searches,cost_usd,project,is_subagent,account_uuid,ai_lines,request_id,source,
             cache_create_1h_tokens)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        let toolInsert = try prepare(
            "INSERT OR IGNORE INTO tool_events(file_path,line_num,session_id,day,count) VALUES(?,?,?,?,?)")
        let fileUpsert = try prepare(
            "INSERT OR REPLACE INTO ingested_files(path,lines_processed) VALUES(?,?)")
        let utInsert = try prepare(
            "INSERT OR IGNORE INTO user_turns(file_path,line_num,session_id,timestamp,day) VALUES(?,?,?,?,?)")
        // Cumulative streaming update: a later line of the same request supersedes the
        // token counts (usage is cumulative) and adds its own content blocks (ws/ai_lines)
        let dupUpdate = try prepare("""
            UPDATE messages SET
                input_tokens = ?, output_tokens = ?, cache_read_tokens = ?,
                cache_create_tokens = ?, cache_create_1h_tokens = ?,
                web_searches = web_searches + ?, ai_lines = ai_lines + ?, cost_usd = ?
            WHERE file_path = ? AND line_num = ?
            """)

        // Global request dedup (lazy: loaded only when a file actually has new lines).
        // Same requestId in the same file = cumulative streaming write (last-wins);
        // in a different file = literal copy (e.g. compaction agent transcripts) → skip.
        var seenRequests: [String: (filePath: String, lineNum: Int)]? = nil

        for (fileURL, isSubagent, source) in files {
            let path = fileURL.path
            let startLine = linesProcessed[path] ?? 0

            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else {
                report.unreadableFiles += 1
                continue
            }

            let allLines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard allLines.count > startLine else { continue }
            let newLines = allLines[startLine...]

            // Pass 1: collect cwds for unknown sessions
            var newCwds: [String: String] = [:]
            for line in newLines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let sid = obj["sessionId"] as? String ?? ""
                guard !sid.isEmpty, newCwds[sid] == nil, sessionProjects[sid] == nil,
                      let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
                newCwds[sid] = cwd
            }

            // Insert newly-discovered sessions.
            // Cowork sessions run in a sandbox whose cwd/path slug is meaningless —
            // group them all under a single "Cowork" project.
            for (sid, cwd) in newCwds {
                let proj = source == "cowork" ? "Cowork" : resolvedProject(cwd: cwd, fileURL: fileURL)
                bindTxt(sessInsert, 1, sid)
                bindTxt(sessInsert, 2, proj)
                bindInt(sessInsert, 3, isSubagent ? 1 : 0)
                bindTxt(sessInsert, 4, cwd)
                sqlite3_step(sessInsert)
                sqlite3_reset(sessInsert)
                sessionProjects[sid] = proj
            }

            // Pass 2: insert messages and tool events
            if seenRequests == nil { seenRequests = loadSeenRequests() }
            var lineNum = startLine
            for line in newLines {
                lineNum += 1
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    report.malformedLines += 1
                    continue
                }

                let type = obj["type"] as? String ?? ""
                let sid  = obj["sessionId"] as? String ?? ""
                let ts   = obj["timestamp"] as? String ?? ""
                let day  = ts.isEmpty ? "" : String(ts.prefix(10))

                if type == "assistant", let msg = obj["message"] as? [String: Any] {
                    let reqId = obj["requestId"] as? String ?? ""

                    // Literal copy of a request already owned by ANOTHER file
                    // (compaction agent transcripts) — skip before the heavy parse
                    let keptRow = reqId.isEmpty ? nil : seenRequests?[reqId]
                    if let kept = keptRow, kept.filePath != path { continue }

                    let model  = msg["model"] as? String ?? "unknown"
                    let usage  = msg["usage"] as? [String: Any] ?? [:]
                    let input  = usage["input_tokens"]                as? Int ?? 0
                    let output = usage["output_tokens"]               as? Int ?? 0
                    let cr     = usage["cache_read_input_tokens"]     as? Int ?? 0
                    let cc     = usage["cache_creation_input_tokens"] as? Int ?? 0
                    // usage.cache_creation breaks the total down by TTL — the 1h tier costs 2× input
                    let ccDetail = usage["cache_creation"] as? [String: Any] ?? [:]
                    let cc1h   = min(cc, ccDetail["ephemeral_1h_input_tokens"] as? Int ?? 0)
                    let contentBlocks = msg["content"] as? [[String: Any]] ?? []
                    let (ws, aiLines) = contentMetrics(contentBlocks)

                    guard input + output + cr + cc > 0 else { continue }

                    let cost = ModelPricingTable.price(for: model)
                        .cost(input: input, output: output, cr: cr, cc5m: cc - cc1h, cc1h: cc1h)

                    // Same request, same file: cumulative streaming write — update the
                    // kept row with the latest (cumulative) usage, add this line's blocks.
                    // timestamp/day/hour stay those of the first line.
                    if let kept = keptRow {
                        bindInt(dupUpdate, 1, input);  bindInt(dupUpdate, 2, output)
                        bindInt(dupUpdate, 3, cr);     bindInt(dupUpdate, 4, cc)
                        bindInt(dupUpdate, 5, cc1h);   bindInt(dupUpdate, 6, ws)
                        bindInt(dupUpdate, 7, aiLines); bindDbl(dupUpdate, 8, cost)
                        bindTxt(dupUpdate, 9, kept.filePath)
                        bindInt(dupUpdate, 10, kept.lineNum)
                        sqlite3_step(dupUpdate)
                        sqlite3_reset(dupUpdate)
                        continue
                    }

                    let hour = parseDate(ts).map { cal.component(.hour, from: $0) } ?? 0
                    let proj = sessionProjects[sid]
                        ?? (source == "cowork" ? "Cowork" : resolvedProject(cwd: nil, fileURL: fileURL))

                    bindTxt(msgInsert,  1, path);   bindInt(msgInsert,  2, lineNum)
                    bindTxt(msgInsert,  3, sid);    bindTxt(msgInsert,  4, ts)
                    bindTxt(msgInsert,  5, day);    bindInt(msgInsert,  6, hour)
                    bindTxt(msgInsert,  7, model);  bindInt(msgInsert,  8, input)
                    bindInt(msgInsert,  9, output); bindInt(msgInsert, 10, cr)
                    bindInt(msgInsert, 11, cc);     bindInt(msgInsert, 12, ws)
                    bindDbl(msgInsert, 13, cost);   bindTxt(msgInsert, 14, proj)
                    bindInt(msgInsert, 15, isSubagent ? 1 : 0)
                    if let uuid = account?.accountUuid { bindTxt(msgInsert, 16, uuid) }
                    else { sqlite3_bind_null(msgInsert, 16) }
                    bindInt(msgInsert, 17, aiLines)
                    bindTxt(msgInsert, 18, reqId)
                    bindTxt(msgInsert, 19, source)
                    bindInt(msgInsert, 20, cc1h)
                    sqlite3_step(msgInsert)
                    sqlite3_reset(msgInsert)
                    // Register only after the >0 guard: a zero-usage first line must not
                    // shadow the real row of the same request
                    if !reqId.isEmpty { seenRequests?[reqId] = (path, lineNum) }
                }

                if type == "user", let msg = obj["message"] as? [String: Any], !day.isEmpty {
                    let contentArr = msg["content"] as? [[String: Any]] ?? []
                    let toolCount = contentArr.filter { $0["type"] as? String == "tool_result" }.count
                    if toolCount > 0 {
                        bindTxt(toolInsert, 1, path); bindInt(toolInsert, 2, lineNum)
                        bindTxt(toolInsert, 3, sid);  bindTxt(toolInsert, 4, day)
                        bindInt(toolInsert, 5, toolCount)
                        sqlite3_step(toolInsert)
                        sqlite3_reset(toolInsert)
                    }
                    let hasText = contentArr.contains { $0["type"] as? String == "text" }
                        || msg["content"] is String
                    if hasText && !ts.isEmpty {
                        bindTxt(utInsert, 1, path); bindInt(utInsert, 2, lineNum)
                        bindTxt(utInsert, 3, sid);  bindTxt(utInsert, 4, ts)
                        bindTxt(utInsert, 5, day)
                        sqlite3_step(utInsert)
                        sqlite3_reset(utInsert)
                    }
                }
            }

            bindTxt(fileUpsert, 1, path); bindInt(fileUpsert, 2, allLines.count)
            sqlite3_step(fileUpsert); sqlite3_reset(fileUpsert)
        }

        sqlite3_finalize(sessInsert)
        sqlite3_finalize(msgInsert)
        sqlite3_finalize(toolInsert)
        sqlite3_finalize(fileUpsert)
        sqlite3_finalize(utInsert)
        sqlite3_finalize(dupUpdate)

        try execSQL("COMMIT")
        return report
    }

    // MARK: - Feedback ingestion

    func ingestFeedback(at url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let stmt = try prepare(
            "INSERT OR REPLACE INTO feedback(session_id,timestamp,rating,comment) VALUES(?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        try execSQL("BEGIN")
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "feedback",
                  let sid = obj["sessionId"] as? String, !sid.isEmpty,
                  let rating = obj["rating"] as? Int, rating >= 1, rating <= 5 else { continue }
            let ts      = obj["timestamp"] as? String ?? ""
            let comment = obj["comment"]   as? String ?? ""
            bindTxt(stmt, 1, sid);    bindTxt(stmt, 2, ts)
            bindInt(stmt, 3, rating); bindTxt(stmt, 4, comment)
            sqlite3_step(stmt); sqlite3_reset(stmt)
        }
        try execSQL("COMMIT")
    }

    // MARK: - Build StatsCache from DB

    func buildStatsCache() throws -> StatsCache {
        try? updateGitStats()
        let (dailyTotals, dailyModelBreakdown) = try queryDailyBreakdown()
        let modelUsage          = try queryModelUsage()
        let dailyActivity       = try queryDailyActivity()
        let hourCounts          = try queryHourCounts()
        let dailyHourCounts     = try queryDailyHourCounts()
        let dailyWorkHours      = try queryDailyWorkHours()
        let projectStats        = try queryProjectStats()
        let dailyProjectCosts   = try queryDailyProjectCosts()
        let (totSess, totMsg, longestSess, firstDate, avgOut) = try querySessionAggregates()
        let (subCnt, dirCnt)    = try queryAgentCounts()
        let sessions            = try querySessions()
        let (subCost, dirCost)  = try queryAgentTypeCosts()
        let accountCosts        = try queryAccountCosts()
        let knownAccounts       = try queryKnownAccounts()
        let knownProjects       = try queryKnownProjects()
        let dailyAvgResponseTime  = try queryDailyAvgResponseTime()
        let dailyAccountCosts    = try queryDailyAccountCosts()
        let dailyHourCosts       = try queryDailyHourCosts()
        let latestTs             = try queryLatestMessageTimestamp()
        let dailySourceCosts     = try queryDailySourceCosts()
        let knownSources         = try queryKnownSources()

        let dailyCosts = Dictionary(uniqueKeysWithValues: dailyTotals.map { ($0.date, $0.estimatedCostUSD) })

        return StatsCache(
            version: nil,
            lastComputedDate: dailyTotals.last?.date,
            dailyActivity: dailyActivity,
            dailyModelTokens: nil,
            modelUsage: modelUsage.isEmpty ? nil : modelUsage,
            totalSessions: totSess,
            totalMessages: totMsg,
            longestSession: longestSess,
            firstSessionDate: firstDate,
            hourCounts: hourCounts.isEmpty ? nil : hourCounts,
            totalSpeculationTimeSavedMs: nil,
            dailyCosts: dailyCosts.isEmpty ? nil : dailyCosts,
            projectStats: projectStats.isEmpty ? nil : projectStats,
            dailyWorkHours: dailyWorkHours.isEmpty ? nil : dailyWorkHours,
            subagentSessionCount: subCnt,
            directSessionCount: dirCnt,
            avgOutputTokensPerSession: avgOut,
            dailyTotals: dailyTotals.isEmpty ? nil : dailyTotals,
            dailyModelBreakdown: dailyModelBreakdown.isEmpty ? nil : dailyModelBreakdown,
            dailyHourCounts: dailyHourCounts.isEmpty ? nil : dailyHourCounts,
            dailyProjectCosts: dailyProjectCosts.isEmpty ? nil : dailyProjectCosts,
            sessions: sessions.isEmpty ? nil : sessions,
            subagentCostUSD: subCost,
            directCostUSD: dirCost,
            accountCosts: accountCosts.isEmpty ? nil : accountCosts,
            knownAccountsList: knownAccounts.isEmpty ? nil : knownAccounts,
            knownProjectsList: knownProjects.isEmpty ? nil : knownProjects,
            dailyAvgResponseTimeSec: dailyAvgResponseTime.isEmpty ? nil : dailyAvgResponseTime,
            dailyAccountCosts: dailyAccountCosts.isEmpty ? nil : dailyAccountCosts,
            dailyHourCosts: dailyHourCosts.isEmpty ? nil : dailyHourCosts,
            latestMessageTimestamp: latestTs,
            dailySourceCosts: dailySourceCosts.isEmpty ? nil : dailySourceCosts,
            knownSourcesList: knownSources.isEmpty ? nil : knownSources
        )
    }

    // MARK: - Queries

    private func queryDailyBreakdown() throws -> ([DailyTokenTotals], [DailyModelBreakdown]) {
        let stmt = try prepare("""
            SELECT day, model,
                SUM(input_tokens), SUM(output_tokens),
                SUM(cache_read_tokens), SUM(cache_create_tokens), SUM(web_searches),
                SUM(cache_create_1h_tokens)
            FROM messages WHERE day != '' \(af)
            GROUP BY day, model ORDER BY day
        """)
        var byDay: [String: [String: (Int, Int, Int, Int, Int, Int)]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = colTxt(stmt, 0); let model = colTxt(stmt, 1)
            byDay[day, default: [:]][model] = (colInt(stmt,2), colInt(stmt,3), colInt(stmt,4), colInt(stmt,5), colInt(stmt,6), colInt(stmt,7))
        }
        sqlite3_finalize(stmt)

        var totals: [DailyTokenTotals] = []
        var breakdown: [DailyModelBreakdown] = []

        for (day, modelMap) in byDay.sorted(by: { $0.key < $1.key }) {
            let mts = modelMap.mapValues { t in
                ModelTokenStats(inputTokens: t.0, outputTokens: t.1,
                                cacheReadInputTokens: t.2, cacheCreationInputTokens: t.3,
                                webSearchRequests: t.4, costUSD: nil)
            }
            breakdown.append(DailyModelBreakdown(date: day, modelTokens: mts))

            let totIn  = modelMap.values.reduce(0) { $0 + $1.0 }
            let totOut = modelMap.values.reduce(0) { $0 + $1.1 }
            let totCR  = modelMap.values.reduce(0) { $0 + $1.2 }
            let totCC  = modelMap.values.reduce(0) { $0 + $1.3 }
            let totWS  = modelMap.values.reduce(0) { $0 + $1.4 }
            let cost   = modelMap.reduce(0.0) { s, p in
                s + ModelPricingTable.price(for: p.key)
                    .cost(input: p.value.0, output: p.value.1, cr: p.value.2,
                          cc5m: p.value.3 - p.value.5, cc1h: p.value.5)
            }
            let savings = modelMap.reduce(0.0) { s, p in
                let pr = ModelPricingTable.price(for: p.key)
                return s + max(0, Double(p.value.2) * (pr.inputPerMTok - pr.cacheReadPerMTok) / 1_000_000)
            }
            totals.append(DailyTokenTotals(date: day, inputTokens: totIn, outputTokens: totOut,
                                           cacheReadTokens: totCR, cacheCreateTokens: totCC,
                                           webSearchCount: totWS, estimatedCostUSD: cost, cacheSavingsUSD: savings))
        }
        return (totals, breakdown)
    }

    private func queryModelUsage() throws -> [String: ModelTokenStats] {
        let stmt = try prepare("""
            SELECT model, SUM(input_tokens), SUM(output_tokens),
                SUM(cache_read_tokens), SUM(cache_create_tokens), SUM(web_searches)
            FROM messages WHERE 1=1 \(af) GROUP BY model
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [String: ModelTokenStats] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = colTxt(stmt, 0)
            result[model] = ModelTokenStats(
                inputTokens: colInt(stmt,1), outputTokens: colInt(stmt,2),
                cacheReadInputTokens: colInt(stmt,3), cacheCreationInputTokens: colInt(stmt,4),
                webSearchRequests: colInt(stmt,5), costUSD: nil)
        }
        return result
    }

    private func queryDailyActivity() throws -> [DailyActivity] {
        let stmt = try prepare("""
            SELECT m.day,
                COUNT(*) AS msg_count,
                COUNT(DISTINCT m.session_id) AS sess_count,
                COALESCE(SUM(te.count), 0) AS tool_count
            FROM messages m
            LEFT JOIN (SELECT day, SUM(count) AS count FROM tool_events GROUP BY day) te
                ON te.day = m.day
            WHERE m.day != '' \(af("m"))
            GROUP BY m.day ORDER BY m.day
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [DailyActivity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(DailyActivity(
                date: colTxt(stmt,0), messageCount: colInt(stmt,1),
                sessionCount: colInt(stmt,2), toolCallCount: colInt(stmt,3)))
        }
        return result
    }

    private func queryHourCounts() throws -> [String: Int] {
        let stmt = try prepare("SELECT hour, COUNT(*) FROM messages WHERE 1=1 \(af) GROUP BY hour")
        defer { sqlite3_finalize(stmt) }
        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW { result["\(colInt(stmt,0))"] = colInt(stmt,1) }
        return result
    }

    private func queryDailyHourCounts() throws -> [String: [String: Int]] {
        let stmt = try prepare("""
            SELECT day, hour, COUNT(*) FROM messages WHERE day != '' \(af)
            GROUP BY day, hour ORDER BY day
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [String: [String: Int]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = colTxt(stmt,0)
            result[day, default: [:]]["\(colInt(stmt,1))"] = colInt(stmt,2)
        }
        return result
    }

    private func queryDailyHourCosts() throws -> [String: [String: Double]] {
        let stmt = try prepare("""
            SELECT day, hour, SUM(cost_usd) FROM messages WHERE day != '' \(af)
            GROUP BY day, hour ORDER BY day
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [String: [String: Double]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = colTxt(stmt, 0)
            result[day, default: [:]]["\(colInt(stmt, 1))"] = colDbl(stmt, 2)
        }
        return result
    }

    private func queryLatestMessageTimestamp() throws -> String? {
        let stmt = try prepare("SELECT MAX(timestamp) FROM messages WHERE 1=1 \(af)")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let ts = colTxt(stmt, 0)
        return ts.isEmpty ? nil : ts
    }

    private func queryDailyWorkHours() throws -> [DailyWorkHours] {
        let stmt = try prepare("""
            SELECT day, MIN(hour), MAX(hour) FROM messages
            WHERE day != '' \(af) GROUP BY day ORDER BY day
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [DailyWorkHours] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(DailyWorkHours(date: colTxt(stmt,0), firstHour: colInt(stmt,1), lastHour: colInt(stmt,2)))
        }
        return result
    }

    private func queryProjectStats() throws -> [ProjectStats] {
        let stmt = try prepare("""
            SELECT m.project,
                SUM(m.input_tokens), SUM(m.output_tokens),
                SUM(m.cache_read_tokens), SUM(m.cache_create_tokens), SUM(m.web_searches),
                COUNT(DISTINCT m.session_id), COUNT(*), SUM(m.cost_usd),
                COALESCE(g.session_lines, 0),
                COALESCE(g.lines_added, 0)
            FROM messages m
            LEFT JOIN git_stats_cache g ON g.project = m.project
            WHERE 1=1 \(af("m"))
            GROUP BY m.project ORDER BY SUM(m.cost_usd) DESC
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [ProjectStats] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ProjectStats(
                project: colTxt(stmt,0),
                inputTokens: colInt(stmt,1), outputTokens: colInt(stmt,2),
                cacheReadInputTokens: colInt(stmt,3), cacheCreationInputTokens: colInt(stmt,4),
                webSearchRequests: colInt(stmt,5), sessionCount: colInt(stmt,6),
                messageCount: colInt(stmt,7), estimatedCostUSD: colDbl(stmt,8),
                aiLinesWritten: colInt(stmt,9), gitLinesAdded: colInt(stmt,10)))
        }
        return result
    }

    private func queryDailyProjectCosts() throws -> [DailyProjectCosts] {
        let stmt = try prepare("""
            SELECT day, project, SUM(cost_usd), SUM(output_tokens), COUNT(*), SUM(web_searches)
            FROM messages WHERE day != '' \(af)
            GROUP BY day, project ORDER BY day
        """)
        defer { sqlite3_finalize(stmt) }
        var costs:   [String: [String: Double]] = [:]
        var outputs: [String: [String: Int]]    = [:]
        var msgs:    [String: [String: Int]]    = [:]
        var ws:      [String: [String: Int]]    = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = colTxt(stmt,0); let proj = colTxt(stmt,1)
            costs[day,   default: [:]][proj] = colDbl(stmt,2)
            outputs[day, default: [:]][proj] = colInt(stmt,3)
            msgs[day,    default: [:]][proj] = colInt(stmt,4)
            ws[day,      default: [:]][proj] = colInt(stmt,5)
        }
        let days = Set(costs.keys)
        return days.map { day in
            DailyProjectCosts(date: day, costs: costs[day] ?? [:], outputs: outputs[day] ?? [:],
                              messages: msgs[day] ?? [:], webSearches: ws[day] ?? [:])
        }.sorted { $0.date < $1.date }
    }

    private func querySessionAggregates() throws -> (Int, Int, LongestSessionInfo?, String?, Int) {
        var totalMessages = 0
        do {
            let s = try prepare("SELECT COUNT(*) FROM messages WHERE 1=1 \(af)")
            if sqlite3_step(s) == SQLITE_ROW { totalMessages = colInt(s,0) }
            sqlite3_finalize(s)
        }

        var totalSessions = 0
        do {
            let s = try prepare("SELECT COUNT(DISTINCT session_id) FROM messages WHERE 1=1 \(af)")
            if sqlite3_step(s) == SQLITE_ROW { totalSessions = colInt(s,0) }
            sqlite3_finalize(s)
        }

        var longestSession: LongestSessionInfo?
        do {
            let s = try prepare("SELECT session_id, COUNT(*) AS c FROM messages WHERE 1=1 \(af) GROUP BY session_id ORDER BY c DESC LIMIT 1")
            if sqlite3_step(s) == SQLITE_ROW {
                longestSession = LongestSessionInfo(sessionId: colTxt(s,0), duration: nil, messageCount: colInt(s,1), timestamp: nil)
            }
            sqlite3_finalize(s)
        }

        var firstDate: String?
        do {
            let s = try prepare("SELECT MIN(timestamp) FROM messages WHERE timestamp != '' \(af)")
            if sqlite3_step(s) == SQLITE_ROW {
                let v = colTxt(s,0); if !v.isEmpty { firstDate = v }
            }
            sqlite3_finalize(s)
        }

        var avgOut = 0
        do {
            let s = try prepare("""
                SELECT CAST(SUM(output_tokens) AS REAL) / NULLIF(COUNT(DISTINCT session_id),0)
                FROM messages WHERE 1=1 \(af)
            """)
            if sqlite3_step(s) == SQLITE_ROW { avgOut = Int(colDbl(s,0)) }
            sqlite3_finalize(s)
        }

        return (totalSessions, totalMessages, longestSession, firstDate, avgOut)
    }

    private func queryAgentCounts() throws -> (Int, Int) {
        var sub = 0, direct = 0
        let s = try prepare("SELECT is_subagent, COUNT(DISTINCT session_id) FROM messages WHERE 1=1 \(af) GROUP BY is_subagent")
        while sqlite3_step(s) == SQLITE_ROW {
            if colInt(s,0) == 1 { sub = colInt(s,1) } else { direct = colInt(s,1) }
        }
        sqlite3_finalize(s)
        return (sub, direct)
    }

    func querySessions() throws -> [SessionSummary] {
        let stmt = try prepare("""
            SELECT m.session_id, m.project, MIN(m.day), COUNT(*),
                SUM(m.output_tokens), SUM(m.cost_usd), MAX(m.is_subagent),
                (SELECT model FROM messages WHERE session_id = m.session_id
                 GROUP BY model ORDER BY COUNT(*) DESC LIMIT 1),
                f.rating
            FROM messages m
            LEFT JOIN feedback f ON f.session_id = m.session_id
            WHERE m.day != '' \(af("m"))
            GROUP BY m.session_id ORDER BY SUM(m.cost_usd) DESC
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [SessionSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rating: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : colInt(stmt, 8)
            result.append(SessionSummary(
                sessionId: colTxt(stmt, 0),
                project: colTxt(stmt, 1),
                firstDay: colTxt(stmt, 2),
                messageCount: colInt(stmt, 3),
                outputTokens: colInt(stmt, 4),
                costUSD: colDbl(stmt, 5),
                isSubagent: colInt(stmt, 6) == 1,
                topModel: colTxt(stmt, 7),
                rating: rating
            ))
        }
        return result
    }

    /// Export-only query: filters are expressed as explicit WHERE clauses so the
    /// export panel's own selectors are independent of the sidebar's live filters.
    func queryFilteredSessions(account: String?, project: String?, startDay: String?, endDay: String?) throws -> [SessionSummary] {
        var clauses: [String] = ["m.day != ''"]
        if let a = account, !a.isEmpty { clauses.append("m.account_uuid = '\(sqlQuote(a))'") }
        if let p = project, !p.isEmpty { clauses.append("m.project = '\(sqlQuote(p))'") }
        if let s = startDay, !s.isEmpty { clauses.append("m.day >= '\(sqlQuote(s))'") }
        if let e = endDay,   !e.isEmpty { clauses.append("m.day <= '\(sqlQuote(e))'") }
        let where_ = clauses.joined(separator: " AND ")
        let stmt = try prepare("""
            SELECT m.session_id, m.project, MIN(m.day), COUNT(*),
                SUM(m.output_tokens), SUM(m.cost_usd), MAX(m.is_subagent),
                (SELECT model FROM messages WHERE session_id = m.session_id
                 GROUP BY model ORDER BY COUNT(*) DESC LIMIT 1),
                f.rating
            FROM messages m
            LEFT JOIN feedback f ON f.session_id = m.session_id
            WHERE \(where_)
            GROUP BY m.session_id ORDER BY SUM(m.cost_usd) DESC
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [SessionSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rating: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : colInt(stmt, 8)
            result.append(SessionSummary(
                sessionId: colTxt(stmt, 0),
                project:   colTxt(stmt, 1),
                firstDay:  colTxt(stmt, 2),
                messageCount: colInt(stmt, 3),
                outputTokens: colInt(stmt, 4),
                costUSD:   colDbl(stmt, 5),
                isSubagent: colInt(stmt, 6) == 1,
                topModel:  colTxt(stmt, 7),
                rating:    rating
            ))
        }
        return result
    }

    func querySessionMessages(sessionId: String) throws -> [MessageDetail] {
        let stmt = try prepare("""
            SELECT timestamp, model, input_tokens, output_tokens,
                   cache_read_tokens, cache_create_tokens, web_searches, cost_usd, ai_lines
            FROM messages
            WHERE session_id = ? AND timestamp != ''
            ORDER BY timestamp ASC
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        var result: [MessageDetail] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(MessageDetail(
                timestamp:         colTxt(stmt, 0),
                model:             colTxt(stmt, 1),
                inputTokens:       colInt(stmt, 2),
                outputTokens:      colInt(stmt, 3),
                cacheReadTokens:   colInt(stmt, 4),
                cacheCreateTokens: colInt(stmt, 5),
                webSearches:       colInt(stmt, 6),
                costUSD:           colDbl(stmt, 7),
                aiLines:           colInt(stmt, 8)
            ))
        }
        return result
    }

    func queryAgentTypeCosts() throws -> (Double?, Double?) {
        var subCost: Double? = nil
        var dirCost: Double? = nil
        let s = try prepare("SELECT is_subagent, SUM(cost_usd) FROM messages WHERE 1=1 \(af) GROUP BY is_subagent")
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW {
            let cost = colDbl(s, 1)
            if colInt(s, 0) == 1 { subCost = cost } else { dirCost = cost }
        }
        return (subCost, dirCost)
    }

    func queryAccountCosts() throws -> [AccountCostBreakdown] {
        let stmt = try prepare("""
            SELECT m.account_uuid,
                   at.email, at.org_name, at.display_name, at.auth_type,
                   SUM(m.cost_usd), COUNT(*)
            FROM messages m
            JOIN (SELECT account_uuid, MAX(id) as mid FROM account_timeline GROUP BY account_uuid) latest
                ON latest.account_uuid = m.account_uuid
            JOIN account_timeline at ON at.id = latest.mid
            WHERE m.account_uuid IS NOT NULL
            GROUP BY m.account_uuid
            HAVING SUM(m.cost_usd) > 0
            ORDER BY SUM(m.cost_usd) DESC
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [AccountCostBreakdown] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid     = colTxt(stmt, 0)
            let email    = colTxt(stmt, 1)
            let org      = colTxt(stmt, 2)
            let dispName = colTxt(stmt, 3)
            let authType = colTxt(stmt, 4)
            let cost     = colDbl(stmt, 5)
            let msgs     = Int(sqlite3_column_int64(stmt, 6))
            let isOAuth  = authType == "oauth"
            let label    = isOAuth ? (dispName.isEmpty ? email : dispName) : "API Key"
            let subtitle = isOAuth ? org : "No OAuth account"
            result.append(AccountCostBreakdown(accountUuid: uuid, label: label,
                                               subtitle: subtitle, authType: authType,
                                               costUSD: cost, messageCount: msgs))
        }
        return result
    }

    private func queryDailyAccountCosts() throws -> [DailyAccountCosts] {
        let stmt = try prepare("""
            SELECT day, account_uuid, SUM(cost_usd), COUNT(*)
            FROM messages
            WHERE account_uuid IS NOT NULL \(af)
            GROUP BY day, account_uuid
            ORDER BY day
        """)
        defer { sqlite3_finalize(stmt) }
        var byCosts: [String: [String: Double]] = [:]
        var byMsgs:  [String: [String: Int]]    = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day  = colTxt(stmt, 0)
            let uuid = colTxt(stmt, 1)
            let cost = colDbl(stmt, 2)
            let msgs = Int(sqlite3_column_int64(stmt, 3))
            byCosts[day, default: [:]][uuid] = (byCosts[day]?[uuid] ?? 0) + cost
            byMsgs[day,  default: [:]][uuid] = (byMsgs[day]?[uuid]  ?? 0) + msgs
        }
        return byCosts.keys.sorted().map {
            DailyAccountCosts(date: $0, costs: byCosts[$0]!, messages: byMsgs[$0] ?? [:])
        }
    }

    private func queryDailySourceCosts() throws -> [DailySourceCosts] {
        let stmt = try prepare("""
            SELECT day, source, SUM(cost_usd), COUNT(*)
            FROM messages
            WHERE day != '' \(af)
            GROUP BY day, source
            ORDER BY day
        """)
        defer { sqlite3_finalize(stmt) }
        var byCosts: [String: [String: Double]] = [:]
        var byMsgs:  [String: [String: Int]]    = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = colTxt(stmt, 0)
            let src = colTxt(stmt, 1)
            byCosts[day, default: [:]][src] = colDbl(stmt, 2)
            byMsgs[day,  default: [:]][src] = colInt(stmt, 3)
        }
        return byCosts.keys.sorted().map {
            DailySourceCosts(date: $0, costs: byCosts[$0]!, messages: byMsgs[$0] ?? [:])
        }
    }

    func queryKnownSources() throws -> [String] {
        // Use account filter only (not source filter) so the picker always shows all sources
        let accountClause = accountFilter.map { "AND account_uuid = '\(sqlQuote($0))'" } ?? ""
        let stmt = try prepare("""
            SELECT DISTINCT source FROM messages
            WHERE source IS NOT NULL AND source != '' \(accountClause)
            ORDER BY source
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { result.append(colTxt(stmt, 0)) }
        return result
    }

    private func queryDailyAvgResponseTime() throws -> [String: Double] {
        let stmt = try prepare("""
            SELECT m.day,
                AVG(
                    CAST(strftime('%s', m.timestamp) AS REAL) -
                    CAST(strftime('%s', ut.timestamp) AS REAL)
                )
            FROM messages m
            JOIN user_turns ut
                ON ut.session_id = m.session_id
               AND ut.timestamp = (
                   SELECT MAX(ut2.timestamp)
                   FROM user_turns ut2
                   WHERE ut2.session_id = m.session_id
                     AND ut2.timestamp < m.timestamp
               )
            WHERE m.day != '' AND m.timestamp != '' \(af)
            GROUP BY m.day
            HAVING AVG(
                CAST(strftime('%s', m.timestamp) AS REAL) -
                CAST(strftime('%s', ut.timestamp) AS REAL)
            ) BETWEEN 0 AND 3600
            ORDER BY m.day
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [String: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[colTxt(stmt, 0)] = colDbl(stmt, 1)
        }
        return result
    }

    func queryKnownAccounts() throws -> [AccountInfo] {
        let stmt = try prepare("""
            SELECT at.account_uuid, at.email, at.org_name, at.display_name, at.auth_type
            FROM account_timeline at
            JOIN (SELECT account_uuid, MAX(id) as mid FROM account_timeline GROUP BY account_uuid) latest
                ON at.id = latest.mid
            ORDER BY latest.mid DESC
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [AccountInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(AccountInfo(
                accountUuid: colTxt(stmt, 0),
                email: colTxt(stmt, 1),
                orgName: colTxt(stmt, 2),
                displayName: colTxt(stmt, 3),
                authType: colTxt(stmt, 4)
            ))
        }
        return result
    }

    func queryKnownProjects() throws -> [String] {
        // Use account filter only (not project filter) so the picker always shows all projects
        let accountClause = accountFilter.map { "AND account_uuid = '\(sqlQuote($0))'" } ?? ""
        let stmt = try prepare("""
            SELECT DISTINCT project FROM messages
            WHERE project IS NOT NULL AND project != '' \(accountClause)
            ORDER BY project
        """)
        defer { sqlite3_finalize(stmt) }
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { result.append(colTxt(stmt, 0)) }
        return result
    }

    // MARK: - Git stats

    private func backfillSessionCwds() {
        // One-time operation: read first line of each known JSONL file to populate sessions.cwd
        var paths: [String] = []
        if let s = try? prepare("SELECT path FROM ingested_files") {
            while sqlite3_step(s) == SQLITE_ROW { paths.append(colTxt(s, 0)) }
            sqlite3_finalize(s)
        }
        guard !paths.isEmpty,
              let upd = try? prepare(
                "UPDATE sessions SET cwd = ? WHERE session_id = ? AND (cwd = '' OR cwd IS NULL)")
        else { return }
        defer { sqlite3_finalize(upd) }
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let text = String(data: data, encoding: .utf8),
                  let firstLine = text.split(separator: "\n", maxSplits: 1,
                                             omittingEmptySubsequences: true).first else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
                  let sid = obj["sessionId"] as? String, !sid.isEmpty,
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            bindTxt(upd, 1, cwd); bindTxt(upd, 2, sid)
            sqlite3_step(upd); sqlite3_reset(upd)
        }
    }

    // One-time backfill: recompute ai_lines for all already-ingested messages.
    // Reads each JSONL file once; guarded by UserDefaults so it only runs on first launch after upgrade.
    func backfillAiLines() throws {
        var paths: [String] = []
        let s = try prepare("SELECT path FROM ingested_files")
        while sqlite3_step(s) == SQLITE_ROW { paths.append(colTxt(s, 0)) }
        sqlite3_finalize(s)
        guard !paths.isEmpty else { return }

        let upd = try prepare(
            "UPDATE messages SET ai_lines = ? WHERE file_path = ? AND line_num = ? AND ai_lines = 0")
        defer { sqlite3_finalize(upd) }

        try execSQL("BEGIN")
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for (i, line) in lines.enumerated() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let content = msg["content"] as? [[String: Any]] else { continue }
                let ai = contentMetrics(content).aiLines
                guard ai > 0 else { continue }
                bindInt(upd, 1, ai); bindTxt(upd, 2, path); bindInt(upd, 3, i + 1)
                sqlite3_step(upd); sqlite3_reset(upd)
            }
        }
        try execSQL("COMMIT")
    }

    // One-shot after a pricing-table change: re-read the JSONLs to populate
    // cache_create_1h_tokens on historical rows, then recompute cost_usd for every
    // message with the current ModelPricingTable. Guarded by UserDefaults in MetricsStore.
    func backfillCacheTiersAndRecomputeCosts() throws {
        var paths: [String] = []
        let s = try prepare("SELECT path FROM ingested_files")
        while sqlite3_step(s) == SQLITE_ROW { paths.append(colTxt(s, 0)) }
        sqlite3_finalize(s)

        try execSQL("BEGIN")

        // Pass 1: populate cache_create_1h_tokens from usage.cache_creation
        let upd = try prepare("""
            UPDATE messages SET cache_create_1h_tokens = ?
            WHERE file_path = ? AND line_num = ? AND cache_create_1h_tokens = 0
            """)
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for (i, line) in lines.enumerated() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let detail = usage["cache_creation"] as? [String: Any],
                      let cc1h = detail["ephemeral_1h_input_tokens"] as? Int, cc1h > 0 else { continue }
                bindInt(upd, 1, cc1h); bindTxt(upd, 2, path); bindInt(upd, 3, i + 1)
                sqlite3_step(upd); sqlite3_reset(upd)
            }
        }
        sqlite3_finalize(upd)

        // Pass 2: recompute cost_usd for every row with the current price table
        var rows: [(rowid: Int, model: String, inp: Int, out: Int, cr: Int, cc: Int, cc1h: Int)] = []
        let q = try prepare("""
            SELECT rowid, model, input_tokens, output_tokens,
                   cache_read_tokens, cache_create_tokens, cache_create_1h_tokens
            FROM messages
            """)
        while sqlite3_step(q) == SQLITE_ROW {
            rows.append((colInt(q,0), colTxt(q,1), colInt(q,2), colInt(q,3), colInt(q,4), colInt(q,5), colInt(q,6)))
        }
        sqlite3_finalize(q)

        let costUpd = try prepare("UPDATE messages SET cost_usd = ? WHERE rowid = ?")
        defer { sqlite3_finalize(costUpd) }
        for r in rows {
            let cc1h = min(r.cc, r.cc1h)
            let cost = ModelPricingTable.price(for: r.model)
                .cost(input: r.inp, output: r.out, cr: r.cr, cc5m: r.cc - cc1h, cc1h: cc1h)
            bindDbl(costUpd, 1, cost); bindInt(costUpd, 2, r.rowid)
            sqlite3_step(costUpd); sqlite3_reset(costUpd)
        }

        try execSQL("COMMIT")
    }

    // One-shot for the dedup semantics change (first-wins → last-wins, per-file → global):
    // Pass A drops literal cross-file copies (compaction agent transcripts); Pass B re-reads
    // the JSONLs and, for requests streamed across multiple lines, applies the final
    // cumulative usage and the summed web_searches/ai_lines. Guarded in MetricsStore.
    func backfillDedupFinalUsage() throws {
        try execSQL("BEGIN")

        // Pass A: a request must own exactly one row — keep the earliest (the original
        // transcript), drop copies in other files. Same-file rows are already unique per
        // request, so any rn > 1 here is a cross-file copy.
        try execSQL("""
            DELETE FROM messages WHERE rowid IN (
                SELECT rowid FROM (
                    SELECT rowid, ROW_NUMBER() OVER (
                        PARTITION BY request_id ORDER BY timestamp, rowid
                    ) AS rn
                    FROM messages WHERE request_id != ''
                ) WHERE rn > 1
            )
            """)

        // Pass B: re-read the files; for requests with multiple usage-bearing lines,
        // take the LAST line's (cumulative) usage and the group's summed ws/ai_lines
        var paths: [String] = []
        let s = try prepare("SELECT path FROM ingested_files")
        while sqlite3_step(s) == SQLITE_ROW { paths.append(colTxt(s, 0)) }
        sqlite3_finalize(s)

        let upd = try prepare("""
            UPDATE messages SET
                input_tokens = ?, output_tokens = ?, cache_read_tokens = ?,
                cache_create_tokens = ?, cache_create_1h_tokens = ?,
                web_searches = ?, ai_lines = ?, cost_usd = ?
            WHERE file_path = ? AND request_id = ?
            """)
        defer { sqlite3_finalize(upd) }

        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let text = String(data: data, encoding: .utf8) else { continue }

            struct Group {
                var lines = 0
                var model = ""
                var input = 0, output = 0, cr = 0, cc = 0, cc1h = 0
                var ws = 0, aiLines = 0
            }
            var groups: [String: Group] = [:]

            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let rid = obj["requestId"] as? String, !rid.isEmpty,
                      let msg = obj["message"] as? [String: Any] else { continue }
                let usage  = msg["usage"] as? [String: Any] ?? [:]
                let input  = usage["input_tokens"]                as? Int ?? 0
                let output = usage["output_tokens"]               as? Int ?? 0
                let cr     = usage["cache_read_input_tokens"]     as? Int ?? 0
                let cc     = usage["cache_creation_input_tokens"] as? Int ?? 0
                guard input + output + cr + cc > 0 else { continue }
                let ccDetail = usage["cache_creation"] as? [String: Any] ?? [:]
                let cc1h = min(cc, ccDetail["ephemeral_1h_input_tokens"] as? Int ?? 0)
                let metrics = contentMetrics(msg["content"] as? [[String: Any]] ?? [])

                var g = groups[rid] ?? Group()
                g.lines += 1
                g.model = msg["model"] as? String ?? "unknown"
                g.input = input; g.output = output; g.cr = cr; g.cc = cc; g.cc1h = cc1h
                g.ws += metrics.webSearches
                g.aiLines += metrics.aiLines
                groups[rid] = g
            }

            for (rid, g) in groups where g.lines > 1 {
                let cost = ModelPricingTable.price(for: g.model)
                    .cost(input: g.input, output: g.output, cr: g.cr, cc5m: g.cc - g.cc1h, cc1h: g.cc1h)
                bindInt(upd, 1, g.input);  bindInt(upd, 2, g.output)
                bindInt(upd, 3, g.cr);     bindInt(upd, 4, g.cc)
                bindInt(upd, 5, g.cc1h);   bindInt(upd, 6, g.ws)
                bindInt(upd, 7, g.aiLines); bindDbl(upd, 8, cost)
                bindTxt(upd, 9, path);     bindTxt(upd, 10, rid)
                sqlite3_step(upd); sqlite3_reset(upd)
            }
        }

        try execSQL("COMMIT")
    }

    func updateGitStats() throws {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        func parseDate(_ str: String) -> Date? { isoFrac.date(from: str) ?? isoPlain.date(from: str) }

        // Collect (project, cwd, first_session_day)
        let ps = try prepare("""
            SELECT s.project, s.cwd, MIN(m.day)
            FROM sessions s JOIN messages m ON m.project = s.project
            WHERE s.cwd != '' AND s.cwd IS NOT NULL AND m.day != ''
            GROUP BY s.project, s.cwd
        """)
        var projectMeta: [(proj: String, cwd: String, since: String)] = []
        while sqlite3_step(ps) == SQLITE_ROW {
            let p = colTxt(ps, 0); let c = colTxt(ps, 1); let d = colTxt(ps, 2)
            if !p.isEmpty && !c.isEmpty { projectMeta.append((p, c, d)) }
        }
        sqlite3_finalize(ps)
        guard !projectMeta.isEmpty else { return }

        // Collect session time windows per project for the numerator
        let ws = try prepare("""
            SELECT m.project, MIN(m.timestamp), MAX(m.timestamp)
            FROM messages m
            JOIN sessions s ON s.session_id = m.session_id
            WHERE m.timestamp != '' AND s.cwd != '' AND s.cwd IS NOT NULL
            GROUP BY m.session_id, m.project
        """)
        var sessionWindows: [String: [(start: Date, end: Date)]] = [:]
        while sqlite3_step(ws) == SQLITE_ROW {
            let proj  = colTxt(ws, 0)
            guard let start = parseDate(colTxt(ws, 1)),
                  let end   = parseDate(colTxt(ws, 2)) else { continue }
            sessionWindows[proj, default: []].append((start: start, end: end))
        }
        sqlite3_finalize(ws)

        // Load cached state to skip unchanged projects
        let cs = try prepare("SELECT project, head_hash, since_date, session_lines FROM git_stats_cache")
        var cachedHead:         [String: String] = [:]
        var cachedSince:        [String: String] = [:]
        var cachedSessionLines: [String: Int]    = [:]
        while sqlite3_step(cs) == SQLITE_ROW {
            let p = colTxt(cs, 0)
            cachedHead[p]         = colTxt(cs, 1)
            cachedSince[p]        = colTxt(cs, 2)
            cachedSessionLines[p] = colInt(cs, 3)
        }
        sqlite3_finalize(cs)

        let upsert = try prepare("""
            INSERT OR REPLACE INTO git_stats_cache(project,cwd,lines_added,session_lines,head_hash,since_date,updated_at)
            VALUES(?,?,?,?,?,?,?)
        """)
        defer { sqlite3_finalize(upsert) }
        let now = ISO8601DateFormatter().string(from: Date())

        for (proj, cwd, since) in projectMeta {
            guard FileManager.default.fileExists(atPath: cwd) else { continue }
            let head = gitRun(cwd: cwd, args: ["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty, !head.hasPrefix("fatal") else { continue }
            // Skip if HEAD, since_date unchanged and session_lines already populated
            let alreadyComputed = (cachedSessionLines[proj] ?? 0) > 0
            if cachedHead[proj] == head && cachedSince[proj] == since && alreadyComputed { continue }

            // Denominator: all git lines added since first Claude session
            let linesAdded = gitLinesAdded(cwd: cwd, since: since)

            // Numerator: git lines committed during Claude session windows (+ 30 min buffer)
            let windows = sessionWindows[proj] ?? []
            let merged  = mergeWindows(windows, bufferSeconds: 1800)
            let sessionLines = gitLinesInWindows(cwd: cwd, windows: merged)

            bindTxt(upsert, 1, proj);        bindTxt(upsert, 2, cwd)
            bindInt(upsert, 3, linesAdded);  bindInt(upsert, 4, sessionLines)
            bindTxt(upsert, 5, head);        bindTxt(upsert, 6, since)
            bindTxt(upsert, 7, now)
            sqlite3_step(upsert); sqlite3_reset(upsert)
        }
    }

    private func mergeWindows(_ windows: [(start: Date, end: Date)], bufferSeconds: Int) -> [(start: Date, end: Date)] {
        guard !windows.isEmpty else { return [] }
        let buffer = TimeInterval(bufferSeconds)
        let sorted = windows.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = [(sorted[0].start, sorted[0].end.addingTimeInterval(buffer))]
        for w in sorted.dropFirst() {
            let bufferedEnd = w.end.addingTimeInterval(buffer)
            if w.start <= merged[merged.count - 1].end {
                if bufferedEnd > merged[merged.count - 1].end {
                    merged[merged.count - 1] = (merged[merged.count - 1].start, bufferedEnd)
                }
            } else {
                merged.append((w.start, bufferedEnd))
            }
        }
        return merged
    }

    private func gitLinesInWindows(cwd: String, windows: [(start: Date, end: Date)]) -> Int {
        guard !windows.isEmpty else { return 0 }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        var total = 0
        for w in windows {
            let after = fmt.string(from: w.start)
            let until = fmt.string(from: w.end)
            let out = gitRun(cwd: cwd, args: ["log", "--numstat", "--pretty=", "--no-merges",
                                              "--after=\(after)", "--until=\(until)"])
            total += out.split(separator: "\n").reduce(0) { sum, line in
                let parts = line.split(separator: "\t")
                guard parts.count >= 2, parts[0] != "-", let n = Int(parts[0]) else { return sum }
                return sum + n
            }
        }
        return total
    }

    // Count lines inside bash heredoc blocks (cat > file << 'EOF' ... EOF)
    // Handles any delimiter name and optional quoting/dashes
    private func bashHeredocLineCount(_ command: String) -> Int {
        let lines = command.components(separatedBy: "\n")
        var total = 0
        var endMarker: String? = nil
        for line in lines {
            if let marker = endMarker {
                if line.trimmingCharacters(in: .whitespaces) == marker { endMarker = nil }
                else { total += 1 }
            } else {
                // Detect << or <<- followed by optional quotes and word
                if let match = line.range(of: #"<<-?\s*['"´]?(\w+)['"´]?"#, options: .regularExpression) {
                    let raw = String(line[match])
                    let marker = raw
                        .replacingOccurrences(of: #"^<<-?\s*"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\"´ \t"))
                    if !marker.isEmpty { endMarker = marker }
                }
            }
        }
        return total
    }

    private func gitRun(cwd: String, args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func gitLinesAdded(cwd: String, since: String = "") -> Int {
        var args = ["log", "--numstat", "--pretty=", "--no-merges"]
        if !since.isEmpty { args += ["--since=\(since)"] }
        let out = gitRun(cwd: cwd, args: args)
        return out.split(separator: "\n").reduce(0) { sum, line in
            let parts = line.split(separator: "\t")
            guard parts.count >= 2, parts[0] != "-", let n = Int(parts[0]) else { return sum }
            return sum + n
        }
    }
}
