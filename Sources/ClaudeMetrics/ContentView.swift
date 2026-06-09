import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility             = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum NavSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case models   = "Models"
    case activity = "Activity"
    case schedule = "Schedule"
    case projects = "Projects"
    case sessions = "Sessions"
    case platform = "Platform"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.xaxis.ascending.badge.clock"
        case .models:   return "cpu"
        case .activity: return "calendar.day.timeline.left"
        case .schedule: return "clock.fill"
        case .projects: return "folder.badge.gear"
        case .sessions: return "bubble.left.and.bubble.right"
        case .platform: return "gauge.medium"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: MetricsStore
    @State private var selected: NavSection = .overview
    @AppStorage("argusai.colorScheme") private var colorSchemePref: String = "system"

    private var preferredColorScheme: ColorScheme? {
        switch colorSchemePref {
        case "dark":  return .dark
        case "light": return .light
        default:      return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selected: $selected)
                .frame(width: 196)

            Color.appBorder
                .frame(width: 1)

            ZStack {
                Color.appBg.ignoresSafeArea()
                Group {
                    if store.isLoading {
                        LoadingView()
                    } else if let err = store.error {
                        ErrorView(message: err)
                    } else if store.stats == nil && !store.isLoading {
                        OnboardingView()
                    } else {
                        switch selected {
                        case .overview: OverviewView()
                        case .models:   ModelsView()
                        case .activity: ActivityView()
                        case .schedule: ScheduleView()
                        case .projects: ProjectsView()
                        case .sessions: SessionsView()
                        case .platform: PlatformView()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.appBg)
        .ignoresSafeArea()
        .background { WindowConfigurator() }
        .preferredColorScheme(preferredColorScheme)
        .sheet(isPresented: $store.showingExport) {
            ExportView()
                .environmentObject(store)
                .environmentObject(store.drive)
        }
    }
}

struct SidebarView: View {
    @Binding var selected: NavSection
    @EnvironmentObject var store: MetricsStore

    private let datePresets: [(String, String, DateFilter)] = [
        ("sun.horizon", "Today",    .today),
        ("calendar",   "7 days",   .sevenDays),
        ("calendar",   "30 days",  .thirtyDays),
        ("infinity",   "All time", .all),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Fixed header ──────────────────────────
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.appAccent.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.appAccent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text("Metrics")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appAccent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 38)
            .padding(.bottom, 14)

            // ── Single scrollable body ────────────────
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // Account chip
                    if let acct = store.currentAccount {
                        HStack(spacing: 6) {
                            Image(systemName: acct.isOAuth ? "person.crop.circle.fill" : "key.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(acct.isOAuth ? Color.appAccent : Color.orange)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(acct.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.appTextPrimary)
                                    .lineLimit(1)
                                if !acct.subtitle.isEmpty {
                                    Text(acct.subtitle)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.appTextTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(acct.isOAuth ? Color.appAccent.opacity(0.08) : Color.orange.opacity(0.08))
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 14)
                    }

                    // Navigation
                    VStack(spacing: 2) {
                        ForEach(NavSection.allCases) { section in
                            NavButton(section: section, isSelected: selected == section) {
                                withAnimation(.easeInOut(duration: 0.15)) { selected = section }
                            }
                        }
                    }
                    .padding(.horizontal, 8)

                    // Time range
                    SidebarSectionLabel("TIME RANGE")
                    VStack(spacing: 2) {
                        ForEach(datePresets, id: \.2) { icon, label, filter in
                            let isSelected = store.dateFilter == filter && store.dateFilter != .custom
                            SidebarFilterRow(icon: icon, label: label, isSelected: isSelected) {
                                store.dateFilter = filter
                            }
                        }
                    }
                    .padding(.horizontal, 8)

                    // Custom range
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 10))
                                .foregroundStyle(store.dateFilter == .custom ? Color.appAccent : Color.appTextTertiary)
                                .frame(width: 14)
                            Text("Custom")
                                .font(.system(size: 11, weight: store.dateFilter == .custom ? .semibold : .regular))
                                .foregroundStyle(store.dateFilter == .custom ? Color.appTextPrimary : Color.appTextSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Da")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.appTextTertiary)
                                    .frame(width: 18, alignment: .trailing)
                                DatePicker("", selection: Binding(
                                    get: { store.customStartDate },
                                    set: { store.customStartDate = $0; store.dateFilter = .custom }
                                ), in: ...store.customEndDate, displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                            }
                            HStack(spacing: 6) {
                                Text("Al")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.appTextTertiary)
                                    .frame(width: 18, alignment: .trailing)
                                DatePicker("", selection: Binding(
                                    get: { store.customEndDate },
                                    set: { store.customEndDate = $0; store.dateFilter = .custom }
                                ), in: store.customStartDate..., displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                            }
                        }
                        .padding(.leading, 36)
                        .padding(.bottom, 4)
                    }

                    // Daily limit
                    SidebarSectionLabel("DAILY LIMIT")
                    HStack(spacing: 8) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appTextTertiary)
                            .frame(width: 14)
                        TextField("$0.00", value: $store.alertThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)

                    // Account filter
                    if store.knownAccounts.count > 1 {
                        SidebarSectionLabel("ACCOUNT")
                        VStack(spacing: 2) {
                            SidebarFilterRow(icon: "person.2.fill", label: "All Accounts",
                                             isSelected: store.accountFilter == nil) {
                                store.accountFilter = nil
                            }
                            ForEach(store.knownAccounts) { acct in
                                SidebarFilterRow(
                                    icon: acct.isOAuth ? "person.crop.circle" : "key.fill",
                                    label: acct.label,
                                    isSelected: store.accountFilter == acct.accountUuid
                                ) { store.accountFilter = acct.accountUuid }
                            }
                        }
                        .padding(.horizontal, 8)
                    }

                    // Project filter
                    if store.knownProjects.count > 1 {
                        SidebarSectionLabel("PROJECT")
                        VStack(spacing: 2) {
                            SidebarFilterRow(icon: "folder.fill", label: "All Projects",
                                             isSelected: store.projectFilter == nil) {
                                store.projectFilter = nil
                            }
                            ForEach(store.knownProjects, id: \.self) { proj in
                                SidebarFilterRow(icon: "folder", label: proj,
                                                 isSelected: store.projectFilter == proj) {
                                    store.projectFilter = proj
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }

                    Spacer(minLength: 12)
                }
            }

            // ── Fixed footer ──────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                Color.appBorder.frame(height: 1)

                if let date = store.lastRefresh {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Updated \(date, style: .relative) ago")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                if store.ingestSkippedLines > 0 || store.ingestUnreadableFiles > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                        Text(ingestWarningText)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .help("Some data could not be ingested — totals may be incomplete")
                }

                Button { store.loadData() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text("Refresh")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
        .background(Color.appSidebar)
    }

    private var ingestWarningText: String {
        var parts: [String] = []
        if store.ingestSkippedLines > 0 { parts.append("\(store.ingestSkippedLines) skipped lines") }
        if store.ingestUnreadableFiles > 0 { parts.append("\(store.ingestUnreadableFiles) unreadable files") }
        return parts.joined(separator: " · ")
    }
}

private struct SidebarSectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.appTextTertiary)
            .tracking(0.8)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }
}

private struct SidebarFilterRow: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Circle().fill(Color.appAccent).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.appAccent.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}


struct NavButton: View {
    let section: NavSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.appAccent.opacity(0.13) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.appAccent.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(Color.appAccent)

            VStack(spacing: 8) {
                Text("No data yet")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appTextPrimary)
                Text("ArgusAI reads your Claude Code session files automatically.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingStep(number: "1", text: "Install Claude Code from claude.ai/code")
                OnboardingStep(number: "2", text: "Run Claude Code in any terminal — start a conversation")
                OnboardingStep(number: "3", text: "ArgusAI detects sessions in ~/.claude/projects and shows metrics here")
            }
            .padding(20)
            .background(Color.appSurface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingStep: View {
    let number: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appBg)
                .frame(width: 22, height: 22)
                .background(Color.appAccent)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.appTextSecondary)
        }
    }
}
