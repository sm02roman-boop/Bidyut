import Foundation

/// Turns taka into units and watts.
///
/// NESCO's prepaid meter is metered in taka: the portal reports a balance, a
/// monthly total and the units bought with each recharge, but never an
/// instantaneous reading. So there is no live kW feed to read — the figures here
/// are derived, and the app labels them that way rather than presenting them as
/// meter telemetry.
///
/// The bridge between taka and units is the *effective rate*: what NESCO
/// actually charged over a whole closed month, electricity taka divided by
/// units. That is more honest than a published slab rate, because it already
/// contains whatever mix of slabs the household landed in.
enum UsageEstimator {

    struct Estimate: Equatable {
        /// Taka per kWh, as NESCO actually billed it.
        var effectiveRate: Double?
        /// Source month of the rate, for display (`yyyy-MM`).
        var rateMonth: String?

        var unitsPerDay: Double?
        /// Mean power draw implied by `unitsPerDay`, in watts.
        var averageWatts: Double?
        /// Units the present balance still buys.
        var unitsRemaining: Double?

        /// How far into the sanctioned load the average draw sits, 0...1.
        var loadFraction: Double?
    }

    /// A rate outside this range means the arithmetic went wrong — a month with
    /// a near-zero unit count, say — so it is discarded rather than shown.
    private static let plausibleRate: ClosedRange<Double> = 1.0...40.0

    static func estimate(
        meter: Meter,
        summary: ConsumptionAnalytics.Summary,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Estimate {
        var estimate = Estimate()

        guard let rate = effectiveRate(meter: meter, now: now, calendar: calendar) else {
            return estimate
        }

        estimate.effectiveRate = rate.value
        estimate.rateMonth = rate.month

        if let burn = summary.dailyBurn, burn > 0 {
            let units = burn / rate.value
            estimate.unitsPerDay = units
            estimate.averageWatts = units / 24 * 1_000
        }

        if let balance = summary.currentBalance {
            estimate.unitsRemaining = max(balance, 0) / rate.value
        }

        if let watts = estimate.averageWatts, let sanctioned = sanctionedWatts(meter: meter) {
            estimate.loadFraction = min(max(watts / sanctioned, 0), 1)
        }

        return estimate
    }

    // MARK: - Effective rate

    struct Rate: Equatable {
        var value: Double
        var month: String
    }

    /// The most recent closed month that produces a believable rate.
    ///
    /// The month in progress is skipped: its totals are still accumulating, and
    /// a part-month's taka over a part-month's units is noisier than it looks.
    static func effectiveRate(
        meter: Meter,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Rate? {
        let currentKey = ConsumptionAnalytics.monthKey(for: now, calendar: calendar)

        let fromMonths = meter.monthlyUsage
            .filter { $0.month != currentKey }
            .sorted { $0.month > $1.month }
            .lazy
            .compactMap { usage -> Rate? in
                guard let taka = usage.electricityTaka, let units = usage.unit, units > 0 else { return nil }
                let value = taka / units
                guard plausibleRate.contains(value) else { return nil }
                return Rate(value: value, month: usage.month)
            }
            .first

        if let fromMonths { return fromMonths }

        // Nothing monthly yet: fall back to what recharges imply. This is the
        // weaker source — a recharge's unit figure is priced at the slab the
        // purchase landed in, not the household's blended rate.
        let recharges = meter.recharges.filter(\.isSuccessful)
        let taka = recharges.compactMap(\.electricityAmount).reduce(0, +)
        let units = recharges.compactMap(\.energyUnit).reduce(0, +)
        guard units > 0 else { return nil }

        let value = taka / units
        guard plausibleRate.contains(value) else { return nil }
        return Rate(value: value, month: "recharges")
    }

    /// Sanctioned load as watts. The portal reports it in kilowatts, as text.
    static func sanctionedWatts(meter: Meter) -> Double? {
        guard let raw = meter.sanctionedLoad,
              let kilowatts = NescoParser.number(raw),
              kilowatts > 0
        else { return nil }
        return kilowatts * 1_000
    }
}

extension UsageEstimator.Estimate {
    var wattsLabel: String {
        guard let averageWatts else { return "—" }
        if averageWatts >= 1_000 {
            return String(format: "%.2f kW", averageWatts / 1_000)
        }
        return "\(Int(averageWatts.rounded())) W"
    }

    var unitsPerDayLabel: String {
        guard let unitsPerDay else { return "—" }
        return String(format: "%.1f kWh", unitsPerDay)
    }

    var unitsRemainingLabel: String {
        guard let unitsRemaining else { return "—" }
        return String(format: "%.1f kWh", unitsRemaining)
    }

    var rateLabel: String {
        guard let effectiveRate else { return "—" }
        return String(format: "৳%.2f per unit", effectiveRate)
    }
}
