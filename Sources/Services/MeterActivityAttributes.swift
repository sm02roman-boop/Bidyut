import Foundation
import ActivityKit

/// The shape of the Lock Screen countdown.
///
/// Compiled into both the app and the widget extension, so it deliberately
/// knows nothing about SwiftData or the network — only the handful of numbers
/// the Lock Screen needs.
struct MeterActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var balance: Double
        var daysRemaining: Double
        var dailyBurn: Double
        /// The first moment supply could actually be cut, Friendly Hour allowed for.
        var cutoffAt: Date
        /// True once the balance has gone negative and emergency credit is in use.
        var onEmergencyCredit: Bool
    }

    var meterName: String
    var customerNumber: String
}
