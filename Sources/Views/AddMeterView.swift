import SwiftUI
import SwiftData

/// Adds a meter, verifying it against the portal before saving so a typo is
/// caught here rather than showing up as an empty dashboard.
struct AddMeterView: View {
    let isOnboarding: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existingMeters: [Meter]

    @State private var customerNumber = ""
    @State private var nickname = ""
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @State private var verified: NescoSnapshot?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Customer number", text: $customerNumber)
                        .keyboardType(.numberPad)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                        .onChange(of: customerNumber) { _, _ in
                            verified = nil
                            errorMessage = nil
                        }

                    TextField("Name it (Home, Chamber, Office)", text: $nickname)
                        .autocorrectionDisabled()
                } header: {
                    Text("NESCO meter")
                } footer: {
                    Text("Your customer number is printed on the meter and on any recharge receipt. It is 5 to 14 digits — not the 11-digit meter number.")
                }

                if let verified {
                    Section("Found") {
                        LabeledContent("Name", value: verified.info.name ?? "—")
                        LabeledContent("Address", value: verified.info.address ?? "—")
                        LabeledContent("Meter no.", value: verified.info.meterNo ?? "—")
                        LabeledContent("Balance", value: Formatters.taka(verified.balance))
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await verifyOrSave() }
                    } label: {
                        HStack {
                            Spacer()
                            if isVerifying {
                                ProgressView()
                            } else {
                                Text(verified == nil ? "Check meter" : "Add meter")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isVerifying || customerNumber.filter(\.isNumber).count < 5)
                }

                if isOnboarding {
                    Section {
                        Text("The app reads the public NESCO customer portal, which only answers requests from inside Bangladesh. Turn off any VPN before syncing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isOnboarding ? "Add your meter" : "New meter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func verifyOrSave() async {
        if verified == nil {
            await verify()
        } else {
            save()
        }
    }

    private func verify() async {
        isVerifying = true
        defer { isVerifying = false }

        do {
            let customer = try NescoClient.validate(customerNumber)

            guard !existingMeters.contains(where: { $0.customerNumber == customer }) else {
                errorMessage = "That meter is already added."
                return
            }

            let snapshot = try await NescoClient().fetchSnapshot(customerNumber: customer)
            verified = snapshot
            errorMessage = nil

            if nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                nickname = snapshot.info.name.map { String($0.prefix(20)) } ?? "My meter"
            }
        } catch {
            verified = nil
            let nesco = error as? NescoError
            errorMessage = [nesco?.errorDescription ?? error.localizedDescription, nesco?.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    private func save() {
        guard let verified else { return }

        let meter = Meter(
            customerNumber: verified.customerNumber,
            nickname: nickname.trimmingCharacters(in: .whitespaces),
            isPrimary: existingMeters.isEmpty
        )
        context.insert(meter)

        let service = SyncService(context: context)
        service.apply(verified, to: meter)

        Task {
            _ = await NotificationService.requestAuthorization()
            let summary = ConsumptionAnalytics.summarize(meter: meter)
            await NotificationService.refreshAlerts(for: meter, summary: summary)
        }

        dismiss()
    }
}
