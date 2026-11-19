import Foundation
import SwiftData
import WidgetKit

/// Pulls a meter's state from the portal and folds it into the local store.
///
/// The local history is the point: NESCO keeps no daily record, so each sync
/// appends a balance snapshot and those snapshots are what the analytics
/// differentiate into a burn rate.
@MainActor
final class SyncService {

    private let client: NescoClient
    private let context: ModelContext

    init(context: ModelContext, client: NescoClient = NescoClient()) {
        self.context = context
        self.client = client
    }

    enum SyncOutcome {
        case updated(balance: Double?)
        case unchanged
    }

    @discardableResult
    func sync(meter: Meter) async throws -> SyncOutcome {
        let snapshot = try await client.fetchSnapshot(customerNumber: meter.customerNumber)
        return apply(snapshot, to: meter)
    }

    /// Syncs every meter, returning the errors rather than throwing, so one dead
    /// meter does not abort the rest.
    func syncAll(meters: [Meter]) async -> [(Meter, Error)] {
        var failures: [(Meter, Error)] = []
        for meter in meters {
            do {
                try await sync(meter: meter)
            } catch {
                failures.append((meter, error))
            }
        }
        return failures
    }

    // MARK: - Folding a snapshot into the store

    @discardableResult
    func apply(_ snapshot: NescoSnapshot, to meter: Meter) -> SyncOutcome {
        let info = snapshot.info

        meter.customerName = info.name ?? meter.customerName
        meter.meterNumber = info.meterNo ?? meter.meterNumber
        meter.address = info.address ?? meter.address
        meter.tariff = info.tariff ?? meter.tariff
        meter.office = info.office ?? meter.office
        meter.feeder = info.feeder ?? meter.feeder
        meter.sanctionedLoad = info.sanctionedLoad ?? meter.sanctionedLoad
        meter.minimumRecharge = info.minimumRecharge ?? meter.minimumRecharge
        meter.meterType = info.meterType ?? meter.meterType
        meter.lastSyncedAt = snapshot.fetchedAt

        mergeRecharges(snapshot.recharges, into: meter)
        mergeMonthly(snapshot.monthly, into: meter)

        let outcome = recordBalance(snapshot.balance, on: meter, at: snapshot.fetchedAt)

        try? context.save()
        SharedStore.publish(meter: meter)
        WidgetCenter.shared.reloadAllTimelines()

        // Everything below is about telling the user something, so none of it
        // should hold up the sync returning.
        let summary = ConsumptionAnalytics.summarize(meter: meter)
        Task {
            await RechargeWatcher.reportFailures(in: meter)
            await LiveActivityController.refresh(meter: meter, summary: summary)
        }

        return outcome
    }

    /// Appends a snapshot, but skips one that would add nothing.
    ///
    /// The portal updates a meter's balance only periodically, so polling more
    /// often than it refreshes would otherwise fill the history with identical
    /// readings and flatten the computed burn rate toward zero.
    private func recordBalance(_ balance: Double?, on meter: Meter, at date: Date) -> SyncOutcome {
        guard let balance else { return .unchanged }

        if let latest = meter.latestSnapshot, abs(latest.balance - balance) < 0.01 {
            return .unchanged
        }

        let snapshot = BalanceSnapshot(capturedAt: date, balance: balance, meter: meter)
        context.insert(snapshot)
        return .updated(balance: balance)
    }

    private func mergeRecharges(_ incoming: [NescoRecharge], into meter: Meter) {
        let existing = Set(meter.recharges.map(\.key))

        for row in incoming {
            guard let date = NescoParser.parseDate(row.rechargeDate) else { continue }
            guard let total = row.totalAmount else { continue }

            let key = "\(meter.customerNumber)-\(row.token.isEmpty ? row.rechargeDate : row.token)"
            guard !existing.contains(key) else { continue }

            let recharge = Recharge(
                key: key,
                token: row.token,
                date: date,
                totalAmount: total,
                electricityAmount: row.electricityAmount,
                energyUnit: row.energyUnit,
                meterRent: row.meterRent,
                demandCharge: row.demandCharge,
                vat: row.vat,
                pfc: row.pfc,
                subsidy: row.subsidy,
                method: row.method.isEmpty ? nil : row.method,
                status: row.status.isEmpty ? nil : row.status,
                meter: meter
            )
            context.insert(recharge)
        }
    }

    private func mergeMonthly(_ incoming: [NescoMonthlyUsage], into meter: Meter) {
        let existing = Dictionary(
            meter.monthlyUsage.map { ($0.month, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for row in incoming {
            if let current = existing[row.month] {
                // The current month's figures keep changing until the month ends.
                current.unit = row.unit ?? current.unit
                current.electricityTaka = row.electricityTaka ?? current.electricityTaka
                current.totalRecharge = row.totalRecharge ?? current.totalRecharge
                current.rebate = row.rebate ?? current.rebate
                current.meterRent = row.meterRent ?? current.meterRent
                current.demandCharge = row.demandCharge ?? current.demandCharge
                current.pfc = row.pfc ?? current.pfc
                current.arrears = row.arrears ?? current.arrears
                current.vat = row.vat ?? current.vat
                current.totalDeducted = row.totalDeducted ?? current.totalDeducted
                current.endBalance = row.endBalance ?? current.endBalance
            } else {
                let usage = MonthlyUsage(
                    key: "\(meter.customerNumber)-\(row.month)",
                    month: row.month,
                    unit: row.unit,
                    electricityTaka: row.electricityTaka,
                    totalRecharge: row.totalRecharge,
                    rebate: row.rebate,
                    meterRent: row.meterRent,
                    demandCharge: row.demandCharge,
                    pfc: row.pfc,
                    arrears: row.arrears,
                    vat: row.vat,
                    totalDeducted: row.totalDeducted,
                    endBalance: row.endBalance,
                    meter: meter
                )
                context.insert(usage)
            }
        }

        seedHistoricalSnapshots(for: meter)
    }

    /// Turns each month's closing balance into a balance snapshot.
    ///
    /// This is what lets a freshly added meter show a real trend immediately.
    /// Only months the app has no live reading for are seeded, so a genuine
    /// reading is never displaced by a month-end figure.
    private func seedHistoricalSnapshots(for meter: Meter) {
        let existing = meter.snapshots.map(\.capturedAt)

        for usage in meter.monthlyUsage {
            guard let balance = usage.endBalance, let date = usage.endOfMonth else { continue }
            // Never seed the month in progress: its closing balance is not final.
            guard date < Date() else { continue }
            // One reading per day is enough; skip if something is already close.
            guard !existing.contains(where: { abs($0.timeIntervalSince(date)) < 43_200 }) else { continue }

            context.insert(BalanceSnapshot(capturedAt: date, balance: balance, meter: meter))
        }
    }
}
