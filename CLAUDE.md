# ArgusAI

Native macOS app (dark/light adaptive) that monitors Claude Code usage metrics in real time.

## Build & Run

```bash
bash build.sh          # compile
open ArgusAI.app       # run
```

**NEVER use `swift build`** — the project uses a hand-written `build.sh` with an explicit `SOURCES` array.  
When adding a new `.swift` file, add it to the `SOURCES=(...)` list in `build.sh`.

`GoogleCredentials.swift` is **gitignored** and must exist locally for the build to succeed (it defines the `GoogleDriveConfig` credential extension). Copy the template before building on a new machine:
```bash
cp Sources/ClaudeMetrics/GoogleCredentials.swift.example \
   Sources/ClaudeMetrics/GoogleCredentials.swift
# fill in your own Client ID and Secret — see README § Google Drive Export
```

Build target is **macOS 26** (`-target arm64-apple-macosx26.0`). Required for Liquid Glass APIs (`glassEffect`).

## Tests

```bash
bash Tests/run_tests.sh
```

Standalone harness (no SPM/XCTest): compiles `Models.swift` + `Theme.swift` + `Tests/main.swift` with `swiftc` and runs the binary (exit 1 on failure). Covers pure logic only: `ModelPricingTable` (cost math, lookup fallbacks, external overrides), `buildSessionsCSV`/`buildSessionsJSON`, formatters. Keep `Tests/main.swift` free of dependencies on other source files so it stays fast to compile.

## Release

```bash
bash release.sh 1.2.0   # oppure senza argomento: chiede la versione interattivamente
```

`release.sh` esegue in ordine:
1. **Flight checklist** — verifica `swiftc`, `git`, `codesign`, `gh`; installa Homebrew e gh CLI se mancanti; controlla autenticazione GitHub e che il tag non esista già
2. **Build** — `bash build.sh` (firma ad-hoc inclusa)
3. **Zip** — `ditto -c -k --keepParent ArgusAI.app ArgusAI-vX.Y.Z-YYYYMMDD.zip`
4. **Fingerprint** — SHA256 + MD5 del zip (salvati anche in `.sha256`)
5. **Tag Git** — `git tag -a vX.Y.Z` + push su origin
6. **GitHub Release** — `gh release create` con zip allegato e note complete (changelog automatico, tabella hash, istruzioni Gatekeeper)

> `dist.sh` crea solo lo zip locale senza pubblicare — utile per distribuire manualmente.

## Architecture

| File | Role |
|---|---|
| `Models.swift` | All Codable structs (`StatsCache`, `DailyTokenTotals`, `DailyModelBreakdown`, `DailyProjectCosts`, `DailyAccountCosts`, `SessionMessageDetail`, `ProjectAlertThreshold`, …) |
| `Database.swift` | `ArgusDB` — SQLite ingestion + all KPI queries; owns `~/.claude/argusai.db` |
| `MetricsStore.swift` | `ObservableObject` — calls `ArgusDB`, owns all state and computed properties |
| `ContentView.swift` | Navigation shell (sidebar + `NavSection` enum); `OnboardingView` for first-run empty state |
| `OverviewView.swift` | Summary KPIs + charts; `DailyCostExplainView` popover (click-to-explain on Daily Cost chart) |
| `ModelsView.swift` | Per-model token breakdown |
| `ActivityView.swift` | Daily activity chart, day-of-week, streak |
| `ScheduleView.swift` | Hourly distribution, top hours, work-hour bars |
| `ProjectsView.swift` | Per-project cost/token table and chart |
| `SessionsView.swift` | Per-session table; click any row → `SessionDetailView` sheet |
| `SessionDetailView.swift` | Per-message breakdown sheet (TIME/MODEL/INPUT/OUTPUT/CACHE R/CACHE W/COST/AI LINES + totals footer) |
| `SettingsView.swift` | Cmd+, preferences window: General (color scheme), Alerts (global + per-project), Pricing (table + external file status) |
| `PlatformView.swift` | Platform KPIs tab (operational metrics, response time, cost per user) |
| `ExportView.swift` | Cmd+E export sheet — filters (project, account, date range), format (CSV/JSON), destination (local / Google Drive) |
| `GoogleDriveService.swift` | OAuth2 PKCE + Drive API upload; token storage in Keychain; `GoogleDriveConfig` enum (scheme, endpoints) |
| `GoogleCredentials.swift` | **gitignored** — `extension GoogleDriveConfig` with `clientID`/`clientSecret`; copy from `GoogleCredentials.swift.example` |
| `Components.swift` | Shared UI components (`MetricCard`, `SectionCard`, `DeltaBadge`, `ChartCrosshair`, …) |
| `Theme.swift` | Adaptive color palette via `NSColor(dynamicProvider:)`; `Color.appAccent`, `modelDisplayName()`, `formatTokens()` |
| `Sources/CSQLite/` | Module map + shim header that bridges system `libsqlite3` into Swift |

## Data pipeline

```
~/.claude/projects/**/*.jsonl                                       ┐
~/Library/Application Support/Claude/local-agent-mode-sessions/     ├→  ArgusDB.ingestFiles()  →  ~/.claude/argusai.db  →  ArgusDB.buildStatsCache()  →  views
    <org>/<user>/local_*/.claude/projects/**/*.jsonl  (Cowork)      ┘
```

- JSONL files are the source of truth (written by Claude Code / Cowork, never modified by ArgusAI).
- **Sources**: every message carries `messages.source` (`claude_code` | `cowork`) derived from which root the file came from. Cowork = local agent-mode sessions of the Claude desktop app — same JSONL format as Claude Code. All Cowork sessions are grouped under a single project named **"Cowork"** (their cwd is a meaningless sandbox path). Cowork discovery uses a targeted walk (`org → user → local_* → .claude/projects`) in `MetricsStore.coworkJSONLFiles()` — never enumerate the whole `local-agent-mode-sessions` tree (sibling dirs hold plugin caches and outputs). **Caveat**: Cowork sessions that run on claude.ai cloud infrastructure leave no local JSONL and cannot be tracked.
- `ArgusDB` tracks `lines_processed` per file in the `ingested_files` table — only new lines are read on each 3s refresh.
- `ingestFiles()` returns an `IngestReport` (unreadable files + malformed lines skipped); `MetricsStore` accumulates the counters (`ingestSkippedLines`/`ingestUnreadableFiles`) and the sidebar footer shows an orange warning when > 0.
- All KPI queries run as SQL against indexed tables; **never re-parse JSONL in Swift**.
- Ingestion uses `INSERT OR REPLACE` (not `INSERT OR IGNORE`) so that corrected fields (e.g. `web_searches`) are always up to date on re-ingest.
- **Dedup**: Claude Code writes multiple `assistant` lines per `requestId` while streaming (one per content block) with **cumulative** usage — the last line has the final token counts. `ingestFiles()` keeps a **global** `seenRequests: [rid → (file, line)]` map (lazy pre-seed from DB): same rid in the same file → UPDATE the kept row with last-wins tokens and **additive** `web_searches`/`ai_lines`; same rid in a different file (compaction agent copies) → skip. The rid is registered only after the `usage > 0` guard, so a zero-usage first line can't shadow the real one. One-shots: `argusai.dedupRequestIds.v1` (legacy, by `(session_id, timestamp)`) and `argusai.dedupFinalUsage.v1` (drops cross-file copies, applies final cumulative usage).
- **Cost estimation**: JSONL files do NOT contain a `costUSD` field. ArgusAI estimates costs using `ModelPricingTable` (public API prices). Actual billing may differ by ~10–15% due to plan pricing, billing cycle, or cache tier differences. An external override file `~/.claude/argus_pricing.json` can override per-model prices.

### Adding a new data point

1. Add a column to `messages` in the schema string inside `Database.swift`
2. Populate it in the ingestion loop (Pass 2, the `type == "assistant"` branch)
3. Add a query method and wire it into `buildStatsCache()`
4. Add the field to `StatsCache` in `Models.swift`
5. Add a `filteredXxx` computed property in `MetricsStore.swift`

### DB schema (key tables)

| Table | Key columns |
|---|---|
| `messages` | `(file_path, line_num)` PK · `session_id` · `day` · `hour` · `model` · `input/output/cr/cc/ws tokens` · `cache_create_1h_tokens` (1h-TTL share of cc) · `cost_usd` · `project` · `is_subagent` · `account_uuid` · `request_id` · `source` (`claude_code`\|`cowork`) |
| `sessions` | `session_id` PK · `project` · `is_subagent` |
| `tool_events` | `(file_path, line_num)` PK · `session_id` · `day` · `count` |
| `user_turns` | `(file_path, line_num)` PK · `session_id` · `timestamp` · `day` — human-typed messages, used for response time |
| `ingested_files` | `path` PK · `lines_processed` |
| `account_timeline` | `id` PK · `account_uuid` · `email` · `org_name` · `display_name` · `auth_type` · `recorded_at` |

Relevant JSONL fields ingested (on `type == "assistant"` lines):
- `message.usage.{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}`
- `message.content[].{type, name}` — tool_use blocks; `name == "WebSearch"` counted as `web_searches`
- `message.model`
- `sessionId`, `timestamp`, `cwd`

> **Note on web searches:** `message.usage.server_tool_use.web_search_requests` is always 0 in Claude Code JSONL. Actual searches are `tool_use` content blocks with `name == "WebSearch"`. The ingestion loop counts those instead.

Relevant JSONL fields ingested (on `type == "user"` lines):
- Human-typed turns (content blocks with `type == "text"`, excluding `tool_result`) → `user_turns` table for response time calculation.

## Multi-account support

ArgusAI tracks **which account/key is active** on every 3-second refresh and associates each ingested message with it via `messages.account_uuid`.

### Auth detection priority (mirrors Claude Code)
1. `ANTHROPIC_API_KEY` env var → `api_key_<last8chars>`
2. `apiKeyHelper` in `~/.claude/settings.json` → `api_key_helper_<hash>`
3. Keychain service `"Claude Code"` / `"Claude Code-credentials"` (API key stored via `/config`) → `api_key_<last8chars>`
4. OAuth from `~/.claude.json` → `oauthAccount.accountUuid`
5. Fallback → `api_key_user`

API key and OAuth are **separate entity types**. A user with 3 API keys + 2 OAuth accounts produces 5 distinct identities in the DB.

### account_timeline
Every time the active account changes, a new row is written to `account_timeline`. `ArgusDB.recordAccount()` compares the last UUID and inserts only on change.

### Historical claim (one-shot)
On first run with the new code, `ArgusDB.claimHistoricalMessages(for:)` runs `UPDATE messages SET account_uuid = ? WHERE account_uuid IS NULL` for the current account. Guarded by `argusai.historicalClaimDone` in UserDefaults — never runs again.

### Account filter
`MetricsStore.accountFilter: String?` (nil = all) is set by the sidebar picker. Before `buildStatsCache()`, `db.accountFilter` is set — all SQL queries inject `AND account_uuid = '...'` via the `af` / `af(_ alias:)` helpers in `ArgusDB`. Changing `accountFilter` triggers a silent reload.

The sidebar "ACCOUNT" section is only shown when `knownAccounts.count > 1`.

### Project filter
`MetricsStore.projectFilter: String?` (nil = all) is set by the sidebar PROJECT picker. Before `buildStatsCache()`, `db.projectFilter` is set — all SQL queries inject `AND project = '...'` via the same `af` / `af(_ alias:)` helpers (which now combine both account and project clauses). Changing `projectFilter` triggers a silent reload.

`ArgusDB.queryKnownProjects()` fetches distinct project names using only the account filter (not the project filter) so the PROJECT picker always lists all available projects. `StatsCache.knownProjectsList: [String]?` carries the list; `MetricsStore.knownProjects` is updated on every refresh.

The sidebar "PROJECT" section is only shown when `knownProjects.count > 1`.

### Source filter
`MetricsStore.sourceFilter: String?` (nil = all) is set by the sidebar SOURCE picker — same mechanics as the project filter (`db.sourceFilter` → `AND source = '...'` via the `af` helpers; `queryKnownSources()` ignores the source filter so the picker always lists all sources). Display names/icons come from `sourceDisplayName()` / `sourceIconName()` in `Theme.swift`. The sidebar "SOURCE" section is only shown when `knownSources.count > 1`.

## Date filtering

`MetricsStore.dateFilter: DateFilter` (`.today` / `.sevenDays` / `.thirtyDays` / `.all` / `.custom` / `.cycle`) drives all views.

`.cycle` mirrors the subscription billing window of the desktop "$ of $200" counter: `MetricsStore.billingCycleResetDay` (1–28, UserDefaults `argusai.billingCycleResetDay`, nil = off, set in Settings → General) → `billingCycleStart` computes the most recent reset day → `dateFilterWindow` returns `[start, ∞)`. The sidebar shows a "Billing Cycle" row only when a reset day is configured; no week-over-week delta (like `.custom`).

**Pattern:** every KPI has a `filteredXxx` computed property in `MetricsStore` that slices the relevant `[DailyXxx]` array from `StatsCache` by date, then aggregates. Never read raw all-time stats directly in views; always use the `filtered*` variant.

The date window logic is centralized in `MetricsStore`:
- `dateFilterWindow: Range<Date>?` — half-open `[start, end)` window for the current filter (`nil` = `.all`, no filtering). The **only** place that switches on `dateFilter`.
- `previousPeriodWindow: Range<Date>?` — same window shifted back one period for week-over-week deltas (`nil` for `.all`/`.custom`).
- `slice(_:in:day:)` — filters an array by a "yyyy-MM-dd" key path; `slice(_:in:)` does the same for `[String: V]` dictionaries keyed by day.

**When adding a new filter-aware property, do NOT write a `switch dateFilter` — call `slice(stats?.xxx ?? [], in: dateFilterWindow) { $0.date }`.**

### Custom date range
`.custom` is set when the user picks dates via the "Da / Al" `DatePicker` rows in the sidebar. `MetricsStore` owns `customStartDate` and `customEndDate` (date-only, no time). All 11 filter switch statements handle `.custom` as `>= startOfDay(from) && < startOfDay(to+1)`. Week-over-week switches return `[]` for `.custom` (no delta badge). The segmented picker uses `DateFilter.presets` (not `allCases`) so `.custom` never appears as a segment.

## Window & UI style

- Borderless window: `.windowStyle(.hiddenTitleBar)` in `ClaudeMetricsApp.swift` + `WindowConfigurator` (NSViewRepresentable) in `ContentView.swift`
- Sidebar top padding is **38pt** to clear the traffic light buttons
- Cards use **macOS 26 Liquid Glass**: `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))` — use this for any new card component, never `Color.appSurface` + clipShape

### Sidebar structure (`ContentView.swift`)

```
[Fixed] Logo header (38pt top padding)
[ScrollView] Account chip · Nav items · filter sections
[Fixed] Footer (last updated · Refresh button)
```

- **Never** use a segmented picker in the sidebar — use `SidebarFilterRow` rows (same visual language as nav items)
- **Never** use `Color.appBorder.frame(height: 1)` as section separator — use `SidebarSectionLabel` + padding
- All filter content (TIME RANGE, DAILY LIMIT, ACCOUNT, SOURCE, PROJECT) lives inside the `ScrollView` so it never overflows with many projects
- New filter sections: add a `SidebarSectionLabel("MY SECTION")` + `VStack` of `SidebarFilterRow` buttons, padded `.horizontal, 8`

When adding a new filter-aware property, use the `slice(_:in:day:)` + `dateFilterWindow` helpers in `MetricsStore` (see § Date filtering) — never duplicate the `switch dateFilter` logic.

Key per-day structures stored in `StatsCache`:
| Field | Used for |
|---|---|
| `dailyTotals: [DailyTokenTotals]` | Overview KPIs (cost, tokens, cache, web searches) |
| `dailyModelBreakdown: [DailyModelBreakdown]` | Models tab |
| `dailyHourCounts: [String: [String: Int]]` | Schedule tab hourly message chart |
| `dailyHourCosts: [String: [String: Double]]?` | Schedule tab — Cost per Hour chart |
| `dailyProjectCosts: [DailyProjectCosts]` | Projects tab |
| `dailyWorkHours: [DailyWorkHours]` | Schedule work-hour bars |
| `dailyActivity: [DailyActivity]` | Activity chart, day-of-week, streak |
| `dailyAccountCosts: [DailyAccountCosts]` | Platform tab — Cost per User (filter-aware) |
| `sessions: [SessionSummary]?` | Sessions tab |
| `subagentCostUSD: Double?` | Agent Type breakdown |
| `directCostUSD: Double?` | Agent Type breakdown |
| `dailyAvgResponseTimeSec: [String: Double]?` | Platform tab — Response Time chart |
| `latestMessageTimestamp: String?` | Menu bar live-activity indicator |

## Adaptive chart aggregation

`MetricsStore.platformChartData: [TokenChartPoint]` applies adaptive aggregation based on the number of daily data points in the current filter window. Each `TokenChartPoint` carries `label`, `inputTokens`, `outputTokens`, and `costUSD` so both the Token Trend and Daily Cost charts share the same aggregated data without duplication.

| Daily data points | Aggregation | Label format |
|---|---|---|
| ≤ 14 | Daily (as-is) | `MMM d` |
| 15 – 90 | Weekly (ISO week, first day label) | `MMM d` |
| > 90 | Monthly | `MMM` / `MMM 'yy` (multi-year) |

## Features

| Feature | Where |
|---|---|
| **Platform tab** | `PlatformView.swift` — Total Cost, Total Requests, Avg Cost/Req, Avg Context/Req, Avg Output/Req, Token Trend, Daily Cost, Response Time, Cost per User |
| **Response Time** | `user_turns` table + correlated subquery in `queryDailyAvgResponseTime()`; measures human message → first assistant token |
| **Sessions tab** | `SessionsView.swift` — per-session table with search field + sortable columns (DATE/MSGS/OUTPUT/COST); `visibleSessions` paginates via `sessionDisplayLimit` (default 100); "Load more" button appears when there are more results |
| **Menu bar extra** | `ClaudeMetricsApp.swift` — `MenuBarExtra` with today cost+msgs, week cost, alert dot; live-activity indicator (green dot + filled waveform icon) when a message was ingested in the last 60 seconds |
| **Delta badges** | `DeltaBadge` in `Components.swift`; `costDeltaPct`/`messagesDeltaPct` in `MetricsStore` (week-over-week); no delta for `.custom` filter |
| **Daily limit alert** | `alertThreshold` (`@Published`, persisted in UserDefaults); `UNNotificationCenter` fires once per day when today's cost ≥ threshold |
| **Weekly summary notification** | `scheduleWeeklySummaryIfNeeded()` — fires every Monday 09:00 with last-7-days cost + message count; guarded by week key in UserDefaults |
| **Forecast** | `burnRatePerDay`, `currentMonthCost`, `daysLeftInMonth`, `projectedMonthCost` in `MetricsStore` |
| **Agent Type breakdown** | `filteredSubagentCost`, `filteredDirectCost` in `MetricsStore`; two-segment bar in `OverviewView` |
| **Filtered export** | `ExportView.swift` — Cmd+E sheet; filters: project, account (if >1), date range; formats CSV+JSON; destinations: local (`NSSavePanel`/`NSOpenPanel`) or Google Drive (OAuth2 upload); `store.performExport(...)` orchestrator in `MetricsStore`; `buildSessionsCSV`/`buildSessionsJSON` pure builders reused by legacy `exportCSV`/`exportJSON` |
| **Google Drive OAuth** | `GoogleDriveService.swift` — PKCE flow via `ASWebAuthenticationSession`; scopes `drive.file openid email`; tokens in Keychain service `"ArgusAI-GoogleDrive"`; `uploadFile(name:data:mimeType:folderID:)` via multipart Drive API v3; `folderID(from:)` parses folder URL/ID; credentials in gitignored `GoogleCredentials.swift` (copy from `.example`) |
| **Daily Cost chart** | `OverviewDailyCostChart` in `OverviewView` (golden area+line); also in `PlatformView` as bar chart with adaptive aggregation |
| **Multi-account tracking** | `account_timeline` table + `messages.account_uuid`; `readCurrentAccount()` in `MetricsStore`; account chip in sidebar |
| **Account filter** | `MetricsStore.accountFilter` → `ArgusDB.accountFilter` → SQL `AND account_uuid = '...'` on all queries; sidebar picker (hidden if single account) |
| **Account cost breakdown** | `queryAccountCosts()` → `StatsCache.accountCosts`; multi-segment bar in `OverviewView` "By Account" card |
| **Source tracking (Cowork)** | `messages.source` column; `queryDailySourceCosts()` → `StatsCache.dailySourceCosts` → `MetricsStore.filteredSourceCosts`; "By Source" card in `OverviewView` (shown when >1 source); sidebar SOURCE filter |
| **Filtered Cost per User** | `MetricsStore.filteredAccountCosts` — aggregates `DailyAccountCosts` by date range; shows cost + message count per account |
| **Best Streak** | `longestStreak` in `MetricsStore` — longest ever consecutive-day run; shown as "Best Streak" card (trophy) in `ActivityView` |
| **Output/Context Ratio** | `filteredEfficiencyTrend` in `MetricsStore` — daily ratio of output tokens to total context tokens; line+area chart in `ActivityView` |
| **Cost per Hour** | `queryDailyHourCosts()` → `dailyHourCosts` → `filteredHourlyCosts`; gold bar chart "Cost per Hour of Day" in `ScheduleView` |
| **Chart tooltips** | `chartXSelection` + overlay on `ActivityBarChart` (date → msg count) and `HourlyBarChart` (hour → msg count) |
| **Sortable Projects table** | `ProjectSortKey` enum + `sorted` computed var in `ProjectTable`; click any column header (PROJECT/MSG/OUTPUT/COST/WEB/% AI) to sort |
| **Custom date range** | "Da / Al" `DatePicker` rows in sidebar (indented under "Custom" `SidebarFilterRow`); selecting a date activates `.custom` filter; clicking a preset deactivates it |
| **Billing Cycle preset** | `DateFilter.cycle` + `billingCycleResetDay` (Settings → General, 1–28) → "Billing Cycle" row in sidebar TIME RANGE; window = most recent reset day → today, mirrors the desktop "$ of $200" counter |
| **Chart crosshair** | `ChartCrosshair` helper in `Components.swift` — vertical + horizontal dashed lines, intersection dot, floating tooltip; applied to all line charts (Daily Messages, Daily Cost, Daily Cost Trend, Output/Context Ratio, Token Trend) |
| **Click-to-explain** | `DailyCostExplainView` popover in `OverviewView.swift`; clicking the Daily Cost chart opens a breakdown by model + project, raw SQL, copy button |
| **Session detail view** | Click any row in Sessions tab → `SessionDetailView` sheet; per-message breakdown (time, model, all token types, cost, ai_lines); footer row with session totals; data from `ArgusDB.querySessionMessages(sessionId:)` |
| **Settings window** | `SettingsView.swift` — Cmd+,; three tabs: General (color scheme System/Dark/Light via `@AppStorage("argusai.colorScheme")`), Alerts (global daily + per-project monthly thresholds), Pricing (built-in price table + external file `~/.claude/argus_pricing.json` status + estimate disclaimer) |
| **Per-project monthly alerts** | `store.projectAlertThresholds: [String: Double]` (UserDefaults JSON); `checkAlerts()` fires once per month per project when spend ≥ limit; key pattern `argusai.projectAlert.<project>.<yyyy-MM>` |
| **External pricing override** | `~/.claude/argus_pricing.json` — JSON object `{ "model-id": { inputPerMTok, outputPerMTok, cacheReadPerMTok, cacheWritePerMTok } }`; loaded once at startup into `ModelPricingTable.externalOverrides`; restart app to apply |
| **Dark/Light mode** | Colors in `Theme.swift` use `NSColor(name:dynamicProvider:)` to adapt to system appearance; user can force dark/light via Settings → General; `ContentView` applies `.preferredColorScheme()` from `@AppStorage("argusai.colorScheme")` |
| **Onboarding** | `OnboardingView` shown when `store.stats == nil && !store.isLoading` — 3-step numbered guide to get started with Claude Code |

### Platform tab — Cost per User
Uses `filteredAccountCosts: [AccountCostBreakdown]` computed from `DailyAccountCosts` (per-day, per-account cost + message counts). This ensures the "Today" filter shows only today's cost, not the all-time total. `AccountCostBreakdown` carries both `costUSD` and `messageCount`.

### Menu bar label
`store.menuBarLabel` returns today's cost formatted as `"$X.XX"`. Updated on every refresh.

### Daily limit alert flow
1. User sets threshold in sidebar (`TextField` bound to `store.alertThreshold`)
2. On each `loadData()`, `checkAlerts()` compares `todayCost` to threshold
3. If ≥ threshold and `argusai.lastAlertDay` ≠ today → fires `UNNotificationRequest`, saves today's date to UserDefaults

### Week-over-week comparison
`previousPeriodDailyTotals` shifts the current window back by one period:
- `.today` → yesterday
- `.sevenDays` → [-14d, -7d]
- `.thirtyDays` → [-60d, -30d]
- `.all` → [] (no delta)

`DeltaBadge` shows ↑ in red (spending more) and ↓ in green (spending less).

## Auto-refresh

3-second timer → `checkAndRefreshIfNeeded()` → compares file mtimes → `loadData(silent: true)`.  
Silent refresh never shows the loading spinner; only the very first load does.

## Pricing

`ModelPricingTable` in `Models.swift` maps model IDs to per-MTok prices.  
Use `ModelPricingTable.price(for: model).cost(input:output:cr:cc5m:cc1h:)` for cost computation — the 4-arg `cost(input:output:cr:cc:)` overload prices everything at the 5-minute cache-write rate and exists for legacy callers/tests.

**Cache write tiers**: 5-minute ephemeral = 1.25× input (`cacheWritePerMTok`); 1-hour ephemeral = 2× input (computed via `effectiveCacheWrite1hPerMTok`, overridable with the optional `cacheWrite1hPerMTok`). Cowork uses 1h caching ~100% of the time, Claude Code ~90% — ingestion reads `usage.cache_creation.ephemeral_1h_input_tokens` into `messages.cache_create_1h_tokens` (`cache_create_tokens` stays the total of both tiers).

**When updating prices**: messages store `cost_usd` at ingest time, and `queryDailyBreakdown` recomputes from tokens — after a table change, historical rows need `ArgusDB.backfillCacheTiersAndRecomputeCosts()` (one-shot, guarded by `argusai.pricingRecompute.v1` in UserDefaults; the flag is set only on success so failures retry at next launch). Bump the key suffix to re-run it after a future price change.

`externalOverrides` is loaded once at startup from `~/.claude/argus_pricing.json` (if present). Format (`cacheWrite1hPerMTok` optional, defaults to 2× input):
```json
{ "claude-sonnet-4-6": { "inputPerMTok": 3.0, "outputPerMTok": 15.0, "cacheReadPerMTok": 0.30, "cacheWritePerMTok": 3.75, "cacheWrite1hPerMTok": 6.0 } }
```

**Note on accuracy**: JSONL files have no `costUSD` field — all costs are estimates from the price table. Actual billing can differ by ~10–15% (billing cycle mismatch, plan-specific rates, cache tier pricing). The Pricing tab in Settings shows this disclaimer to users.

## Plain buttons on macOS

With `.buttonStyle(.plain)`, SwiftUI only hits the text content — not empty space. **Always add `.contentShape(Rectangle())`** to the label view of any plain-style button that must be tappable across its full area (rows, nav items, filter rows).

## Color scheme

`Theme.swift` uses `NSColor(name:dynamicProvider:)` for all semantic colors. To add a new adaptive color:
```swift
static let appMyColor = Color(NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)  // dark
        : NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)  // light
})
```
