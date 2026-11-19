import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct BidyutApp: App {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let refreshTaskID = "com.codeyo.bidyut.refresh"

    private let container: ModelContainer

    init() {
        do {
            container = try Self.makeContainer()
        } catch {
            fatalError("Could not open the local store: \(error)")
        }
        registerBackgroundRefresh()
    }

    /// The schema, in one place, so every entry point opens the same store.
    static var schema: Schema {
        Schema([Meter.self, BalanceSnapshot.self, Recharge.self, MonthlyUsage.self])
    }

    /// Opens the store, App Group or not.
    ///
    /// The App Group is where the database belongs: it is what lets the widget
    /// and the Live Activity read it. But a free Apple ID cannot sign the App
    /// Groups entitlement, so a personal-team build has no group container and
    /// asking for one would crash the app on launch. Falling back to the app's
    /// own sandbox keeps everything but the extensions working — the right
    /// trade for someone who just wants the app on their phone.
    ///
    /// Siri runs in its own process and calls this too, so both get the same
    /// answer and never end up reading different databases.
    static func makeContainer() throws -> ModelContainer {
        let schema = Self.schema

        if SharedStore.hasAppGroup,
           let shared = try? ModelContainer(
               for: schema,
               configurations: ModelConfiguration(
                   schema: schema,
                   groupContainer: .identifier(SharedStore.appGroupID)
               )
           ) {
            return shared
        }

        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await Self.handleBackgroundRefresh(container: container)
        }
    }

    // MARK: - Background refresh

    private func registerBackgroundRefresh() {
        Self.scheduleNextRefresh()
    }

    /// iOS decides when this actually runs; asking for four hours is a hint, not
    /// a schedule. The forecast tolerates gaps because it works from elapsed
    /// time between readings rather than assuming a fixed cadence.
    static func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3_600)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func handleBackgroundRefresh(container: ModelContainer) async {
        scheduleNextRefresh()

        let context = container.mainContext
        let descriptor = FetchDescriptor<Meter>()
        guard let meters = try? context.fetch(descriptor), !meters.isEmpty else { return }

        let service = SyncService(context: context)
        _ = await service.syncAll(meters: meters)

        for meter in meters {
            let summary = ConsumptionAnalytics.summarize(meter: meter)
            await NotificationService.refreshAlerts(for: meter, summary: summary)
        }
    }
}

/// Shows the dashboard once a meter exists, and onboarding before that.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Meter.createdAt) private var meters: [Meter]

    var body: some View {
        Group {
            if meters.isEmpty {
                AddMeterView(isOnboarding: true)
            } else {
                DashboardView()
            }
        }
        .tint(Theme.accent)
    }
}
