import Foundation

/// Derives usable figures from the raw history.
///
/// NESCO publishes consumption monthly only, so everything daily — burn rate,
/// days remaining, the depletion date — is reconstructed here by differencing
/// consecutive balance snapshots and adding back whatever was recharged in
/// between. The quality of these numbers rises with the number of syncs.
enum ConsumptionAnalytics {

    /// A single measured stretch between two balance readings.
    struct Interval: Equatable {
        let start: Date
        let end: Date
        /// Taka consumed over the interval, recharges accounted for.
        let consumed: Double

        var days: Double {
            max(end.timeIntervalSince(start) / 86_400, 0)
        }

        var dailyBurn: Double? {
            days > 0.2 ? consumed / days : nil
        }
    }

    /// How much confidence to place in a burn-rate estimate.
    enum Confidence: String {
        case none, low, medium, high

        var label: String {
            switch self {
            case .none: return "Not enough data"
            case .low: return "Rough estimate"
            case .medium: return "Fair estimate"
            case .high: return "Good estimate"
            }
        }
    }

    struct Summary {
        var currentBalance: Double?
        var dailyBurn: Double?
        var confidence: Confidence = .none
        var daysRemaining: Double?
        var depletionDate: Date?
        var observedDays: Double = 0
        var intervalCount: Int = 0

        /// Average cost per day over the last full calendar month, if known.
        var lastMonthUnits: Double?
        var thisMonthRecharged: Double?
        var lastRecharge: Recharge?
        var averageFixedCharges: Double?

        var isRunningLow: Bool {
            guard let daysRemaining else { return false }
            return daysRemaining <= 3
        }
    }

    // MARK: - Entry point

    static func summarize(
        meter: Meter,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Summary {
        var summary = Summary()
        summary.currentBalance = meter.currentBalance

        let snapshots = meter.snapshots.sorted { $0.capturedAt < $1.capturedAt }
        let recharges = meter.recharges.filter(\.isSuccessful).sorted { $0.date < $1.date }

        let intervals = buildIntervals(snapshots: snapshots, recharges: recharges)
        summary.intervalCount = intervals.count
        summary.observedDays = intervals.reduce(0) { $0 + $1.days }

        // Prefer measured intervals; fall back to NESCO's own monthly figure so a
        // meter added today still gets a forecast.
        let monthlyFallback = lastCompleteMonthDailyAverage(meter: meter, now: now, calendar: calendar)

        if let burn = weightedDailyBurn(from: intervals, now: now) ?? monthlyFallback {
            summary.dailyBurn = burn
            summary.confidence = intervals.isEmpty
                ? .low
                : confidence(for: intervals, observedDays: summary.observedDays)

            if let balance = summary.currentBalance, burn > 0 {
                // A negative balance means emergency credit is already in use.
                let usable = max(balance, 0)
                let days = usable / burn
                summary.daysRemaining = days
                summary.depletionDate = now.addingTimeInterval(days * 86_400)
            }
        }

        summary.lastRecharge = recharges.last
        summary.thisMonthRecharged = recharges
            .filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.totalAmount }

        if let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) {
            let key = monthKey(for: lastMonth, calendar: calendar)
            summary.lastMonthUnits = meter.monthlyUsage.first { $0.month == key }?.unit
        }

        // NESCO's monthly statement is the more reliable source for fixed costs;
        // per-recharge deductions vary with arrears and are only a fallback.
        summary.averageFixedCharges = monthlyFixedCharges(meter: meter, now: now, calendar: calendar)
            ?? averageFixedCharges(from: recharges)

        return summary
    }

    // MARK: - Intervals

    /// Pairs up consecutive snapshots into measured intervals.
    ///
    /// Balance only falls through use and rises through recharge, so:
    ///
    ///     consumed = balanceAtStart + creditedInBetween - balanceAtEnd
    ///
    /// The credited figure is the electricity portion of a recharge, not the
    /// amount paid — NESCO takes meter rent, demand charge and VAT off the top
    /// before the remainder reaches the balance.
    static func buildIntervals(snapshots: [BalanceSnapshot], recharges: [Recharge]) -> [Interval] {
        guard snapshots.count >= 2 else { return [] }

        var intervals: [Interval] = []

        for (previous, current) in zip(snapshots, snapshots.dropFirst()) {
            let credited = recharges
                .filter { $0.date > previous.capturedAt && $0.date <= current.capturedAt }
                .reduce(0.0) { $0 + ($1.electricityAmount ?? $1.totalAmount) }

            let consumed = previous.balance + credited - current.balance
            let interval = Interval(start: previous.capturedAt, end: current.capturedAt, consumed: consumed)

            // Discard physically impossible intervals. A negative result means a
            // recharge was missed or landed outside the window, so the reading
            // would skew the average rather than inform it.
            guard consumed >= 0, interval.days > 0.2, interval.days < 60 else { continue }
            intervals.append(interval)
        }

        return intervals
    }

    /// Recent days describe current habits better than old ones, so intervals are
    /// weighted by recency with a 21-day half-life.
    static func weightedDailyBurn(from intervals: [Interval], now: Date) -> Double? {
        let usable = intervals.filter { $0.dailyBurn != nil }
        guard !usable.isEmpty else { return nil }

        let halfLife = 21.0
        var weightedSum = 0.0
        var weightTotal = 0.0

        for interval in usable {
            guard let burn = interval.dailyBurn else { continue }
            let age = max(now.timeIntervalSince(interval.end) / 86_400, 0)
            // Longer intervals are better measurements, so weight by duration too.
            let weight = pow(0.5, age / halfLife) * interval.days
            weightedSum += burn * weight
            weightTotal += weight
        }

        guard weightTotal > 0 else { return nil }
        return weightedSum / weightTotal
    }

    static func confidence(for intervals: [Interval], observedDays: Double) -> Confidence {
        switch (intervals.count, observedDays) {
        case (0, _): return .none
        case (1...2, _): return .low
        case (_, ..<7): return .low
        case (_, 7..<21): return .medium
        default: return .high
        }
    }

    /// Mean of the fixed charges NESCO takes from each recharge.
    static func averageFixedCharges(from recharges: [Recharge]) -> Double? {
        let values = recharges.suffix(6).compactMap(\.totalDeductions)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// NESCO's own figure for the last month that has closed, as taka per day.
    ///
    /// The month in progress is excluded because its total is still growing and
    /// would understate the rate.
    static func lastCompleteMonthDailyAverage(
        meter: Meter,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Double? {
        let currentKey = monthKey(for: now, calendar: calendar)
        return meter.monthlyUsage
            .filter { $0.month != currentKey }
            .sorted { $0.month < $1.month }
            .last?
            .dailyAverage
    }

    /// Fixed monthly cost — meter rent, demand charge, PFC and VAT — taken from
    /// the last closed month rather than inferred from recharges.
    static func monthlyFixedCharges(
        meter: Meter,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Double? {
        let currentKey = monthKey(for: now, calendar: calendar)
        return meter.monthlyUsage
            .filter { $0.month != currentKey }
            .sorted { $0.month < $1.month }
            .last?
            .fixedCharges
    }

    // MARK: - Daily series for charts

    /// Average daily spend per calendar day, spread evenly across each interval.
    ///
    /// A single interval can span several days, so its consumption is divided
    /// across the days it covers rather than dumped on the end date.
    static func dailySeries(
        meter: Meter,
        days: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> [(date: Date, amount: Double)] {
        let snapshots = meter.snapshots.sorted { $0.capturedAt < $1.capturedAt }
        let recharges = meter.recharges.filter(\.isSuccessful).sorted { $0.date < $1.date }
        let intervals = buildIntervals(snapshots: snapshots, recharges: recharges)
        guard !intervals.isEmpty else { return [] }

        var buckets: [Date: Double] = [:]

        for interval in intervals {
            guard let perDay = interval.dailyBurn else { continue }
            var cursor = calendar.startOfDay(for: interval.start)
            let last = calendar.startOfDay(for: interval.end)

            while cursor <= last {
                // Count only the portion of this day that the interval covers.
                let dayStart = max(cursor, interval.start)
                let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: cursor) ?? interval.end, interval.end)
                let covered = max(dayEnd.timeIntervalSince(dayStart) / 86_400, 0)
                buckets[cursor, default: 0] += perDay * covered

                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }

        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else {
            return []
        }

        return buckets
            .filter { $0.key >= cutoff }
            .map { (date: $0.key, amount: $0.value) }
            .sorted { $0.date < $1.date }
    }

    /// Balance readings for the trend chart.
    static func balanceSeries(meter: Meter, days: Int = 30, now: Date = Date(), calendar: Calendar = .dhaka)
        -> [(date: Date, balance: Double)] {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        return meter.snapshots
            .filter { $0.capturedAt >= cutoff }
            .sorted { $0.capturedAt < $1.capturedAt }
            .map { (date: $0.capturedAt, balance: $0.balance) }
    }

    // MARK: - Recharge advice

    /// Suggests a recharge that lasts a target number of days, rounded to a
    /// sensible note value and topped up to cover the fixed charges NESCO takes.
    static func suggestedRecharge(summary: Summary, targetDays: Int = 30) -> Double? {
        guard let burn = summary.dailyBurn, burn > 0 else { return nil }

        let balance = summary.currentBalance ?? 0
        let needed = (burn * Double(targetDays)) - max(balance, 0)
        let withCharges = needed + (summary.averageFixedCharges ?? 0)
        guard withCharges > 0 else { return nil }

        // Round up to the nearest 100 Tk — how people actually recharge.
        return (withCharges / 100).rounded(.up) * 100
    }

    static func monthKey(for date: Date, calendar: Calendar = .dhaka) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
}

extension Calendar {
    /// The meter runs on Dhaka time, so every day boundary must too.
    static var dhaka: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka") ?? .current
        return calendar
    }
}
