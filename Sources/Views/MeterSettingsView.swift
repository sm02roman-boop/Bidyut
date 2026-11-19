import SwiftUI
import SwiftData
import WidgetKit

struct MeterSettingsView: View {
    @Bindable var meter: Meter

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allMeters: [Meter]

    @State private var showingDeleteConfirmation = false
    @State private var language = LanguageSettings.current

    private var threshold: Binding<Double> {
        Binding(
            get: { meter.lowBalanceThreshold > 0 ? meter.lowBalanceThreshold : NotificationService.defaultThreshold },
            set: { meter.lowBalanceThreshold = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.callAttention("Name", "নাম")) {
                    TextField(L10n.callAttention("Nickname", "ডাকনাম"), text: $meter.nickname)
                }

                Section {
                    Picker(L10n.language, selection: $language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .onChange(of: language) { _, newValue in
                        LanguageSettings.current = newValue
                        // Redraw everything that reads L10n, including the widget.
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                } footer: {
                    Text(L10n.callAttention(
                        "Changes the app and its widgets straight away. Figures use Bengali digits in বাংলা.",
                        "অ্যাপ ও widget সাথে সাথে বদলে যাবে। বাংলায় সংখ্যাগুলোও বাংলা অঙ্কে দেখাবে।"
                    ))
                }

                Section {
                    Toggle("Low balance alerts", isOn: $meter.notificationsEnabled)

                    if meter.notificationsEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Warn below")
                                Spacer()
                                Text(Formatters.takaShort(threshold.wrappedValue))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: threshold, in: 50...2000, step: 50)
                        }
                    }
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("You also get a warning about two days before the balance is forecast to run out, which usually arrives sooner than the amount above.")
                }

                if allMeters.count > 1 {
                    Section {
                        Toggle("Show this meter first", isOn: Binding(
                            get: { meter.isPrimary },
                            set: { isPrimary in
                                if isPrimary {
                                    allMeters.forEach { $0.isPrimary = false }
                                }
                                meter.isPrimary = isPrimary
                            }
                        ))
                    }
                }

                Section("History") {
                    LabeledContent("Readings", value: "\(meter.snapshots.count)")
                    LabeledContent("Recharges", value: "\(meter.recharges.count)")
                    LabeledContent("Last sync", value: Formatters.fullDate(meter.lastSyncedAt))
                }

                Section {
                    Button("Remove meter", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                } footer: {
                    Text("Removing a meter also deletes its stored reading history, which is what the daily forecast is built from.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? context.save()
                        Task {
                            let summary = ConsumptionAnalytics.summarize(meter: meter)
                            await NotificationService.refreshAlerts(for: meter, summary: summary)
                            SharedStore.publish(meter: meter)
                        }
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Remove \(meter.displayName)?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove meter and history", role: .destructive) {
                    NotificationService.cancelAll(for: meter)
                    context.delete(meter)
                    try? context.save()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. \(meter.snapshots.count) stored readings will be deleted.")
            }
        }
    }
}
