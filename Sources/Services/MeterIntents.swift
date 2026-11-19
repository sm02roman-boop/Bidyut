import AppIntents
import SwiftData
import Foundation

/// Siri and Shortcuts.
///
/// Checking the balance is a ten-second errand done several times a week, so it
/// should not require opening an app at all — asking out loud, or tapping a
/// Shortcut, is the whole point.
struct CheckBalanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Check meter balance"
    static var description = IntentDescription(
        "Reads the current NESCO prepaid balance and how long it should last."
    )

    /// Siri should speak the answer rather than push the app forward.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        // Opened exactly as the app opens it, so Siri never reads an empty
        // store on a build without the App Group.
        let context = ModelContext(try BidyutApp.makeContainer())

        let meters = try context.fetch(FetchDescriptor<Meter>())
        guard let meter = meters.first(where: \.isPrimary) ?? meters.first else {
            return .result(dialog: "No meter has been added to Bidyut yet.") {
                IntentBalanceView(state: nil)
            }
        }

        // Refresh before answering: a stale figure is worse than a slow one when
        // the question is whether to recharge today.
        let service = SyncService(context: context)
        try? await service.sync(meter: meter)

        let summary = ConsumptionAnalytics.summarize(meter: meter)
        let estimate = UsageEstimator.estimate(meter: meter, summary: summary)

        let balance = Formatters.taka(summary.currentBalance)
        var spoken = "\(meter.displayName) has \(balance)."

        if let days = summary.daysRemaining {
            spoken += " That is about \(Formatters.days(days)) at your current usage."

            if let prediction = SupplyPredictor.predict(
                balance: summary.currentBalance ?? 0,
                dailyBurn: summary.dailyBurn ?? 0
            ), prediction.hasGrace {
                spoken += " Friendly Hour means supply would keep running past zero."
            }
        }

        let state = SharedStore.WidgetState(
            meterName: meter.displayName,
            customerNumber: meter.customerNumber,
            balance: summary.currentBalance,
            dailyBurn: summary.dailyBurn,
            daysRemaining: summary.daysRemaining,
            depletionDate: summary.depletionDate,
            lastSyncedAt: meter.lastSyncedAt,
            isRunningLow: summary.isRunningLow
        )

        return .result(dialog: IntentDialog(stringLiteral: spoken)) {
            IntentBalanceView(state: state, units: estimate.unitsRemainingLabel)
        }
    }
}

/// Asks what an appliance costs to run right now, at the marginal slab rate.
///
/// The marginal rate is the one that matters for a decision — the blended
/// average is always lower and would make the answer look cheaper than it is.
struct ApplianceCostIntent: AppIntent {
    static var title: LocalizedStringResource = "Cost to run an appliance"
    static var description = IntentDescription(
        "Works out what running something costs at today's marginal rate."
    )

    @Parameter(title: "Watts", default: 1000)
    var watts: Double

    @Parameter(title: "Hours", default: 1)
    var hours: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Opened exactly as the app opens it, so Siri never reads an empty
        // store on a build without the App Group.
        let context = ModelContext(try BidyutApp.makeContainer())

        let meters = try context.fetch(FetchDescriptor<Meter>())
        guard let meter = meters.first(where: \.isPrimary) ?? meters.first else {
            return .result(dialog: "No meter has been added to Bidyut yet.")
        }

        let summary = ConsumptionAnalytics.summarize(meter: meter)
        let estimate = UsageEstimator.estimate(meter: meter, summary: summary)
        let projection = RechargePlanner.projectMonth(meter: meter, estimate: estimate)
        let monthToDate = projection?.monthToDateUnits ?? 0

        let result = TariffEngine.costOfRunning(
            watts: watts,
            hours: hours,
            monthToDateUnits: monthToDate
        )
        let rate = TariffEngine.marginalRate(atUnits: monthToDate)

        let dialog = "\(Int(watts)) watts for \(Formatters.hours(hours)) uses about \(String(format: "%.2f", result.units)) units — \(Formatters.taka(result.taka)) at your current rate of \(Formatters.taka(rate)) a unit."
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

/// Offers the intents to Siri without the user wiring up a Shortcut first.
struct BidyutShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckBalanceIntent(),
            phrases: [
                "What is my \(.applicationName) balance",
                "Check my meter balance in \(.applicationName)",
                "How much electricity balance do I have in \(.applicationName)"
            ],
            shortTitle: "Meter balance",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: ApplianceCostIntent(),
            phrases: [
                "How much does it cost to run something in \(.applicationName)"
            ],
            shortTitle: "Running cost",
            systemImageName: "powerplug.fill"
        )
    }
}
