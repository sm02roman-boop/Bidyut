import Foundation

/// Works out when the power would actually go off.
///
/// A prepaid meter hitting zero does not cut supply there and then. NESCO runs
/// a Friendly Hour from 4:00 PM until 11:00 AM the next day, and treats Friday,
/// Saturday and government holidays as 24-hour holiday mode; through all of
/// those the meter keeps supplying and books the usage as negative balance,
/// recovered from the next recharge.
///
/// So the only window in which a meter can actually disconnect is **11:00 AM to
/// 4:00 PM, Sunday to Thursday** — five hours a day, five days a week. That
/// turns "you run out Friday afternoon" into "nothing happens until Sunday
/// morning", which is the difference between panic and a calm errand.
enum SupplyPredictor {

    /// Friendly Hour begins at 16:00 and runs to 11:00 the next morning.
    static let friendlyHourStartHour = 16
    static let friendlyHourEndHour = 11

    /// Emergency credit, taken on the meter keypad with 99999.
    ///
    /// Published limits differ by phase: single-phase connections are generally
    /// quoted at ৳200 and three-phase at ৳500, and some NESCO material quotes
    /// ৳500 generally. Treated as a floor so the app never over-promises.
    static let singlePhaseEmergencyCredit: Double = 200
    static let threePhaseEmergencyCredit: Double = 500

    enum SupplyState: Equatable {
        /// Inside Friendly Hour — supply continues even at zero.
        case friendlyHour
        /// Friday, Saturday or a public holiday — supply continues all day.
        case holiday
        /// The meter can disconnect during this window.
        case cutoffWindow

        var label: String {
            switch self {
            case .friendlyHour: return "Friendly Hour"
            case .holiday: return "Holiday"
            case .cutoffWindow: return "Cut-off window"
            }
        }

        var protectsSupply: Bool { self != .cutoffWindow }
    }

    /// Which regime a given moment falls in.
    ///
    /// Government holidays beyond the weekend are not published in a form the
    /// app can read, so only the weekly ones are known for certain; an unknown
    /// public holiday only ever makes the real answer later, never earlier.
    static func state(at date: Date, calendar: Calendar = .dhaka) -> SupplyState {
        let weekday = calendar.component(.weekday, from: date)
        // Gregorian weekday: 6 = Friday, 7 = Saturday.
        if weekday == 6 || weekday == 7 { return .holiday }

        let hour = calendar.component(.hour, from: date)
        if hour >= friendlyHourStartHour || hour < friendlyHourEndHour {
            return .friendlyHour
        }
        return .cutoffWindow
    }

    struct Prediction: Equatable {
        /// When the balance itself reaches zero.
        let zeroAt: Date
        /// The first moment the meter could actually disconnect.
        let earliestCutoff: Date
        /// How long the protected period buys beyond zero.
        let graceHours: Double
        /// Taka of negative balance likely accrued by then, repaid on recharge.
        let accruedDebt: Double
        let stateAtZero: SupplyState

        var hasGrace: Bool { graceHours > 0.5 }
    }

    /// Predicts the real cut-off from the balance and burn rate.
    static func predict(
        balance: Double,
        dailyBurn: Double,
        from now: Date = Date(),
        calendar: Calendar = .dhaka
    ) -> Prediction? {
        guard dailyBurn > 0 else { return nil }

        let daysToZero = max(balance, 0) / dailyBurn
        let zeroAt = now.addingTimeInterval(daysToZero * 86_400)
        let stateAtZero = state(at: zeroAt, calendar: calendar)

        let cutoff = nextCutoffMoment(onOrAfter: zeroAt, calendar: calendar)
        let graceHours = cutoff.timeIntervalSince(zeroAt) / 3_600
        let accruedDebt = dailyBurn * (graceHours / 24)

        return Prediction(
            zeroAt: zeroAt,
            earliestCutoff: cutoff,
            graceHours: max(graceHours, 0),
            accruedDebt: max(accruedDebt, 0),
            stateAtZero: stateAtZero
        )
    }

    /// Walks forward to the first instant inside a cut-off window.
    static func nextCutoffMoment(onOrAfter date: Date, calendar: Calendar = .dhaka) -> Date {
        if state(at: date, calendar: calendar) == .cutoffWindow {
            return date
        }

        var cursor = date
        // At most a fortnight of hops; the weekly pattern guarantees a hit well
        // before that, and the bound stops a malformed calendar looping forever.
        for _ in 0..<(24 * 14) {
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next

            if state(at: cursor, calendar: calendar) == .cutoffWindow {
                // Step back to the exact start of the window, 11:00.
                return calendar.date(
                    bySettingHour: friendlyHourEndHour, minute: 0, second: 0, of: cursor
                ) ?? cursor
            }
        }
        return cursor
    }

    /// Emergency credit this meter can draw on, by phase.
    static func emergencyCredit(meterType: String?) -> Double {
        guard let meterType else { return singlePhaseEmergencyCredit }
        let isThreePhase = meterType.localizedCaseInsensitiveContains("3p")
            || meterType.localizedCaseInsensitiveContains("three")
        return isThreePhase ? threePhaseEmergencyCredit : singlePhaseEmergencyCredit
    }

    /// Plain-language summary for the dashboard.
    static func summary(for prediction: Prediction, calendar: Calendar = .dhaka) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE h a"

        guard prediction.hasGrace else {
            return "Balance reaches zero inside the cut-off window, so supply could stop straight away."
        }

        let cutoff = formatter.string(from: prediction.earliestCutoff)
        let reason = prediction.stateAtZero == .holiday ? "the weekend" : "Friendly Hour"

        return "Balance hits zero during \(reason), so supply keeps running until \(cutoff) at the earliest — about \(Int(prediction.graceHours)) hours of grace, booked as roughly ৳\(Int(prediction.accruedDebt)) of negative balance."
    }
}
