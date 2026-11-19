import Foundation

/// Writing the widget's summary lives in the app target only.
///
/// `SharedStore` itself is compiled into both targets and deliberately knows
/// nothing about SwiftData, so the widget never links the model layer.
extension SharedStore {
    @MainActor
    static func publish(meter: Meter) {
        let summary = ConsumptionAnalytics.summarize(meter: meter)
        write(
            WidgetState(
                meterName: meter.displayName,
                customerNumber: meter.customerNumber,
                balance: summary.currentBalance,
                dailyBurn: summary.dailyBurn,
                daysRemaining: summary.daysRemaining,
                depletionDate: summary.depletionDate,
                lastSyncedAt: meter.lastSyncedAt,
                isRunningLow: summary.isRunningLow
            )
        )
    }
}
