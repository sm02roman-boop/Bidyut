import Foundation
import ActivityKit

/// The Lock Screen countdown for the last stretch before a recharge.
///
/// The days when this matters are the days someone checks the balance five
/// times. A Live Activity turns five deliberate checks into zero: the figure is
/// already on the Lock Screen, and in the Dynamic Island while the phone is in
/// hand.
///
/// It starts only inside the final window and ends as soon as a recharge lands,
/// so it never becomes wallpaper the user learns to ignore.
///
/// The attributes themselves live in `MeterActivityAttributes.swift`, which the
/// widget extension also compiles.
@MainActor
enum LiveActivityController {

    /// Below this many days left, the countdown is worth a place on the Lock Screen.
    static let startThresholdDays: Double = 2.5

    private static var current: Activity<MeterActivityAttributes>? {
        Activity<MeterActivityAttributes>.activities.first
    }

    /// Brings the Live Activity in line with the latest figures.
    ///
    /// Called after every sync: it starts, updates or ends the activity as the
    /// situation requires, so no caller has to reason about which.
    static func refresh(meter: Meter, summary: ConsumptionAnalytics.Summary) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        guard let balance = summary.currentBalance,
              let burn = summary.dailyBurn, burn > 0,
              let days = summary.daysRemaining
        else {
            await end()
            return
        }

        // Comfortably funded again: take it off the Lock Screen.
        guard days <= startThresholdDays else {
            await end()
            return
        }

        let prediction = SupplyPredictor.predict(balance: balance, dailyBurn: burn)
        let state = MeterActivityAttributes.ContentState(
            balance: balance,
            daysRemaining: days,
            dailyBurn: burn,
            cutoffAt: prediction?.earliestCutoff ?? Date().addingTimeInterval(days * 86_400),
            onEmergencyCredit: balance < 0
        )

        if let current {
            await current.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(3 * 3_600))
            )
        } else {
            let attributes = MeterActivityAttributes(
                meterName: meter.displayName,
                customerNumber: meter.customerNumber
            )
            _ = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(3 * 3_600)),
                pushType: nil
            )
        }
    }

    static func end() async {
        for activity in Activity<MeterActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static var isRunning: Bool { current != nil }
}
