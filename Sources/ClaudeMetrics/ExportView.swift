import SwiftUI
import AppKit

struct ExportView: View {
    @EnvironmentObject var store: MetricsStore
    @EnvironmentObject var drive: GoogleDriveService
    @Environment(\.dismiss) private var dismiss

    // MARK: - Filter state (pre-populated from sidebar)
    @State private var selectedProject: String? = nil
    @State private var selectedAccount: String? = nil
    @State private var allDates: Bool = true
    @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @State private var endDate: Date = Date()

    // MARK: - Format
    @State private var exportCSV: Bool = true
    @State private var exportJSON: Bool = false

    // MARK: - Destination
    @State private var destination: DestinationTab = .local
    @State private var driveFolderURL: String = ""

    // MARK: - Progress / feedback
    @State private var isExporting = false
    @State private var exportError: String? = nil
    @State private var exportSuccess = false

    enum DestinationTab: String, CaseIterable, Identifiable {
        case local  = "File locale"
        case drive  = "Google Drive"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.appAccent)
                Text("Esporta dati")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── FILTRI ──
                    SectionCard(title: "Filtri", icon: "line.3.horizontal.decrease.circle") {
                        VStack(alignment: .leading, spacing: 12) {
                            // Progetto
                            HStack {
                                Text("Progetto").frame(width: 80, alignment: .leading)
                                Picker("", selection: $selectedProject) {
                                    Text("Tutti").tag(String?.none)
                                    ForEach(store.knownProjects, id: \.self) { p in
                                        Text(p).tag(String?.some(p))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            }

                            // Account
                            if store.knownAccounts.count > 1 {
                                HStack {
                                    Text("Account").frame(width: 80, alignment: .leading)
                                    Picker("", selection: $selectedAccount) {
                                        Text("Tutti").tag(String?.none)
                                        ForEach(store.knownAccounts) { a in
                                            Text(a.label).tag(String?.some(a.accountUuid))
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }
                            }

                            // Date
                            Toggle("Tutte le date", isOn: $allDates)
                                .toggleStyle(.checkbox)

                            if !allDates {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Da").font(.caption).foregroundStyle(Color.appTextSecondary)
                                        DatePicker("", selection: $startDate, displayedComponents: .date)
                                            .labelsHidden()
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Al").font(.caption).foregroundStyle(Color.appTextSecondary)
                                        DatePicker("", selection: $endDate, in: startDate..., displayedComponents: .date)
                                            .labelsHidden()
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }

                    // ── FORMATO ──
                    SectionCard(title: "Formato", icon: "doc.text") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 20) {
                                Toggle("CSV", isOn: $exportCSV).toggleStyle(.checkbox)
                                Toggle("JSON", isOn: $exportJSON).toggleStyle(.checkbox)
                            }
                            if !exportCSV && !exportJSON {
                                Text("Seleziona almeno un formato")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    // ── DESTINAZIONE ──
                    SectionCard(title: "Destinazione", icon: "folder") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("", selection: $destination) {
                                ForEach(DestinationTab.allCases) { t in
                                    Text(t.rawValue).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if destination == .drive {
                                DriveConnectionSection(driveFolderURL: $driveFolderURL)
                            }
                        }
                    }

                    // ── Feedback ──
                    if let err = exportError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        .padding(.horizontal, 4)
                    }
                    if exportSuccess {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(destination == .drive ? "File caricati su Google Drive" : "File salvati")
                                .font(.caption).foregroundStyle(.green)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }

            Divider()

            // ── Footer ──
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await doExport() }
                } label: {
                    if isExporting {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("Esporta")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting || (!exportCSV && !exportJSON) || !canExport)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { prePopulateFromSidebar() }
    }

    // MARK: - Helpers

    private var canExport: Bool {
        if destination == .drive {
            // Use the directly-observed `drive` so SwiftUI re-evaluates
            // when connectedEmail changes (not store.drive which isn't observed).
            return drive.isConnected && !driveFolderURL.isEmpty
        }
        return true
    }

    private func prePopulateFromSidebar() {
        selectedProject = store.projectFilter
        selectedAccount = store.accountFilter
        if store.dateFilter != .all && store.dateFilter != .custom {
            allDates = false
            // Mirror current sidebar date range
            let cal = Calendar.current
            switch store.dateFilter {
            case .today:
                startDate = cal.startOfDay(for: Date())
                endDate   = Date()
            case .sevenDays:
                startDate = cal.date(byAdding: .day, value: -7, to: Date())!
                endDate   = Date()
            case .thirtyDays:
                startDate = cal.date(byAdding: .day, value: -30, to: Date())!
                endDate   = Date()
            case .cycle:
                startDate = store.billingCycleStart ?? cal.startOfDay(for: Date())
                endDate   = Date()
            default: break
            }
        } else if store.dateFilter == .custom {
            allDates  = false
            startDate = store.customStartDate
            endDate   = store.customEndDate
        }
    }

    private func doExport() async {
        exportError   = nil
        exportSuccess = false
        isExporting   = true
        defer { isExporting = false }

        var formats = Set<ExportFormat>()
        if exportCSV  { formats.insert(.csv) }
        if exportJSON { formats.insert(.json) }

        let dest: ExportDestination = destination == .drive
            ? .googleDrive(folderURL: driveFolderURL)
            : .localFolder

        do {
            try await store.performExport(
                project:   selectedProject,
                account:   selectedAccount,
                startDate: allDates ? nil : startDate,
                endDate:   allDates ? nil : endDate,
                formats:   formats,
                destination: dest
            )
            exportSuccess = true
            // Auto-close after 1.5 s on success
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            dismiss()
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Drive connection sub-section

private struct DriveConnectionSection: View {
    // Directly observed so auth-state changes trigger re-render.
    @EnvironmentObject var drive: GoogleDriveService
    @Binding var driveFolderURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Auth row
            HStack(spacing: 10) {
                if drive.isConnected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connesso").font(.caption.weight(.semibold))
                        Text(drive.connectedEmail ?? "").font(.caption2).foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer()
                    Button("Disconnetti") { drive.disconnect() }
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                        .font(.caption)
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.appTextSecondary)
                    Text("Non connesso").font(.caption).foregroundStyle(Color.appTextSecondary)
                    Spacer()
                    Button {
                        Task { await drive.authenticate() }
                    } label: {
                        if drive.isAuthenticating {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Connetti con Google", systemImage: "person.badge.key")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(drive.isAuthenticating)
                }
            }

            if let err = drive.lastError {
                Text(err).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            // Folder URL
            VStack(alignment: .leading, spacing: 4) {
                Text("Cartella Drive (link o ID)")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                TextField("https://drive.google.com/drive/folders/…", text: $driveFolderURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                if !driveFolderURL.isEmpty && GoogleDriveService.folderID(from: driveFolderURL) == nil {
                    Text("Link non valido — incolla l'URL della cartella Drive")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            Text("Nota: l\u{2019}app potrebbe mostrare una schermata Google \u{201C}app non verificata\u{201D}. Clicca Avanzate \u{2192} Procedi per continuare.")
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
