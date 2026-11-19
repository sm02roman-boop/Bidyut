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
        // No background-refresh request here. SwiftUI registers the handler
        // for `refreshTaskID` through `.backgroundTask` once the scene exists,
        // which is after `init`. Submitting a request before its handler is
        // registered trips an assertion in BGTaskScheduler and kills the app
        // on launch, so the request is made when the app goes to the
        // background instead — see `RootView`.
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

    /// iOS decides when this actually runs; asking for four hours is a hint, not
    /// a schedule. The forecast tolerates gaps because it works from elapsed
    /// time between readings rather than assuming a fixed cadence.
    ///
    /// Only call this once the scene is up. Before then there is no registered
    /// handler and the scheduler asserts.
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
    @Environment(\.scenePhase) private var scenePhase
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
        // Ask for the next background refresh as the app leaves the screen. By
        // now `.backgroundTask` has registered the handler, so the scheduler
        // accepts the request.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BidyutApp.scheduleNextRefresh()
            }
        }
    }
}
