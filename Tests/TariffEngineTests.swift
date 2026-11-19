import XCTest
@testable import Bidyut

/// The tariff engine is pinned to this meter's own statements.
///
/// If a future BERC revision changes the slabs, these tests fail — which is the
/// point: a silently wrong bill projection is worse than no projection.
final class TariffEngineTests: XCTestCase {

    func testReproducesTheOctoberBillExactly() {
        // 419.039 units → NESCO billed ৳3,614.77
        let computed = TariffEngine.energyCharge(forUnits: 419.039)
        XCTAssertEqual(computed, 3_614.77, accuracy: 0.02)
    }

    func testReproducesTheSeptemberBillExactly() {
        // 391.039 units → NESCO billed ৳3,242.80
        let computed = TariffEngine.energyCharge(forUnits: 391.039)
        XCTAssertEqual(computed, 3_242.80, accuracy: 0.02)
    }

    func testLifelineIsFlatNotProgressive() {
        // At or below 50 units every unit is at the lifeline rate, so this is
        // NOT 50 × 5.26.
        XCTAssertEqual(TariffEngine.energyCharge(forUnits: 50), 50 * 4.63, accuracy: 0.01)
        XCTAssertEqual(TariffEngine.energyCharge(forUnits: 30), 30 * 4.63, accuracy: 0.01)

        // Just past the threshold the progressive slabs take over, which makes
        // the bill jump — a real feature of the tariff, not a bug here.
        XCTAssertEqual(TariffEngine.energyCharge(forUnits: 51), 51 * 5.26, accuracy: 0.01)
    }

    func testSlabBoundariesPriceTheNextUnitCorrectly() {
        XCTAssertEqual(TariffEngine.marginalRate(atUnits: 40), 4.63)
        XCTAssertEqual(TariffEngine.marginalRate(atUnits: 74), 5.26)
        XCTAssertEqual(TariffEngine.marginalRate(atUnits: 120), 8.50)
        XCTAssertEqual(TariffEngine.marginalRate(atUnits: 250), 9.10)
        XCTAssertEqual(TariffEngine.marginalRate(atUnits: 399), 9.62)
        XCTAssertEqual(TariffEngine.marginalRate(atUnits: 401), 15.01)
        XCTAssertEqual(TariffEngine.marginalRate(atUnits: 650), 17.35)
    }

    func testTheFourHundredUnitCliff() {
        let warning = try? XCTUnwrap(TariffEngine.cliffWarning(atUnits: 419.039))

        XCTAssertEqual(warning?.boundary, 400)
        XCTAssertEqual(warning?.unitsOver ?? 0, 19.039, accuracy: 0.001)
        XCTAssertEqual(warning?.previousRate, 9.62)
        XCTAssertEqual(warning?.currentRate, 15.01)
        // 19.039 × (15.01 − 9.62)
        XCTAssertEqual(warning?.extraCost ?? 0, 102.62, accuracy: 0.02)
        // The step is more than half again.
        XCTAssertGreaterThan(warning?.rateJump ?? 0, 0.5)
    }

    func testHoldingToFourHundredUnitsSaysWhatItSaves() {
        let over = TariffEngine.energyCharge(forUnits: 419.039)
        let under = TariffEngine.energyCharge(forUnits: 400)
        XCTAssertEqual(over - under, 285.78, accuracy: 0.02)
    }

    func testNoCliffBelowTheFirstBoundary() {
        XCTAssertNil(TariffEngine.cliffWarning(atUnits: 40))
        XCTAssertNil(TariffEngine.cliffWarning(atUnits: 70))
    }

    func testUnitsAffordableInvertsTheCharge() {
        for units in [75.5, 300.0, 419.039, 620.0] {
            let cost = TariffEngine.energyCharge(forUnits: units)
            let back = TariffEngine.unitsAffordable(taka: cost)
            XCTAssertEqual(back, units, accuracy: 0.001, "round trip failed at \(units)")
        }
    }

    func testUnitsAffordableRespectsWhereTheMonthAlreadyIs() {
        // The same money buys fewer units late in the month, because those units
        // are billed in a dearer band.
        let early = TariffEngine.unitsAffordable(taka: 500, startingAtUnits: 100)
        let late = TariffEngine.unitsAffordable(taka: 500, startingAtUnits: 420)
        XCTAssertGreaterThan(early, late)
        XCTAssertEqual(late, 500 / 15.01, accuracy: 0.01)
    }

    func testMonthlyBillAddsTheFixedCharges() {
        let bill = TariffEngine.monthlyBill(
            units: 419.039,
            sanctionedLoadKW: 2,
            meterRent: 40,
            rechargedThisMonth: 3_790
        )

        XCTAssertEqual(bill.demandCharge, 84)      // 42 × 2 kW, as NESCO billed
        XCTAssertEqual(bill.meterRent, 40)
        XCTAssertEqual(bill.rebate, 18.95, accuracy: 0.01)   // 0.5% of 3,790
        XCTAssertEqual(bill.vat, 180.74, accuracy: 0.05)     // 5% of the energy charge
        XCTAssertGreaterThan(bill.total, bill.energyCharge)
    }

    func testRunningCostUsesTheMarginalRate() {
        // A 1.2 kW air conditioner for 8 hours is 9.6 units.
        let cheap = TariffEngine.costOfRunning(watts: 1_200, hours: 8, monthToDateUnits: 100)
        let dear = TariffEngine.costOfRunning(watts: 1_200, hours: 8, monthToDateUnits: 450)

        XCTAssertEqual(cheap.units, 9.6, accuracy: 0.001)
        XCTAssertEqual(cheap.taka, 9.6 * 8.50, accuracy: 0.01)
        XCTAssertEqual(dear.taka, 9.6 * 15.01, accuracy: 0.01)
        // The same eight hours costs well over half again late in the month.
        XCTAssertGreaterThan(dear.taka / cheap.taka, 1.5)
    }
}

/// Friendly Hour arithmetic. NESCO runs it 4pm–11am daily, with Friday,
/// Saturday and public holidays protected around the clock, so the only window
/// in which a meter can disconnect is 11am–4pm, Sunday to Thursday.
final class SupplyPredictorTests: XCTestCase {

    private var calendar: Calendar { .dhaka }

    private func dhaka(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testCutoffWindowIsOnlyWeekdayMidday() {
        // Monday 1pm — the meter can disconnect.
        XCTAssertEqual(SupplyPredictor.state(at: dhaka("2026-11-16T13:00:00+06:00")), .cutoffWindow)
        // Monday 5pm — Friendly Hour.
        XCTAssertEqual(SupplyPredictor.state(at: dhaka("2026-11-16T17:00:00+06:00")), .friendlyHour)
        // Monday 9am — still Friendly Hour, which runs to 11am.
        XCTAssertEqual(SupplyPredictor.state(at: dhaka("2026-11-16T09:00:00+06:00")), .friendlyHour)
        // Friday 1pm — holiday, protected all day.
        XCTAssertEqual(SupplyPredictor.state(at: dhaka("2026-11-20T13:00:00+06:00")), .holiday)
        // Saturday 1pm — holiday too.
        XCTAssertEqual(SupplyPredictor.state(at: dhaka("2026-11-21T13:00:00+06:00")), .holiday)
    }

    func testWeekendZeroWaitsUntilSundayMorning() {
        // Running out Friday afternoon should not threaten supply until Sunday
        // at 11am — the first cut-off window after the weekend.
        let friday = dhaka("2026-11-20T14:00:00+06:00")
        let cutoff = SupplyPredictor.nextCutoffMoment(onOrAfter: friday, calendar: calendar)

        XCTAssertEqual(calendar.component(.weekday, from: cutoff), 1) // Sunday
        XCTAssertEqual(calendar.component(.hour, from: cutoff), 11)
        XCTAssertGreaterThan(cutoff.timeIntervalSince(friday), 40 * 3_600)
    }

    func testEveningZeroWaitsUntilNextMorning() {
        let monday = dhaka("2026-11-16T20:00:00+06:00")
        let cutoff = SupplyPredictor.nextCutoffMoment(onOrAfter: monday, calendar: calendar)

        XCTAssertEqual(calendar.component(.hour, from: cutoff), 11)
        // Tuesday, not the same evening.
        XCTAssertEqual(calendar.component(.weekday, from: cutoff), 3)
    }

    func testMiddayZeroHasNoGrace() {
        let noon = dhaka("2026-11-16T12:00:00+06:00")
        XCTAssertEqual(SupplyPredictor.nextCutoffMoment(onOrAfter: noon, calendar: calendar), noon)
    }

    func testPredictionAccruesDebtDuringGrace() {
        // Zero reached Friday afternoon at ৳117 a day: roughly two days of
        // protected supply, booked as negative balance.
        let friday = dhaka("2026-11-20T14:00:00+06:00")
        let prediction = try? XCTUnwrap(
            SupplyPredictor.predict(balance: 0, dailyBurn: 117, from: friday, calendar: calendar)
        )

        XCTAssertTrue(prediction?.hasGrace ?? false)
        XCTAssertGreaterThan(prediction?.graceHours ?? 0, 40)
        XCTAssertGreaterThan(prediction?.accruedDebt ?? 0, 150)
    }

    func testNoPredictionWithoutABurnRate() {
        XCTAssertNil(SupplyPredictor.predict(balance: 230, dailyBurn: 0))
    }

    func testEmergencyCreditByPhase() {
        XCTAssertEqual(SupplyPredictor.emergencyCredit(meterType: "1P Keypad"), 200)
        XCTAssertEqual(SupplyPredictor.emergencyCredit(meterType: "3P Smart"), 500)
        XCTAssertEqual(SupplyPredictor.emergencyCredit(meterType: nil), 200)
    }
}
