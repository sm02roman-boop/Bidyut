import Foundation
import UserNotifications

/// Low-balance warnings.
///
/// The warning that matters is not "balance is low" but "you have about two days
/// left", which needs the burn rate — so alerts are scheduled off the forecast
/// rather than off a bare taka threshold.
@MainActor
enum NotificationService {

    static let defaultThreshold: Double = 200

    private static let categoryID = "LOW_BALANCE"

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Replaces any pending warning for this meter with one based on the latest
    /// figures. Rescheduling on every sync keeps a stale alert from firing after
    /// the user has already recharged.
    static func refreshAlerts(for meter: Meter, summary: ConsumptionAnalytics.Summary) async {
        let center = UNUserNotificationCenter.current()
        let identifiers = AlertKind.allCases.map { $0.identifier(for: meter.customerNumber) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        guard meter.notificationsEnabled else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let threshold = meter.lowBalanceThreshold > 0 ? meter.lowBalanceThreshold : defaultThreshold

        // Fires immediately if the balance is already below the threshold.
        if let balance = meter.currentBalance, balance <= threshold {
            await schedule(
                kind: .lowBalance,
                meter: meter,
                title: "\(meter.displayName): balance low",
                body: lowBalanceBody(balance: balance, summary: summary),
                after: 1
            )
            return
        }

        // Otherwise, warn ahead of the moment supply could actually be cut —
        // which Friendly Hour usually pushes well past the balance reaching zero.
        guard let burn = summary.dailyBurn,
              let prediction = SupplyPredictor.predict(
                balance: meter.currentBalance ?? 0,
                dailyBurn: burn
              )
        else { return }

        // Half a day before the cut-off leaves time to recharge without rushing.
        let target = prediction.earliestCutoff.addingTimeInterval(-12 * 3_600)
        let warnAt = civilisedHour(for: target)
        let delay = warnAt.timeIntervalSinceNow
        guard delay > 60 else { return }

        await schedule(
            kind: .forecast,
            meter: meter,
            title: L10n.callAttention(
                "\(meter.displayName): recharge soon",
                "\(meter.displayName): শীঘ্রই রিচার্জ করুন"
            ),
            body: forecastBody(summary: summary, prediction: prediction),
            after: delay
        )
    }

    /// Moves an alert out of the small hours.
    ///
    /// A warning at 3am wakes someone who can do nothing about it until the
    /// morning, and by then the notification has been swiped away unread. Any
    /// time between 11pm and 7am is pushed to 8am, which is both actionable and
    /// still ahead of the 11am cut-off window.
    private static func civilisedHour(for date: Date, calendar: Calendar = .dhaka) -> Date {
        let hour = calendar.component(.hour, from: date)
        guard hour >= 23 || hour < 7 else { return date }

        let base = hour >= 23
            ? calendar.date(byAdding: .day, value: 1, to: date) ?? date
            : date

        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: base) ?? date
    }

    static func cancelAll(for meter: Meter) {
        let identifiers = AlertKind.allCases.map { $0.identifier(for: meter.customerNumber) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - Internals

    private enum AlertKind: CaseIterable {
        case lowBalance, forecast

        func identifier(for customerNumber: String) -> String {
            switch self {
            case .lowBalance: return "low-\(customerNumber)"
            case .forecast: return "forecast-\(customerNumber)"
            }
        }
    }

    private static func schedule(
        kind: AlertKind,
        meter: Meter,
        title: String,
        body: String,
        after delay: TimeInterval
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = ["customerNumber": meter.customerNumber]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        let request = UNNotificationRequest(
            identifier: kind.identifier(for: meter.customerNumber),
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func lowBalanceBody(balance: Double, summary: ConsumptionAnalytics.Summary) -> String {
        var parts = ["\(Formatters.taka(balance)) left"]
        if let days = summary.daysRemaining {
            parts.append("about \(Formatters.days(days)) at your current usage")
        }
        if let suggested = ConsumptionAnalytics.suggestedRecharge(summary: summary) {
            parts.append("Recharge around \(Formatters.taka(suggested)) to cover a month.")
        }
        return parts.joined(separator: " — ")
    }

    private static func forecastBody(
        summary: ConsumptionAnalytics.Summary,
        prediction: SupplyPredictor.Prediction
    ) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Dhaka")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE h a"
        let cutoff = formatter.string(from: prediction.earliestCutoff)

        return L10n.callAttention(
            "Supply is safe until about \(cutoff). Recharging before then avoids running on negative balance.",
            "আনুমানিক \(cutoff) পর্যন্ত লাইন নিরাপদ। তার আগে রিচার্জ করলে নেগেটিভ ব্যালেন্সে যেতে হবে না।"
        )
    }
}
