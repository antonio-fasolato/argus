import SwiftUI
import Charts
import AppKit

struct OverviewView: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Overview",
                    subtitle: store.stats?.lastComputedDate.map { "Data as of \($0)" } ?? "Claude Code usage summary"
                )

                // KPI row 1
                HStack(spacing: 14) {
                    VStack(spacing: 4) {
                        MetricCard(
                            icon: "bubble.left.and.bubble.right.fill",
                            iconColor: .appAccent,
                            label: "Total Messages",
                            value: "\(store.filteredTotalMessages)",
                            detail: "\(store.filteredTotalSessions) sessions"
                        )
                        if let pct = store.messagesDeltaPct {
                            DeltaBadge(pct: pct)
                        }
                    }
                    MetricCard(
                        icon: "arrow.up.right.circle.fill",
                        iconColor: .modelSonnet,
                        label: "Output Tokens",
                        value: formatTokens(store.filteredOutputTokens),
                        detail: "\(formatTokens(store.filteredInputTokens)) input"
                    )
                    MetricCard(
                        icon: "doc.on.doc.fill",
                        iconColor: .modelHaiku,
                        label: "Cache Tokens",
                        value: formatTokens(store.filteredCacheTokens),
                        detail: "reads + writes"
                    )
                    VStack(spacing: 4) {
                        MetricCard(
                            icon: "dollarsign.circle.fill",
                            iconColor: .appGold,
                            label: "Est. Cost",
                            value: formatCost(store.filteredTotalCost),
                            detail: "public pricing"
                        )
                        if let pct = store.costDeltaPct {
                            DeltaBadge(pct: pct)
                        }
                    }
                }

                // KPI row 2
                HStack(spacing: 14) {
                    MetricCard(
                        icon: "doc.on.doc.fill",
                        iconColor: .modelHaiku,
                        label: "Cache Hit Rate",
                        value: String(format: "%.1f%%", store.filteredCacheHitRate * 100),
                        detail: "tokens served from cache"
                    )
                    MetricCard(
                        icon: "tag.fill",
                        iconColor: .appGold,
                        label: "Cache Savings",
                        value: formatCost(store.filteredCacheSavings),
                        detail: "vs full input price"
                    )
                    MetricCard(
                        icon: "flame.fill",
                        iconColor: Color.orange,
                        label: "Current Streak",
                        value: "\(store.currentStreak)",
                        detail: "consecutive days"
                    )
                    MetricCard(
                        icon: "magnifyingglass.circle.fill",
                        iconColor: .modelSonnet,
                        label: "Web Searches",
                        value: "\(store.filteredWebSearches)",
                        detail: "server-side searches"
                    )
                }

                // Daily activity chart
                if store.filteredActivity.count > 1 {
                    SectionCard(title: "Daily Messages", icon: "chart.xyaxis.line") {
                        DailyMessagesChart()
                            .frame(height: 200)
                    }
                }

                // Model comparison
                if !store.filteredSortedModels.isEmpty {
                    SectionCard(title: "Token Usage by Model", icon: "cpu") {
                        ModelOutputChart()
                            .frame(height: 150)
                    }
                }

                // Daily cost
                if store.filteredDailyCostData.count > 1 {
                    SectionCard(title: "Daily Cost", icon: "dollarsign.circle") {
                        OverviewDailyCostChart()
                            .frame(height: 160)
                    }
                }

                // Forecast
                SectionCard(title: "Forecast", icon: "chart.line.uptrend.xyaxis") {
                    VStack(spacing: 10) {
                        HStack {
                            Text("Burn rate")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.appTextSecondary)
                            Spacer()
                            Text(String(format: "%@ / day", formatCost(store.burnRatePerDay)))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appTextPrimary)
                        }
                        HStack {
                            Text("Spent this month")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.appTextSecondary)
                            Spacer()
                            Text(formatCost(store.currentMonthCost))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appTextPrimary)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Projected month")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.appTextSecondary)
                                Text("(\(store.daysLeftInMonth) days left)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.appTextTertiary)
                            }
                            Spacer()
                            Text("~\(formatCost(store.projectedMonthCost))")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appGold)
                        }
                    }
                }

                // Account breakdown (only when multiple accounts have tracked data)
                if let accountCosts = store.stats?.accountCosts, accountCosts.count > 1 {
                    let totalAccountCost = accountCosts.reduce(0) { $0 + $1.costUSD }
                    SectionCard(title: "By Account", icon: "person.crop.circle.badge.clock") {
                        VStack(spacing: 10) {
                            ForEach(accountCosts) { acct in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(acct.label)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.appTextPrimary)
                                        if !acct.subtitle.isEmpty {
                                            Text(acct.subtitle)
                                                .font(.system(size: 10))
                                                .foregroundStyle(Color.appTextTertiary)
                                        }
                                    }
                                    Spacer()
                                    Text(formatCost(acct.costUSD))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.appTextPrimary)
                                }
                            }
                            if totalAccountCost > 0 {
                                GeometryReader { geo in
                                    HStack(spacing: 2) {
                                        ForEach(Array(accountCosts.enumerated()), id: \.offset) { idx, acct in
                                            let colors: [Color] = [Color.appAccent, .orange, .purple, .green]
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(colors[idx % colors.count])
                                                .frame(width: max(4, geo.size.width * CGFloat(acct.costUSD / totalAccountCost)))
                                        }
                                    }
                                }
                                .frame(height: 8)
                            }
                        }
                    }
                }

                // Source breakdown (Claude Code vs Cowork) — only when more than one source has data
                let sourceCosts = store.filteredSourceCosts
                if sourceCosts.count > 1 {
                    let totalSourceCost = sourceCosts.reduce(0) { $0 + $1.costUSD }
                    SectionCard(title: "By Source", icon: "square.stack.3d.up") {
                        VStack(spacing: 10) {
                            ForEach(sourceCosts) { src in
                                HStack {
                                    Label(sourceDisplayName(src.source), systemImage: sourceIconName(src.source))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.appTextSecondary)
                                    Spacer()
                                    Text("\(src.messageCount) msgs · \(formatCost(src.costUSD))")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.appTextPrimary)
                                }
                            }
                            if totalSourceCost > 0 {
                                GeometryReader { geo in
                                    HStack(spacing: 2) {
                                        ForEach(Array(sourceCosts.enumerated()), id: \.offset) { idx, src in
                                            let colors: [Color] = [Color.appAccent, .orange, .purple]
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(colors[idx % colors.count])
                                                .frame(width: max(4, geo.size.width * CGFloat(src.costUSD / totalSourceCost)))
                                        }
                                    }
                                }
                                .frame(height: 8)
                            }
                        }
                    }
                }

                // Agent type
                let subCost  = store.filteredSubagentCost
                let dirCost  = store.filteredDirectCost
                let totalAgentCost = subCost + dirCost
                if totalAgentCost > 0 {
                    SectionCard(title: "Agent Type", icon: "person.2.fill") {
                        VStack(spacing: 10) {
                            HStack {
                                Text("Direct")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.appTextSecondary)
                                Spacer()
                                Text("\(store.filteredSessions.filter { !$0.isSubagent }.count) sessions · \(formatCost(dirCost))")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.appTextPrimary)
                            }
                            HStack {
                                Text("Subagent")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.appTextSecondary)
                                Spacer()
                                Text("\(store.filteredSessions.filter { $0.isSubagent }.count) sessions · \(formatCost(subCost))")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.appTextPrimary)
                            }
                            // Two-segment bar
                            GeometryReader { geo in
                                HStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.appAccent)
                                        .frame(width: max(4, geo.size.width * CGFloat(dirCost / totalAgentCost)))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.appTextSecondary)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                }
            }
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBg)
    }
}

struct DailyMessagesChart: View {
    @EnvironmentObject var store: MetricsStore
    @State private var selectedDate: Date? = nil

    private let tooltipFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private func closestItem(to date: Date) -> DailyActivity? {
        store.filteredActivity.min(by: {
            abs($0.dateValue.timeIntervalSince(date)) < abs($1.dateValue.timeIntervalSince(date))
        })
    }

    var body: some View {
        Chart(store.filteredActivity) { item in
            AreaMark(
                x: .value("Date", item.dateValue),
                y: .value("Messages", item.messageCount)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.appAccent.opacity(0.35), Color.appAccent.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Date", item.dateValue),
                y: .value("Messages", item.messageCount)
            )
            .foregroundStyle(Color.appAccent)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Date", item.dateValue),
                y: .value("Messages", item.messageCount)
            )
            .foregroundStyle(Color.appAccent)
            .symbolSize(28)
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.appBorder)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(Color.appTextSecondary)
                    .font(.system(size: 10))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.appBorder)
                AxisValueLabel().foregroundStyle(Color.appTextSecondary).font(.system(size: 10))
            }
        }
        .chartPlotStyle { $0.background(Color.clear) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let sel = selectedDate,
                   let item = closestItem(to: sel),
                   let plotAnchor = proxy.plotFrame {
                    let plotRect = geo[plotAnchor]
                    let xPos = (proxy.position(forX: item.dateValue) ?? 0) + plotRect.minX
                    let yPos = (proxy.position(forY: item.messageCount) ?? 0) + plotRect.minY

                    ChartCrosshair.verticalLine(plotRect: plotRect, xPos: xPos)
                    ChartCrosshair.horizontalLine(plotRect: plotRect, yPos: yPos)
                    ChartCrosshair.point(xPos: xPos, yPos: yPos, color: Color.appAccent)
                    ChartCrosshair.tooltip(plotRect: plotRect, xPos: xPos, yPos: yPos) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tooltipFmt.string(from: item.dateValue))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.appTextPrimary)
                            Text("\(item.messageCount) msgs")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                }
            }
        }
    }
}

struct OverviewDailyCostChart: View {
    @EnvironmentObject var store: MetricsStore
    @State private var selectedDate: Date? = nil
    @State private var explainPoint: CostPoint? = nil

    struct CostPoint: Identifiable {
        let id: String
        let date: Date
        let cost: Double
    }

    private let tooltipFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    var points: [CostPoint] {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return store.filteredDailyCostData.compactMap { item in
            guard let d = fmt.date(from: item.date) else { return nil }
            return CostPoint(id: item.date, date: d, cost: item.cost)
        }
    }

    private func closestPoint(to date: Date) -> CostPoint? {
        points.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("Date", p.date), y: .value("Cost", p.cost))
                .foregroundStyle(LinearGradient(
                    colors: [Color.appGold.opacity(0.35), Color.appGold.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Date", p.date), y: .value("Cost", p.cost))
                .foregroundStyle(Color.appGold)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            PointMark(x: .value("Date", p.date), y: .value("Cost", p.cost))
                .foregroundStyle(Color.appGold).symbolSize(28)
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.appBorder)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(Color.appTextSecondary).font(.system(size: 10))
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.appBorder)
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        Text(formatCost(n)).font(.system(size: 10)).foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
        }
        .chartPlotStyle { $0.background(Color.clear) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plotAnchor = proxy.plotFrame {
                    let plotRect = geo[plotAnchor]

                    // Tap layer: convert click to closest point and open the explain popover.
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: plotRect.width, height: plotRect.height)
                        .position(x: plotRect.midX, y: plotRect.midY)
                        .onTapGesture { location in
                            let xInPlot = location.x - plotRect.minX
                            guard let d: Date = proxy.value(atX: xInPlot) else { return }
                            explainPoint = closestPoint(to: d)
                        }

                    if let sel = selectedDate, let p = closestPoint(to: sel) {
                        let xPos = (proxy.position(forX: p.date) ?? 0) + plotRect.minX
                        let yPos = (proxy.position(forY: p.cost) ?? 0) + plotRect.minY

                        ChartCrosshair.verticalLine(plotRect: plotRect, xPos: xPos)
                        ChartCrosshair.horizontalLine(plotRect: plotRect, yPos: yPos)
                        ChartCrosshair.point(xPos: xPos, yPos: yPos, color: Color.appGold)
                        ChartCrosshair.tooltip(plotRect: plotRect, xPos: xPos, yPos: yPos) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tooltipFmt.string(from: p.date))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.appTextPrimary)
                                Text(formatCost(p.cost))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.appGold)
                                Text("click to explain")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.appTextTertiary)
                            }
                        }
                    }

                    // Invisible popover anchor positioned at the clicked point.
                    if let ep = explainPoint {
                        let xPos = (proxy.position(forX: ep.date) ?? 0) + plotRect.minX
                        let yPos = (proxy.position(forY: ep.cost) ?? 0) + plotRect.minY
                        Color.clear
                            .frame(width: 1, height: 1)
                            .position(x: xPos, y: yPos)
                            .popover(
                                isPresented: Binding(
                                    get: { explainPoint != nil },
                                    set: { if !$0 { explainPoint = nil } }
                                ),
                                attachmentAnchor: .point(.center)
                            ) {
                                DailyCostExplainView(point: ep)
                                    .environmentObject(store)
                            }
                    }
                }
            }
        }
    }
}

struct DailyCostExplainView: View {
    @EnvironmentObject var store: MetricsStore
    let point: OverviewDailyCostChart.CostPoint
    @State private var copied = false

    private let titleDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d, yyyy"; return f
    }()

    private var rawSQL: String {
        var clauses = ""
        if let af = store.accountFilter {
            let safe = af.replacingOccurrences(of: "'", with: "''")
            clauses += "\n  AND account_uuid = '\(safe)'"
        }
        if let pf = store.projectFilter {
            let safe = pf.replacingOccurrences(of: "'", with: "''")
            clauses += "\n  AND project = '\(safe)'"
        }
        return """
        SELECT model,
               SUM(input_tokens)        AS input_tokens,
               SUM(output_tokens)       AS output_tokens,
               SUM(cache_read_tokens)   AS cache_read,
               SUM(cache_create_tokens) AS cache_write,
               COUNT(*)                 AS messages,
               ROUND(SUM(cost_usd), 4)  AS cost_usd
        FROM messages
        WHERE day = '\(point.id)'\(clauses)
        GROUP BY model
        ORDER BY cost_usd DESC;
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleDateFmt.string(from: point.date))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                    Text(formatCost(point.cost))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.appGold)
                }

                if let exp = store.dailyCostExplanation(for: point.id) {
                    if exp.totalMessages > 0 {
                        Text("\(exp.totalMessages) message\(exp.totalMessages == 1 ? "" : "s") this day")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appTextTertiary)
                    }

                    sectionHeader("Calculation")
                    Text("Per-message cost = (in × p_in + out × p_out + cr × p_cr + cw × p_cw) / 1,000,000.  The chart point is the sum of all assistant messages on this day.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !exp.modelLines.isEmpty {
                        sectionHeader("By model")
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(exp.modelLines) { line in modelRow(line) }
                        }
                    }

                    if !exp.projectLines.isEmpty {
                        sectionHeader("By project")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(exp.projectLines) { pr in
                                HStack(spacing: 8) {
                                    Text(pr.project)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.appTextPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text("\(pr.messageCount) msg")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color.appTextTertiary)
                                    Text(formatCost(pr.costUSD))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.appTextPrimary)
                                        .frame(width: 70, alignment: .trailing)
                                }
                            }
                        }
                    }

                    sectionHeader("Source")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("~/.claude/projects/**/*.jsonl")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.appTextSecondary)
                        Text("→ ~/.claude/argusai.db · messages table")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.appTextSecondary)
                        Text("aggregated by queryDailyBreakdown() — GROUP BY day, model")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.appTextTertiary)
                        if let af = exp.accountFilter {
                            Text("account filter: \(af)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.appTextTertiary)
                        }
                        if let pf = exp.projectFilter {
                            Text("project filter: \(pf)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.appTextTertiary)
                        }
                    }

                    HStack(alignment: .center) {
                        sectionHeader("Raw SQL")
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(rawSQL, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10))
                                Text(copied ? "Copied" : "Copy")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(copied ? Color.green : Color.appTextSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.appBorder, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Copy SQL to clipboard")
                    }
                    Text(rawSQL)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.appTextPrimary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.appBorder, lineWidth: 0.5))
                    Text("Run with:  sqlite3 ~/.claude/argusai.db")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.appTextTertiary)
                } else {
                    Text("No detail available for this day.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380, height: 560)
        .background(Color.appBg)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.appTextSecondary)
            .tracking(0.6)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func modelRow(_ line: MetricsStore.DailyCostExplanation.ModelLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(line.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.forModel(line.model))
                Spacer()
                Text(formatCost(line.costTotal))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.appGold)
            }
            costBreakLine("input",   tokens: line.inputTokens,       rate: line.price.inputPerMTok,     cost: line.costInput)
            costBreakLine("output",  tokens: line.outputTokens,      rate: line.price.outputPerMTok,    cost: line.costOutput)
            if line.cacheReadTokens > 0 {
                costBreakLine("cache read",  tokens: line.cacheReadTokens,   rate: line.price.cacheReadPerMTok,  cost: line.costCacheRead)
            }
            if line.cacheCreateTokens > 0 {
                costBreakLine("cache write", tokens: line.cacheCreateTokens, rate: line.price.cacheWritePerMTok, cost: line.costCacheCreate)
            }
        }
    }

    @ViewBuilder
    private func costBreakLine(_ label: String, tokens: Int, rate: Double, cost: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 78, alignment: .leading)
            Text(formatTokens(tokens))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 56, alignment: .trailing)
            Text("× $\(String(format: "%g", rate))/M")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.appTextTertiary)
            Spacer()
            Text(formatCost(cost))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

struct ModelOutputChart: View {
    @EnvironmentObject var store: MetricsStore

    struct BarItem: Identifiable {
        let id: String
        let model: String
        let tokens: Int
        let kind: String
    }

    var items: [BarItem] {
        store.filteredSortedModels.flatMap { entry in [
            BarItem(id: "\(entry.model)-out", model: modelDisplayName(entry.model),
                    tokens: entry.stats.outputTokens, kind: "Output"),
            BarItem(id: "\(entry.model)-in",  model: modelDisplayName(entry.model),
                    tokens: entry.stats.inputTokens,  kind: "Input"),
        ]}
    }

    var body: some View {
        Chart(items) { item in
            BarMark(
                x: .value("Tokens", item.tokens),
                y: .value("Model", item.model)
            )
            .foregroundStyle(by: .value("Kind", item.kind))
        }
        .chartForegroundStyleScale([
            "Output": Color.appAccent,
            "Input":  Color.appAccent.opacity(0.38),
        ])
        .chartXAxis {
            AxisMarks { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.appBorder)
                AxisValueLabel {
                    if let n = v.as(Int.self) {
                        Text(formatTokens(n))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.system(size: 11)).foregroundStyle(Color.appTextPrimary)
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .chartPlotStyle { $0.background(Color.clear) }
    }
}
