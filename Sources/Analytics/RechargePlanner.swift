import Foundation

/// Decides what to recharge, and when.
///
/// Three things make this more than "balance divided by daily spend":
///
/// 1. **The slab cliff.** Units are billed progressively, so the month's last
///    units can cost far more than its first. Crossing 400 units raises the
///    rate from ৳9.62 to ৳15.01 — more than half again.
/// 2. **Fixed charges land once a month.** Meter rent and demand charge are
///    taken from the first recharge of each calendar month, so a recharge on
///    the 1st carries them and one on the 20th does not, provided the month
///    already had one. Skipping a month entirely stacks them up.
/// 3. **Prepaid recharges earn a small rebate**, which the portal reports as a
///    negative "রেয়াত" line.
enum RechargePlanner {

    struct Plan: Equatable {
        /// What to recharge now, rounded to a note people actually use.
        var suggested: Double
        /// Days of supply that buys at the present rate of use.
        var coversDays: Double?
        /// Fixed charges this recharge will carry, if it is the month's first.
        var fixedChargesDue: Double
        var isFirstOfMonth: Bool
        /// Rebate this recharge should earn.
        var expectedRebate: Double
        /// Units the recharge buys, priced at the slabs it will fall in.
        var unitsBought: Double?
    }

    /// A projection of where the month is heading, and what that costs.
    struct MonthProjection: Equatable {
        var monthToDateUnits: Double
        var projectedUnits: Double
        var daysRemaining: Double
        var projectedEnergyCharge: Double
        var projectedTotal: Double
        /// Set when the projection crosses into a dearer slab.
        var cliff: CliffForecast?

        struct CliffForecast: Equatable {
            let boundary: Double
            /// Units expected above the boundary by month end.
            let unitsOver: Double
            /// What those units cost at the higher rate.
            let costOfThoseUnits: Double
            /// How much of that is purely the rate step.
            let slabPenalty: Double
            /// Units per day that would land exactly on the boundary.
            let budgetPerDay: Double
            /// Date the boundary is expected to be crossed.
            let crossesOn: Date?
        }
    }

    // MARK: - Month projection

    static func projectMonth(
        meter: Meter,
        estimate: UsageEstimator.Estimate,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> MonthProjection? {
        guard let unitsPerDay = estimate.unitsPerDay, unitsPerDay > 0 else { return nil }

        let monthKey = ConsumptionAnalytics.monthKey(for: now, calendar: calendar)
        let monthToDate = meter.monthlyUsage.first { $0.month == monthKey }?.unit
            ?? estimatedMonthToDate(unitsPerDay: unitsPerDay, now: now, calendar: calendar)

        guard let range = calendar.range(of: .day, in: .month, for: now) else { return nil }
        let dayOfMonth = Double(calendar.component(.day, from: now))
        let daysRemaining = max(Double(range.count) - dayOfMonth, 0)

        let projected = monthToDate + unitsPerDay * daysRemaining
        let energy = TariffEngine.energyCharge(forUnits: projected)

        let sanctioned = (UsageEstimator.sanctionedWatts(meter: meter) ?? 1_000) / 1_000
        let bill = TariffEngine.monthlyBill(
            units: projected,
            sanctionedLoadKW: sanctioned,
            meterRent: recentMeterRent(meter: meter)
        )

        return MonthProjection(
            monthToDateUnits: monthToDate,
            projectedUnits: projected,
            daysRemaining: daysRemaining,
            projectedEnergyCharge: energy,
            projectedTotal: bill.total,
            cliff: cliffForecast(
                monthToDate: monthToDate,
                projected: projected,
                unitsPerDay: unitsPerDay,
                daysRemaining: daysRemaining,
                daysInMonth: Double(range.count),
                dayOfMonth: dayOfMonth,
                now: now,
                calendar: calendar
            )
        )
    }

    /// Warns only while something can still be done about it.
    ///
    /// A boundary already crossed is a fact, not a decision, so the forecast is
    /// built around the one the month is heading toward.
    private static func cliffForecast(
        monthToDate: Double,
        projected: Double,
        unitsPerDay: Double,
        daysRemaining: Double,
        daysInMonth: Double,
        dayOfMonth: Double,
        now: Date,
        calendar: Calendar
    ) -> MonthProjection.CliffForecast? {
        guard let projectedSlab = TariffEngine.slab(atUnits: projected),
              let index = TariffEngine.residentialSlabs.firstIndex(of: projectedSlab),
              index > 0
        else { return nil }

        let previous = TariffEngine.residentialSlabs[index - 1]
        let boundary = previous.through
        let unitsOver = projected - boundary
        guard unitsOver > 0 else { return nil }

        let crossesOn: Date? = {
            guard unitsPerDay > 0, monthToDate < boundary else { return nil }
            let days = (boundary - monthToDate) / unitsPerDay
            guard days <= daysRemaining else { return nil }
            return calendar.date(byAdding: .day, value: Int(days.rounded()), to: now)
        }()

        return MonthProjection.CliffForecast(
            boundary: boundary,
            unitsOver: unitsOver,
            costOfThoseUnits: unitsOver * projectedSlab.rate,
            slabPenalty: unitsOver * (projectedSlab.rate - previous.rate),
            budgetPerDay: max((boundary - monthToDate) / max(daysRemaining, 1), 0),
            crossesOn: crossesOn
        )
    }

    /// Before NESCO publishes the month in progress, infer it from the rate of
    /// use and how far into the month we are.
    private static func estimatedMonthToDate(
        unitsPerDay: Double,
        now: Date,
        calendar: Calendar
    ) -> Double {
        let dayOfMonth = Double(calendar.component(.day, from: now))
        return unitsPerDay * max(dayOfMonth - 1, 0)
    }

    private static func recentMeterRent(meter: Meter) -> Double {
        meter.monthlyUsage
            .sorted { $0.month > $1.month }
            .compactMap(\.meterRent)
            .first ?? 40
    }

    // MARK: - What to recharge

    /// Builds a recharge plan for a target number of days.
    static func plan(
        meter: Meter,
        summary: ConsumptionAnalytics.Summary,
        estimate: UsageEstimator.Estimate,
        targetDays: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Plan? {
        guard let burn = summary.dailyBurn, burn > 0 else { return nil }

        let balance = summary.currentBalance ?? 0
        let first = isFirstRechargeOfMonth(meter: meter, now: now, calendar: calendar)

        let sanctioned = (UsageEstimator.sanctionedWatts(meter: meter) ?? 1_000) / 1_000
        let fixedCharges = first
            ? recentMeterRent(meter: meter) + TariffEngine.demandChargePerKW * sanctioned
            : 0

        let needed = burn * Double(targetDays) - max(balance, 0) + fixedCharges
        guard needed > 0 else {
            return Plan(
                suggested: 0,
                coversDays: balance / burn,
                fixedChargesDue: fixedCharges,
                isFirstOfMonth: first,
                expectedRebate: 0,
                unitsBought: estimate.unitsRemaining
            )
        }

        // People recharge in round notes, so round up to the nearest hundred.
        let suggested = (needed / 100).rounded(.up) * 100

        let monthToDate = projectMonth(meter: meter, estimate: estimate, now: now, calendar: calendar)?
            .monthToDateUnits ?? 0

        return Plan(
            suggested: suggested,
            coversDays: (suggested + balance - fixedCharges) / burn,
            fixedChargesDue: fixedCharges,
            isFirstOfMonth: first,
            expectedRebate: suggested * TariffEngine.prepaidRebateRate,
            unitsBought: TariffEngine.unitsAffordable(
                taka: suggested - fixedCharges,
                startingAtUnits: monthToDate
            )
        )
    }

    /// Whether the next recharge will be the first in this calendar month, and
    /// so will carry the month's fixed charges.
    static func isFirstRechargeOfMonth(
        meter: Meter,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Bool {
        !meter.recharges
            .filter(\.isSuccessful)
            .contains { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
    }

    /// Taka that would take the month exactly to a slab boundary — the most
    /// electricity to buy without funding units at the higher rate.
    static func budgetToStayUnder(
        boundary: Double,
        monthToDateUnits: Double
    ) -> Double? {
        guard monthToDateUnits < boundary else { return nil }
        return TariffEngine.energyCharge(forUnits: boundary)
            - TariffEngine.energyCharge(forUnits: monthToDateUnits)
    }
}
