import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
                .environmentObject(store)

            AlertsSettingsTab()
                .tabItem { Label("Alerts", systemImage: "bell") }
                .environmentObject(store)

            PricingSettingsTab()
                .tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @AppStorage("argusai.colorScheme") var colorScheme: String = "system"
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color Scheme", selection: $colorScheme) {
                    Text("System").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
            }
            Section("Billing Cycle") {
                HStack {
                    Text("Reset day of month")
                    Spacer()
                    TextField("Off", value: Binding(
                        get: { store.billingCycleResetDay ?? 0 },
                        set: { store.billingCycleResetDay = (1...28).contains($0) ? $0 : nil }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                }
                Text("The Claude desktop/claude.ai \"$ of $200\" counter follows your subscription cycle, not the calendar month. Set the day it resets (1–28) to get a \"Billing Cycle\" preset in the sidebar; 0 disables it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Auto-refresh", value: "Every 3 seconds")
                LabeledContent("Database", value: "~/.claude/argusai.db")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Alerts

struct AlertsSettingsTab: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        Form {
            Section("Global") {
                HStack {
                    Text("Daily spend limit")
                    Spacer()
                    TextField("$0.00", value: $store.alertThreshold, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("USD")
                        .foregroundStyle(.secondary)
                }
            }

            if !store.knownProjects.isEmpty {
                Section("Project Monthly Limits") {
                    ForEach(store.knownProjects, id: \.self) { project in
                        HStack {
                            Text(project)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            TextField("No limit", value: Binding(
                                get: { store.projectAlertThresholds[project] ?? 0 },
                                set: { store.projectAlertThresholds[project] = $0 > 0 ? $0 : nil }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            Text("USD/mo")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Pricing

struct PricingSettingsTab: View {
    private var pricingFileExists: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude/argus_pricing.json")
    }

    var body: some View {
        Form {
            Section("Custom Pricing Override") {
                LabeledContent("Config file", value: "~/.claude/argus_pricing.json")
                LabeledContent("Status") {
                    Text(pricingFileExists ? "Active" : "Not found — using built-in prices")
                        .foregroundStyle(pricingFileExists ? .green : .secondary)
                }
                Text("Create the file to override model prices. Restart the app to apply changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Built-in Prices (per MTok)") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Model").bold()
                        Text("Input").bold()
                        Text("Output").bold()
                        Text("Cache R").bold()
                        Text("Cache W").bold()
                    }
                    Divider()
                    ForEach([
                        ("Sonnet 4.6", "$3.00",  "$15.00", "$0.30", "$3.75"),
                        ("Opus 4.7",   "$15.00", "$75.00", "$1.50", "$18.75"),
                        ("Haiku 4.5",  "$0.80",  "$4.00",  "$0.08", "$1.00"),
                    ], id: \.0) { row in
                        GridRow {
                            Text(row.0)
                            Text(row.1)
                            Text(row.2)
                            Text(row.3)
                            Text(row.4)
                        }
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                }

                Text("⚠️ Costs shown in ArgusAI are estimates based on public API prices and may differ from actual billing by ~10–15%.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
