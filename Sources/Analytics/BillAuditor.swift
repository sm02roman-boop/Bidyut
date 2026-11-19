import Foundation

/// Checks NESCO's arithmetic.
///
/// The tariff engine reproduces this meter's own statements to within a paisa.
/// That agreement is what makes the reverse useful: when a month *stops*
/// matching, the discrepancy is real and worth a phone call. Nobody re-derives
/// their electricity bill by hand, so an error that does happen goes unnoticed
/// and unchallenged.
///
/// The audit is deliberately conservative. A false alarm sends someone to a
/// hotline to argue a case that is not there, which is worse than staying quiet.
enum BillAuditor {

    struct Finding: Equatable, Identifiable {
        enum Kind: String {
            case energyCharge
            case demandCharge
            case vat
            case rebate

            var label: String {
                switch self {
                case .energyCharge: return L10n.callAttention("Energy charge", "বিদ্যুৎ বিল")
                case .demandCharge: return L10n.callAttention("Demand charge", "ডিমান্ড চার্জ")
                case .vat: return L10n.callAttention("VAT", "ভ্যাট")
                case .rebate: return L10n.callAttention("Rebate", "রেয়াত")
                }
            }
        }

        let month: String
        let kind: Kind
        let expected: Double
        let charged: Double

        var id: String { "\(month)-\(kind.rawValue)" }

        /// Positive means NESCO charged more than the tariff implies.
        var difference: Double { charged - expected }

        var overcharged: Bool { difference > 0 }
    }

    struct MonthAudit: Equatable, Identifiable {
        let month: String
        let units: Double
        let findings: [Finding]

        var id: String { month }
        var isClean: Bool { findings.isEmpty }

        /// Net difference across every finding for the month.
        var netDifference: Double {
            findings.reduce(0) { $0 + $1.difference }
        }
    }

    /// How far a figure may drift before it counts as a discrepancy.
    ///
    /// NESCO rounds at several points and bills part-months, so a few taka of
    /// slack is normal. The floor stops tiny months from tripping on rounding
    /// alone; the proportional term keeps large months from hiding a real gap
    /// inside a fixed allowance.
    static func tolerance(for expected: Double) -> Double {
        max(5, abs(expected) * 0.01)
    }

    /// Audits every closed month the app holds.
    static func audit(
        meter: Meter,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> [MonthAudit] {
        let currentKey = ConsumptionAnalytics.monthKey(for: now, calendar: calendar)
        let sanctionedKW = (UsageEstimator.sanctionedWatts(meter: meter) ?? 0) / 1_000

        return meter.monthlyUsage
            .filter { $0.month != currentKey }
            .sorted { $0.month > $1.month }
            .compactMap { audit(month: $0, sanctionedKW: sanctionedKW) }
    }

    static func audit(month usage: MonthlyUsage, sanctionedKW: Double) -> MonthAudit? {
        guard let units = usage.unit, units > 0 else { return nil }

        var findings: [Finding] = []

        // The energy charge is the one worth real scrutiny: it is the largest
        // line and the only one computed from a progressive scale.
        if let charged = usage.electricityTaka {
            let expected = TariffEngine.energyCharge(forUnits: units)
            if abs(charged - expected) > tolerance(for: expected) {
                findings.append(
                    Finding(month: usage.month, kind: .energyCharge, expected: expected, charged: charged)
                )
            }
        }

        // Demand charge is a flat multiplication, so any gap is a plain error —
        // but only check it when the sanctioned load is actually known.
        if sanctionedKW > 0, let charged = usage.demandCharge {
            let expected = TariffEngine.demandChargePerKW * sanctionedKW
            if abs(charged - expected) > 1 {
                findings.append(
                    Finding(month: usage.month, kind: .demandCharge, expected: expected, charged: charged)
                )
            }
        }

        if let charged = usage.vat, let energy = usage.electricityTaka {
            let expected = energy * TariffEngine.vatRate
            if abs(charged - expected) > tolerance(for: expected) {
                findings.append(
                    Finding(month: usage.month, kind: .vat, expected: expected, charged: charged)
                )
            }
        }

        // The portal reports the rebate as a negative number.
        if let rebate = usage.rebate, let recharged = usage.totalRecharge, recharged > 0 {
            let credited = abs(rebate)
            let expected = recharged * TariffEngine.prepaidRebateRate
            if abs(credited - expected) > tolerance(for: expected) {
                findings.append(
                    Finding(month: usage.month, kind: .rebate, expected: expected, charged: credited)
                )
            }
        }

        return MonthAudit(month: usage.month, units: units, findings: findings)
    }

    /// A one-line verdict for the dashboard.
    static func headline(for audits: [MonthAudit]) -> String? {
        let flagged = audits.filter { !$0.isClean }
        guard !flagged.isEmpty else { return nil }

        let total = flagged.reduce(0) { $0 + $1.netDifference }
        guard abs(total) > 1 else { return nil }

        let months = flagged.count
        return L10n.callAttention(
            "\(months) month\(months == 1 ? "" : "s") do not match the published tariff, by \(Formatters.taka(abs(total))) in total.",
            "\(BengaliDigits.localize("\(months)")) মাসের হিসাব প্রকাশিত ট্যারিফের সাথে মিলছে না, মোট \(Formatters.taka(abs(total))) পার্থক্য।"
        )
    }
}

/// Spots a change in how much electricity is being used.
///
/// The cause is usually mundane — a guest, hotter weather, something left
/// switched on — but the user is the only one who can tell which, and they can
/// only do that if someone tells them the change happened.
enum AnomalyDetector {

    struct Anomaly: Equatable {
        enum Kind: Equatable {
            case surge(percent: Double)
            case drop(percent: Double)
        }

        let kind: Kind
        let recentDailyBurn: Double
        let baselineDailyBurn: Double
        let observedDays: Double

        var message: String {
            switch kind {
            case .surge(let percent):
                let pct = BengaliDigits.localize("\(Int(percent.rounded()))")
                return L10n.callAttention(
                    "Usage is up \(Int(percent.rounded()))% on the previous stretch — \(Formatters.taka(recentDailyBurn)) a day against \(Formatters.taka(baselineDailyBurn)). Worth a look for something left running.",
                    "আগের তুলনায় খরচ \(pct)% বেড়েছে — দিনে \(Formatters.taka(recentDailyBurn)), আগে ছিল \(Formatters.taka(baselineDailyBurn))। কিছু চালু রয়ে গেছে কিনা দেখুন।"
                )
            case .drop(let percent):
                let pct = BengaliDigits.localize("\(Int(percent.rounded()))")
                return L10n.callAttention(
                    "Usage is down \(Int(percent.rounded()))% — \(Formatters.taka(recentDailyBurn)) a day against \(Formatters.taka(baselineDailyBurn)).",
                    "খরচ \(pct)% কমেছে — দিনে \(Formatters.taka(recentDailyBurn)), আগে ছিল \(Formatters.taka(baselineDailyBurn))।"
                )
            }
        }

        var isSurge: Bool {
            if case .surge = kind { return true }
            return false
        }
    }

    /// A change has to be this large to be worth mentioning.
    ///
    /// Day-to-day variation in a household runs well over ten per cent, so a
    /// lower threshold would fire constantly and be learned as noise.
    static let threshold: Double = 30

    /// Compares the last week of measured intervals against the week before.
    ///
    /// Both windows need real coverage: comparing a well-measured week against
    /// a single stray reading produces a number that looks precise and means
    /// nothing.
    static func detect(
        meter: Meter,
        now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Anomaly? {
        let snapshots = meter.snapshots.sorted { $0.capturedAt < $1.capturedAt }
        let recharges = meter.recharges.filter(\.isSuccessful).sorted { $0.date < $1.date }
        let intervals = ConsumptionAnalytics.buildIntervals(snapshots: snapshots, recharges: recharges)
        guard intervals.count >= 2 else { return nil }

        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
              let fortnightAgo = calendar.date(byAdding: .day, value: -14, to: now)
        else { return nil }

        let recent = intervals.filter { $0.end > weekAgo }
        let baseline = intervals.filter { $0.end <= weekAgo && $0.end > fortnightAgo }

        guard let recentBurn = averageBurn(recent), recentBurn > 0,
              let baselineBurn = averageBurn(baseline), baselineBurn > 0
        else { return nil }

        let recentDays = recent.reduce(0) { $0 + $1.days }
        let baselineDays = baseline.reduce(0) { $0 + $1.days }
        guard recentDays >= 2, baselineDays >= 2 else { return nil }

        let change = (recentBurn - baselineBurn) / baselineBurn * 100
        guard abs(change) >= threshold else { return nil }

        return Anomaly(
            kind: change > 0 ? .surge(percent: change) : .drop(percent: abs(change)),
            recentDailyBurn: recentBurn,
            baselineDailyBurn: baselineBurn,
            observedDays: recentDays
        )
    }

    /// Consumption-weighted, so a long interval counts for more than a short one.
    private static func averageBurn(_ intervals: [ConsumptionAnalytics.Interval]) -> Double? {
        let days = intervals.reduce(0) { $0 + $1.days }
        guard days > 0 else { return nil }
        let consumed = intervals.reduce(0) { $0 + $1.consumed }
        return consumed / days
    }
}
