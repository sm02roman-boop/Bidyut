import SwiftUI
import SwiftData

// MARK: - Slab position

/// Where this month sits on the progressive tariff, and what the next slab costs.
///
/// The bar is the point: a household reading "419 units" learns nothing, but a
/// household seeing itself 19 units past a rate step understands immediately why
/// the bill jumped.
struct SlabProgressCard: View {
    let projection: RechargePlanner.MonthProjection

    private var slabs: [TariffEngine.Slab] {
        TariffEngine.residentialSlabs.filter { !$0.through.isInfinite }
    }

    /// The bar is drawn only to 600 units, where the last finite band ends.
    private let scaleMax: Double = 600

    var body: some View {
        Card(title: "Where this month sits") {
            VStack(alignment: .leading, spacing: 14) {

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%.0f", projection.monthToDateUnits))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("units so far")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatters.taka(TariffEngine.marginalRate(atUnits: projection.monthToDateUnits)))
                        .font(.subheadline.weight(.semibold))
                    Text("/ unit now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                slabBar

                if let cliff = projection.cliff {
                    cliffNotice(cliff)
                } else if let headroom = TariffEngine.unitsUntilNextSlab(atUnits: projection.projectedUnits) {
                    Label(
                        "On track for \(Int(projection.projectedUnits)) units — \(Int(headroom)) below the next rate step.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var slabBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(slabs) { slab in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(for: slab))
                                .frame(width: max(width * (slab.width / scaleMax) - 2, 2))
                        }
                    }

                    // Where the month is now, and where it is heading.
                    marker(at: projection.monthToDateUnits, width: width, filled: true)
                    if projection.projectedUnits > projection.monthToDateUnits {
                        marker(at: projection.projectedUnits, width: width, filled: false)
                    }
                }
            }
            .frame(height: 18)

            HStack {
                ForEach(slabs) { slab in
                    Text(Formatters.taka(slab.rate, decimals: 2))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func marker(at units: Double, width: CGFloat, filled: Bool) -> some View {
        let x = min(max(units / scaleMax, 0), 1) * width
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(filled ? Color.primary : Color.primary.opacity(0.4))
            .frame(width: 3, height: 26)
            .offset(x: x - 1.5)
    }

    /// Later slabs read as hotter, so the bar carries meaning without a legend.
    private func color(for slab: TariffEngine.Slab) -> Color {
        switch slab.rate {
        case ..<6: return Color(red: 0.16, green: 0.62, blue: 0.52)
        case ..<9: return Color(red: 0.28, green: 0.60, blue: 0.44)
        case ..<9.5: return Color(red: 0.62, green: 0.60, blue: 0.30)
        case ..<10: return Color(red: 0.80, green: 0.56, blue: 0.22)
        default: return Color(red: 0.80, green: 0.32, blue: 0.26)
        }
    }

    private func cliffNotice(_ cliff: RechargePlanner.MonthProjection.CliffForecast) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Status.warning.color)
                Text("Heading past \(Int(cliff.boundary)) units")
                    .font(.subheadline.weight(.semibold))
            }

            Text("About \(Int(cliff.unitsOver)) units above the line by month end, costing \(Formatters.takaShort(cliff.costOfThoseUnits)) — of which \(Formatters.takaShort(cliff.slabPenalty)) is the rate step alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if cliff.budgetPerDay > 0 {
                Text("Staying under means about \(String(format: "%.1f", cliff.budgetPerDay)) units a day for the rest of the month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let date = cliff.crossesOn {
                Text("Expected to cross around \(Formatters.dayMonth(date)).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Status.warning.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Derived load

/// Units and watts, derived from the balance falling.
///
/// Labelled as derived throughout: NESCO publishes no live meter reading, so
/// presenting these as a measurement would be a lie the user could not check.
struct LiveUsageCard: View {
    let estimate: UsageEstimator.Estimate

    var body: some View {
        Card {
            HStack(spacing: 14) {
                tile("Avg load", estimate.wattsLabel)
                Divider()
                tile("Per day", estimate.unitsPerDayLabel)
                Divider()
                tile("Left", estimate.unitsRemainingLabel)
            }

            if let month = estimate.rateMonth, month != "recharges" {
                Text("Estimated from the balance falling, priced at \(estimate.rateLabel) — what NESCO actually charged in \(displayMonth(month)).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayMonth(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: key) else { return key }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date)
    }
}

// MARK: - Supply prediction

/// When the power would actually go off, which is rarely when the balance hits
/// zero.
struct SupplyPredictionCard: View {
    let prediction: SupplyPredictor.Prediction
    let meterType: String?

    private var nowState: SupplyPredictor.SupplyState {
        SupplyPredictor.state(at: Date())
    }

    var body: some View {
        Card(title: "When supply would stop") {
            VStack(alignment: .leading, spacing: 12) {

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Balance hits zero")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Formatters.dayMonth(prediction.zeroAt))
                            .font(.title3.weight(.semibold))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Supply could cut")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Formatters.dayMonth(prediction.earliestCutoff))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(prediction.hasGrace ? Theme.Status.healthy.color : Theme.Status.critical.color)
                    }
                }

                if prediction.hasGrace {
                    Text(SupplyPredictor.summary(for: prediction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Zero falls inside the 11am–4pm cut-off window, so there is no grace period. Recharge before then.")
                        .font(.caption)
                        .foregroundStyle(Theme.Status.critical.color)
                }

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: nowState.protectsSupply ? "moon.stars.fill" : "sun.max.fill")
                        .foregroundStyle(nowState.protectsSupply ? Theme.Status.healthy.color : Theme.Status.warning.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Right now: \(nowState.label)")
                            .font(.caption.weight(.medium))
                        Text(nowState.protectsSupply
                             ? "The meter will not disconnect at the moment."
                             : "Disconnection is possible until 4pm.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Emergency credit of about \(Formatters.takaShort(SupplyPredictor.emergencyCredit(meterType: meterType))) is available on the keypad with 99999, repaid from your next recharge.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Appliance cost

/// What running something actually costs, at the rate the next unit will be
/// billed at rather than the month's average.
struct ApplianceCostCard: View {
    let monthToDateUnits: Double

    private struct Appliance: Identifiable {
        let id = UUID()
        let name: String
        let symbol: String
        let watts: Double
    }

    /// Typical draws for common household equipment, offered as starting points
    /// the user can override with the slider.
    private let presets: [Appliance] = [
        Appliance(name: "Ceiling fan", symbol: "fan.fill", watts: 75),
        Appliance(name: "Fridge", symbol: "refrigerator.fill", watts: 150),
        Appliance(name: "1 ton AC", symbol: "snowflake", watts: 1_200),
        Appliance(name: "Water pump", symbol: "drop.fill", watts: 750),
        Appliance(name: "Iron", symbol: "tshirt.fill", watts: 1_000)
    ]

    @State private var watts: Double = 1_200
    @State private var hours: Double = 4

    private var result: (units: Double, taka: Double) {
        TariffEngine.costOfRunning(watts: watts, hours: hours, monthToDateUnits: monthToDateUnits)
    }

    var body: some View {
        Card(title: "What does it cost to run?") {
            VStack(alignment: .leading, spacing: 14) {

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets) { appliance in
                            Button {
                                withAnimation(.snappy) { watts = appliance.watts }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: appliance.symbol)
                                    Text(appliance.name)
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(
                                    watts == appliance.watts ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.1),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Power")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(watts)) W")
                            .font(.caption.weight(.medium))
                    }
                    Slider(value: $watts, in: 25...3_000, step: 25)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Running time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Formatters.hours(hours))
                            .font(.caption.weight(.medium))
                    }
                    Slider(value: $hours, in: 0.5...24, step: 0.5)
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Formatters.taka(result.taka))
                            .font(.title2.weight(.bold))
                        Text(String(format: "%.2f units", result.units))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Formatters.taka(result.taka * 30)) / month")
                            .font(.subheadline.weight(.medium))
                        Text("if run daily")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Priced at \(Formatters.taka(TariffEngine.marginalRate(atUnits: monthToDateUnits))) a unit — the rate your next unit is billed at, not the month's average.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Bill audit

/// Months where NESCO's charge and the published tariff disagree.
///
/// Shown only when something is actually wrong. A permanent "all clear" panel
/// would be read once and then ignored, which is exactly the habit that lets a
/// real discrepancy slip past.
struct BillAuditCard: View {
    let audits: [BillAuditor.MonthAudit]

    private var flagged: [BillAuditor.MonthAudit] {
        audits.filter { !$0.isClean }
    }

    var body: some View {
        if !flagged.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.magnifyingglass")
                            .foregroundStyle(Theme.Status.warning.color)
                        Text(L10n.callAttention("Bill check", "বিল যাচাই"))
                            .font(.subheadline.weight(.semibold))
                    }

                    if let headline = BillAuditor.headline(for: audits) {
                        Text(headline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(flagged.prefix(3)) { audit in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(monthLabel(audit.month))
                                .font(.caption.weight(.semibold))

                            ForEach(audit.findings) { finding in
                                HStack {
                                    Text(finding.kind.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Formatters.taka(finding.charged))
                                        .font(.caption2.weight(.medium))
                                    Text(finding.overcharged ? "↑" : "↓")
                                        .font(.caption2)
                                        .foregroundStyle(finding.overcharged ? Theme.Status.critical.color : Theme.Status.healthy.color)
                                    Text(Formatters.taka(finding.expected))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Text(L10n.callAttention(
                        "Charged against what the published tariff gives. Take the figures to 16603 if they look wrong.",
                        "প্রকাশিত ট্যারিফ অনুযায়ী যা হওয়ার কথা, তার সাথে মিলিয়ে দেখা। অমিল মনে হলে ১৬৬০৩-এ এই সংখ্যাগুলো জানান।"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func monthLabel(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: key) else { return key }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        return BengaliDigits.localize(formatter.string(from: date))
    }
}

// MARK: - Anomaly

/// A change in how much is being used, surfaced while it can still be acted on.
struct AnomalyCard: View {
    let anomaly: AnomalyDetector.Anomaly

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: anomaly.isSurge ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(anomaly.isSurge ? Theme.Status.warning.color : Theme.Status.healthy.color)

                VStack(alignment: .leading, spacing: 4) {
                    Text(anomaly.isSurge
                         ? L10n.callAttention("Usage has risen", "খরচ বেড়েছে")
                         : L10n.callAttention("Usage has fallen", "খরচ কমেছে"))
                        .font(.subheadline.weight(.semibold))
                    Text(anomaly.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Siri snippet

/// The card Siri shows alongside the spoken answer.
struct IntentBalanceView: View {
    let state: SharedStore.WidgetState?
    var units: String?

    var body: some View {
        if let state {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.meterName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Formatters.taka(state.balance))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                HStack(spacing: 10) {
                    if let days = state.daysRemaining {
                        Label(Formatters.days(days), systemImage: "clock")
                    }
                    if let units {
                        Label(units, systemImage: "bolt")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        } else {
            Text("No meter added yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }
}
