import XCTest
import SwiftData
@testable import Bidyut

/// The audit has to stay quiet on a correct bill and speak up on a wrong one.
/// A false alarm sends someone to argue a case that does not exist, so the
/// clean-bill tests matter as much as the discrepancy ones.
final class BillAuditorTests: XCTestCase {

    private func makeMeter() throws -> (Meter, ModelContext) {
        let schema = Schema([Meter.self, BalanceSnapshot.self, Recharge.self, MonthlyUsage.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let meter = Meter(customerNumber: "12345678", nickname: "Home")
        meter.sanctionedLoad = "2.00"
        context.insert(meter)
        return (meter, context)
    }

    /// October exactly as NESCO billed it: every line should pass.
    private func octoberAsBilled(meter: Meter) -> MonthlyUsage {
        MonthlyUsage(
            key: "oct",
            month: "2026-10",
            unit: 419.039,
            electricityTaka: 3_614.77,
            totalRecharge: 3_790,
            rebate: -17.76,
            meterRent: 40,
            demandCharge: 84,
            pfc: 0,
            arrears: 0,
            vat: 180.48,
            totalDeducted: 3_919.25,
            endBalance: 127.9,
            meter: meter
        )
    }

    func testARealBillPassesCleanly() throws {
        let (meter, context) = try makeMeter()
        context.insert(octoberAsBilled(meter: meter))

        let audit = try XCTUnwrap(BillAuditor.audit(month: octoberAsBilled(meter: meter), sanctionedKW: 2))
        XCTAssertTrue(audit.isClean, "October matched to a paisa — flagging it would be a false alarm: \(audit.findings)")
    }

    func testCatchesAnInflatedEnergyCharge() throws {
        let (meter, _) = try makeMeter()
        let usage = octoberAsBilled(meter: meter)
        usage.electricityTaka = 3_900   // ৳285 more than the tariff gives

        let audit = try XCTUnwrap(BillAuditor.audit(month: usage, sanctionedKW: 2))
        let finding = try XCTUnwrap(audit.findings.first { $0.kind == .energyCharge })

        XCTAssertTrue(finding.overcharged)
        XCTAssertEqual(finding.expected, 3_614.78, accuracy: 0.05)
        XCTAssertEqual(finding.difference, 285.22, accuracy: 0.1)
    }

    func testCatchesAWrongDemandCharge() throws {
        let (meter, _) = try makeMeter()
        let usage = octoberAsBilled(meter: meter)
        usage.demandCharge = 126        // billed for 3 kW on a 2 kW connection

        let audit = try XCTUnwrap(BillAuditor.audit(month: usage, sanctionedKW: 2))
        let finding = try XCTUnwrap(audit.findings.first { $0.kind == .demandCharge })

        XCTAssertEqual(finding.expected, 84)
        XCTAssertEqual(finding.difference, 42, accuracy: 0.01)
    }

    func testRoundingDoesNotTripTheAudit() throws {
        let (meter, _) = try makeMeter()
        let usage = octoberAsBilled(meter: meter)
        usage.electricityTaka = 3_616.50   // under two taka out

        let audit = try XCTUnwrap(BillAuditor.audit(month: usage, sanctionedKW: 2))
        XCTAssertTrue(audit.isClean, "A couple of taka is rounding, not an error")
    }

    func testSkipsDemandChargeWhenLoadIsUnknown() throws {
        let (meter, _) = try makeMeter()
        let usage = octoberAsBilled(meter: meter)
        usage.demandCharge = 999

        // With no sanctioned load there is nothing to compare against, and
        // guessing would manufacture a finding.
        let audit = try XCTUnwrap(BillAuditor.audit(month: usage, sanctionedKW: 0))
        XCTAssertNil(audit.findings.first { $0.kind == .demandCharge })
    }

    func testToleranceScalesWithTheFigure() {
        XCTAssertEqual(BillAuditor.tolerance(for: 100), 5)      // floor
        XCTAssertEqual(BillAuditor.tolerance(for: 3_614.77), 36.1477, accuracy: 0.01)
    }
}

/// Only a change big enough to act on should surface.
final class AnomalyDetectorTests: XCTestCase {

    private func interval(daysAgo: Double, length: Double, consumed: Double) -> ConsumptionAnalytics.Interval {
        let end = Date().addingTimeInterval(-daysAgo * 86_400)
        return ConsumptionAnalytics.Interval(
            start: end.addingTimeInterval(-length * 86_400),
            end: end,
            consumed: consumed
        )
    }

    func testThresholdIsHighEnoughToIgnoreOrdinaryVariation() {
        // Household usage swings well over ten per cent day to day; a lower bar
        // would fire constantly and be learned as noise.
        XCTAssertGreaterThanOrEqual(AnomalyDetector.threshold, 25)
    }

    func testIntervalArithmeticUnderpinsTheComparison() {
        // 3 days at 100/day against 3 days at 200/day is a doubling.
        let recent = interval(daysAgo: 1, length: 3, consumed: 600)
        let baseline = interval(daysAgo: 9, length: 3, consumed: 300)

        XCTAssertEqual(recent.dailyBurn ?? 0, 200, accuracy: 0.01)
        XCTAssertEqual(baseline.dailyBurn ?? 0, 100, accuracy: 0.01)

        let change = ((recent.dailyBurn! - baseline.dailyBurn!) / baseline.dailyBurn!) * 100
        XCTAssertGreaterThan(change, AnomalyDetector.threshold)
    }

    func testAnomalyMessageNamesBothRates() {
        let anomaly = AnomalyDetector.Anomaly(
            kind: .surge(percent: 42),
            recentDailyBurn: 166,
            baselineDailyBurn: 117,
            observedDays: 5
        )
        XCTAssertTrue(anomaly.isSurge)
        XCTAssertTrue(anomaly.message.contains("166") || anomaly.message.contains("১৬৬"))
    }
}
