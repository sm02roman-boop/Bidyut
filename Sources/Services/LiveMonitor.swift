import Foundation
import SwiftUI
import SwiftData

/// Keeps the balance fresh while the app is open.
///
/// There is nothing to subscribe to: the portal has no push, no websocket and no
/// live reading, so "live" here means polling it on a timer and watching the
/// balance step down. The meter's own balance only moves every so often, so
/// polling faster than `interval` would return the same number and add nothing
/// but load on a government server.
@MainActor
@Observable
final class LiveMonitor {

    /// How often to re-read the portal while the app is in the foreground.
    static let interval: TimeInterval = 15 * 60

    private(set) var isPolling = false
    private(set) var lastCheckedAt: Date?
    private(set) var lastError: String?

    /// Balance movement seen since this monitor started watching.
    private(set) var observedDrop: Double?
    private var baselineBalance: Double?
    private var baselineAt: Date?

    private var task: Task<Void, Never>?

    func start(meter: Meter, context: ModelContextBox) {
        stop()
        baselineBalance = meter.currentBalance
        baselineAt = Date()
        observedDrop = nil

        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(meter: meter, context: context)
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isPolling = false
    }

    /// Rate of fall measured within this session, in taka per day.
    ///
    /// It needs a real drop over a real stretch of time to mean anything, so it
    /// stays nil until both are present.
    var sessionBurnPerDay: Double? {
        guard let observedDrop, observedDrop > 0,
              let baselineAt
        else { return nil }

        let days = Date().timeIntervalSince(baselineAt) / 86_400
        guard days > 0.02 else { return nil }
        return observedDrop / days
    }

    private func poll(meter: Meter, context: ModelContextBox) async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        do {
            let service = SyncService(context: context.context)
            try await service.sync(meter: meter)
            lastCheckedAt = Date()
            lastError = nil

            if let baseline = baselineBalance, let current = meter.currentBalance {
                let drop = baseline - current
                // A recharge raises the balance; that is not consumption, so the
                // baseline moves up instead of recording a negative drop.
                if drop < 0 {
                    baselineBalance = current
                    baselineAt = Date()
                    observedDrop = nil
                } else {
                    observedDrop = drop
                }
            } else {
                baselineBalance = meter.currentBalance
                baselineAt = Date()
            }
        } catch {
            lastError = (error as? NescoError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Carries a `ModelContext` into the monitor without making it `Sendable`.
@MainActor
struct ModelContextBox {
    let context: ModelContext
}
