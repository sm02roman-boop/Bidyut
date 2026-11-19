import SwiftUI

/// Recharge history, with the deduction breakdown NESCO buries in the portal's
/// row attributes — where the money actually went.
struct RechargeHistoryView: View {
    let meter: Meter

    private var recharges: [Recharge] {
        meter.recharges.sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            if recharges.isEmpty {
                ContentUnavailableView(
                    "No recharges yet",
                    systemImage: "creditcard",
                    description: Text("Recharges appear here after the next sync.")
                )
            } else {
                Section {
                    ForEach(recharges) { recharge in
                        RechargeRow(recharge: recharge)
                    }
                } footer: {
                    Text("“Credited” is what reached your balance after NESCO deducted meter rent, demand charge and VAT.")
                }
            }
        }
        .navigationTitle("Recharges")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RechargeRow: View {
    let recharge: Recharge
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Formatters.taka(recharge.totalAmount))
                            .font(.headline)
                        HStack(spacing: 6) {
                            Text(Formatters.dayMonth(recharge.date))
                            if let method = recharge.method, !method.isEmpty {
                                Text("·")
                                Text(method)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        if let units = recharge.energyUnit {
                            Text(Formatters.units(units))
                                .font(.subheadline.weight(.medium))
                        }
                        if !recharge.isSuccessful {
                            Text(recharge.status ?? "Failed")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.Status.critical.color)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 6) {
                    if let value = recharge.electricityAmount {
                        breakdown("Credited to balance", value, emphasis: true)
                    }
                    if let value = recharge.meterRent, value > 0 { breakdown("Meter rent", -value) }
                    if let value = recharge.demandCharge, value > 0 { breakdown("Demand charge", -value) }
                    if let value = recharge.vat, value > 0 { breakdown("VAT", -value) }
                    if let value = recharge.pfc, value > 0 { breakdown("Power factor charge", -value) }
                    if let value = recharge.subsidy, value > 0 { breakdown("Subsidy", value) }

                    if let share = recharge.deductionShare {
                        Divider()
                        HStack {
                            Text("Deductions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int((share * 100).rounded()))% of payment")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(share > 0.3 ? Theme.Status.warning.color : .secondary)
                        }
                    }

                    if !recharge.token.isEmpty {
                        Divider()
                        HStack {
                            Text("Token")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(recharge.token)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func breakdown(_ label: String, _ value: Double, emphasis: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Formatters.taka(value))
                .font(emphasis ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(value < 0 ? .secondary : .primary)
        }
    }
}
