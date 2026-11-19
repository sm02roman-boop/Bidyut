import XCTest
import SwiftData
@testable import Bidyut

/// Taka-to-units conversion, checked against the real October statement for
/// meter 12345678: 419.039 kWh billed at ৳3,614.77.
final class UsageEstimatorTests: XCTestCase {

    private func makeMeter() throws -> (Meter, ModelContext) {
        let schema = Schema([Meter.self, BalanceSnapshot.self, Recharge.self, MonthlyUsage.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let meter = Meter(customerNumber: "12345678", nickname: "Home")
        meter.sanctionedLoad = "2.00"
        context.insert(meter)
        return (meter, context)
    }

    func testEffectiveRateComesFromTheLastClosedMonth() throws {
        let (meter, context) = try makeMeter()
        context.insert(MonthlyUsage(key: "a", month: "2026-09", unit: 391.039, electricityTaka: 3242.80, meter: meter))
        context.insert(MonthlyUsage(key: "b", month: "2026-10", unit: 419.039, electricityTaka: 3614.77, meter: meter))

        let now = ISO8601DateFormatter().date(from: "2026-11-19T15:00:00+06:00")!
        let rate = try XCTUnwrap(UsageEstimator.effectiveRate(meter: meter, now: now))

        XCTAssertEqual(rate.month, "2026-10")
        XCTAssertEqual(rate.value, 8.626, accuracy: 0.002)
    }

    func testDerivesUnitsAndWattsFromTheDailyBurn() throws {
        let (meter, context) = try makeMeter()
        context.insert(MonthlyUsage(key: "b", month: "2026-10", unit: 419.039, electricityTaka: 3614.77, meter: meter))

        var summary = ConsumptionAnalytics.Summary()
        summary.dailyBurn = 116.60
        summary.currentBalance = 229.97

        let now = ISO8601DateFormatter().date(from: "2026-11-19T15:00:00+06:00")!
        let estimate = UsageEstimator.estimate(meter: meter, summary: summary, now: now)

        // 116.60 / 8.626
        XCTAssertEqual(try XCTUnwrap(estimate.unitsPerDay), 13.52, accuracy: 0.05)
        // 13.52 kWh over 24 hours
        XCTAssertEqual(try XCTUnwrap(estimate.averageWatts), 563, accuracy: 3)
        // 229.97 / 8.626
        XCTAssertEqual(try XCTUnwrap(estimate.unitsRemaining), 26.66, accuracy: 0.05)
        // 563 W against a 2 kW sanctioned load
        XCTAssertEqual(try XCTUnwrap(estimate.loadFraction), 0.28, accuracy: 0.01)
    }

    func testRejectsAnImplausibleRate() throws {
        let (meter, context) = try makeMeter()
        // A month with almost no units would divide into an absurd rate.
        context.insert(MonthlyUsage(key: "c", month: "2026-10", unit: 0.01, electricityTaka: 3614.77, meter: meter))

        let now = ISO8601DateFormatter().date(from: "2026-11-19T15:00:00+06:00")!
        XCTAssertNil(UsageEstimator.effectiveRate(meter: meter, now: now))
    }

    func testNoRateWithoutData() throws {
        let (meter, _) = try makeMeter()
        let now = Date()
        XCTAssertNil(UsageEstimator.effectiveRate(meter: meter, now: now))
        XCTAssertNil(UsageEstimator.estimate(meter: meter, summary: .init(), now: now).averageWatts)
    }
}

/// The parser is the fragile part of this app — it reads HTML NESCO can change
/// without notice — so it is the part worth testing. These fixtures mirror the
/// portal's real markup shape.
final class NescoParserTests: XCTestCase {

    func testExtractsCSRFTokenFromMetaTag() {
        let html = #"<meta name="csrf-token" content="AbC123token">"#
        XCTAssertEqual(NescoParser.csrfToken(in: html), "AbC123token")
    }

    func testExtractsCSRFTokenFromHiddenInput() {
        let html = #"<input type="hidden" name="_token" value="XyZ789">"#
        XCTAssertEqual(NescoParser.csrfToken(in: html), "XyZ789")
    }

    func testParsesCustomerInfoPositionally() {
        let html = """
        <div id="con_info_div">
          <input value="MD RAKIBUL ISLAM">
          <input value="ABDUL KARIM">
          <input value="HOUSE 12, ROAD 3, RAJSHAHI">
          <input value="01712345678">
          <input value="S&amp;D RAJSHAHI">
          <input value="FEEDER-7">
          <input value="87654321">
          <input value="05035014311">
          <input value="4.00">
          <input value="LT-A">
          <input value="1P Keypad">
          <input value="Active">
          <input value="12/03/2022">
          <input value="100">
          <input value="842.50">
        </div>
        <div>consumerRechargeData</div>
        """

        let info = NescoParser.parseCustomerInfo(from: html)

        XCTAssertEqual(info.name, "MD RAKIBUL ISLAM")
        XCTAssertEqual(info.consumerNo, "87654321")
        XCTAssertEqual(info.meterNo, "05035014311")
        XCTAssertEqual(info.tariff, "LT-A")
        XCTAssertEqual(info.balance, 842.50)
        XCTAssertEqual(info.minimumRecharge, 100)
    }

    func testParsesRechargeRowAttributes() {
        let html = """
        <tr data-order="1" data-token="12345678901234567890" data-seq="7"
            data-rent="40" data-demandcharge="42" data-tax="47.62" data-pfc="0"
            data-subsidyamount="0" data-purchaseamount="870.38" data-totalamount="1000"
            data-purchaseenergy="112.5" data-salename="bKash"
            data-purchasedate="04/11/2026" data-meterno="05035014311"
            data-customerno="87654321" data-customername="MD RAKIBUL ISLAM"
            data-tariff="LT-A">
          <td>1</td><td>Success</td>
        </tr>
        """

        let recharges = NescoParser.parseRecharges(from: html)
        XCTAssertEqual(recharges.count, 1)

        let recharge = try? XCTUnwrap(recharges.first)
        XCTAssertEqual(recharge?.totalAmount, 1000)
        XCTAssertEqual(recharge?.electricityAmount, 870.38)
        XCTAssertEqual(recharge?.energyUnit, 112.5)
        XCTAssertEqual(recharge?.meterRent, 40)
        XCTAssertEqual(recharge?.demandCharge, 42)
        XCTAssertEqual(recharge?.vat, 47.62)
        XCTAssertEqual(recharge?.method, "bKash")
        XCTAssertEqual(recharge?.status, "Success")

        // 40 + 42 + 47.62 + 0
        XCTAssertEqual(recharge?.totalDeductions ?? 0, 129.62, accuracy: 0.01)
    }

    func testStripsThousandsSeparators() {
        XCTAssertEqual(NescoParser.number("1,234.56"), 1234.56)
        XCTAssertEqual(NescoParser.number("৳ 980"), 980)
        XCTAssertEqual(NescoParser.number("-45.5"), -45.5)
        XCTAssertNil(NescoParser.number("—"))
        XCTAssertNil(NescoParser.number(""))
    }

    func testDetectsAccountNotFound() {
        XCTAssertTrue(NescoParser.looksLikeAccountNotFound("<p>কোনো তথ্য পাওয়া যায়নি</p>"))
        XCTAssertTrue(NescoParser.looksLikeAccountNotFound("<p>No customer found</p>"))
        XCTAssertFalse(NescoParser.looksLikeAccountNotFound("<p>MD RAKIBUL ISLAM</p>"))
    }

    /// The portal's real recharge format: upper-cased month, single-digit hour.
    /// Getting this wrong silently drops every recharge, so it is pinned here.
    func testParsesPortalRechargeDateFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka")!

        let afternoon = NescoParser.parseDate("08-NOV-2026 12:59 PM")
        XCTAssertNotNil(afternoon)
        let a = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: afternoon!)
        XCTAssertEqual(a.year, 2026)
        XCTAssertEqual(a.month, 11)
        XCTAssertEqual(a.day, 8)
        XCTAssertEqual(a.hour, 12)
        XCTAssertEqual(a.minute, 59)

        let singleDigitHour = NescoParser.parseDate("03-NOV-2026 2:22 PM")
        XCTAssertNotNil(singleDigitHour)
        XCTAssertEqual(calendar.component(.hour, from: singleDigitHour!), 14)

        XCTAssertNotNil(NescoParser.parseDate("29-OCT-2026 9:22 PM"))
        XCTAssertNotNil(NescoParser.parseDate("04/11/2026"))
    }

    /// The monthly table has several columns ending in "(টাকা)", so matching that
    /// word alone picks the recharge column instead of the consumption one.
    func testMonthlyUsagePicksTheRightTakaColumn() {
        let html = """
        <table class="bfont_post">
          <thead><tr>
            <th>বছর</th><th>মাস</th><th>সর্বমোট রিচার্জ (টাকা)</th><th>রেয়াত (টাকা)</th>
            <th>ব্যবহৃত বিদ্যুৎ (টাকা)</th><th>মিটার রেন্ট (টাকা)</th><th>ডিমান্ড চার্জ (টাকা)</th>
            <th>পিএফসি চার্জ (টাকা)</th><th>পরিশোধিত বকেয়া/জরিমানা (টাকা)</th><th>ভ্যাট (টাকা)</th>
            <th>সর্বমোট ব্যবহার/কর্তন (টাকা)</th><th>মাস শেষে মিটার ব্যালেন্স (টাকা)</th>
            <th>ব্যবহৃত বিদ্যুৎ (কি.ও.আ.)</th>
          </tr></thead>
          <tbody><tr>
            <td>2026</td><td>October</td><td>3790</td><td>-17.76</td><td>3614.77</td>
            <td>40</td><td>84</td><td>0</td><td>0</td><td>180.48</td>
            <td>3919.25</td><td>127.9</td><td>419.039</td>
          </tr></tbody>
        </table>
        """

        let rows = NescoParser.parseMonthlyUsage(from: html)
        XCTAssertEqual(rows.count, 1)

        let row = rows[0]
        XCTAssertEqual(row.month, "2026-10")
        XCTAssertEqual(row.unit, 419.039)
        // Consumption, not the 3790 recharge total.
        XCTAssertEqual(row.electricityTaka, 3614.77)
        XCTAssertEqual(row.totalRecharge, 3790)
        XCTAssertEqual(row.meterRent, 40)
        XCTAssertEqual(row.demandCharge, 84)
        XCTAssertEqual(row.vat, 180.48)
        XCTAssertEqual(row.endBalance, 127.9)
        // 40 + 84 + 0 + 180.48
        XCTAssertEqual(row.fixedCharges ?? 0, 304.48, accuracy: 0.01)
    }

    /// The portal encodes য় as U+09DF while a Swift source literal normally
    /// carries the decomposed য + nukta. They render identically and compare
    /// unequal, which silently broke the rebate column and the not-found check.
    func testMatchesBengaliAcrossBothEncodings() {
        let precomposed = "\u{09B0}\u{09C7}\u{09DF}\u{09BE}\u{09A4} (টাকা)"          // রেয়াত
        let decomposed = "\u{09B0}\u{09C7}\u{09AF}\u{09BC}\u{09BE}\u{09A4} (টাকা)"   // রেয়াত

        XCTAssertNotEqual(precomposed, decomposed, "Fixture should hold the two encodings")
        XCTAssertTrue(NescoParser.matches(precomposed, "রেয়াত|rebate"))
        XCTAssertTrue(NescoParser.matches(decomposed, "রেয়াত|rebate"))
        XCTAssertEqual(NescoParser.canonical(precomposed), NescoParser.canonical(decomposed))
    }

    func testResolvesRebateColumnWithPrecomposedHeader() {
        let rebateHeader = "\u{09B0}\u{09C7}\u{09DF}\u{09BE}\u{09A4} (টাকা)"
        let html = """
        <table><thead><tr><th>বছর</th><th>মাস</th><th>\(rebateHeader)</th>
        <th>ব্যবহৃত বিদ্যুৎ (টাকা)</th><th>ব্যবহৃত বিদ্যুৎ (কি.ও.আ.)</th></tr></thead>
        <tbody><tr><td>2026</td><td>October</td><td>-17.76</td><td>3614.77</td><td>419.039</td></tr></tbody></table>
        """

        let rows = NescoParser.parseMonthlyUsage(from: html)
        XCTAssertEqual(rows.first?.rebate, -17.76)
        XCTAssertEqual(rows.first?.electricityTaka, 3614.77)
    }

    func testStatusComesFromTheRowsLastCell() {
        // The portal puts the data attributes on an <a> nested in the third cell,
        // so the status is read by scanning forward to the end of the row.
        let html = """
        <tr><td>1</td><td></td><td>
          <a class="consumerRechargeData" data-totalamount="500" data-purchaseamount="354.36"
             data-token="1234567890123456" data-purchasedate="03-NOV-2026 2:22 PM"
             data-salename="NAGAD" data-rent="40" data-demandcharge="84" data-tax="23.81">view</a>
        </td><td>0</td><td>73.36</td><td>NAGAD</td><td>03-NOV-2026 2:22 PM</td><td>Success</td></tr>
        """

        let recharges = NescoParser.parseRecharges(from: html)
        XCTAssertEqual(recharges.count, 1)
        XCTAssertEqual(recharges.first?.status, "Success")
        XCTAssertTrue(recharges.first?.totalAmount == 500)
    }

    func testMonthlyUsageHandlesNegativeClosingBalance() {
        let html = """
        <table><thead><tr><th>বছর</th><th>মাস</th><th>মাস শেষে মিটার ব্যালেন্স (টাকা)</th>
        <th>ব্যবহৃত বিদ্যুৎ (কি.ও.আ.)</th></tr></thead>
        <tbody><tr><td>2026</td><td>May</td><td>-36.37</td><td>330.78</td></tr></tbody></table>
        """

        let rows = NescoParser.parseMonthlyUsage(from: html)
        XCTAssertEqual(rows.first?.endBalance, -36.37)
    }
}

/// The forecast is the app's main claim, so the arithmetic behind it is tested
/// directly rather than trusted.
final class ConsumptionAnalyticsTests: XCTestCase {

    private func snapshot(_ daysAgo: Double, _ balance: Double) -> BalanceSnapshot {
        BalanceSnapshot(capturedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400), balance: balance)
    }

    func testBurnRateFromPlainDecline() {
        // 1000 → 800 over 4 days with no recharge is 50 Tk a day.
        let snapshots = [snapshot(4, 1000), snapshot(0, 800)]
        let intervals = ConsumptionAnalytics.buildIntervals(snapshots: snapshots, recharges: [])

        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].consumed, 200, accuracy: 0.01)
        XCTAssertEqual(intervals[0].dailyBurn ?? 0, 50, accuracy: 0.5)
    }

    func testRechargeIsAddedBackBeforeMeasuringUse() {
        // Balance rose from 200 to 900, but 1000 was credited in between, so the
        // meter actually consumed 300.
        let recharge = Recharge(
            key: "k",
            token: "t",
            date: Date(timeIntervalSinceNow: -2 * 86_400),
            totalAmount: 1150,
            electricityAmount: 1000
        )
        let snapshots = [snapshot(4, 200), snapshot(0, 900)]
        let intervals = ConsumptionAnalytics.buildIntervals(snapshots: snapshots, recharges: [recharge])

        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].consumed, 300, accuracy: 0.01)
    }

    func testImpossibleIntervalsAreDiscarded() {
        // Balance rose with no recharge recorded: the reading cannot be trusted,
        // so it must not drag the average down.
        let snapshots = [snapshot(4, 200), snapshot(0, 900)]
        let intervals = ConsumptionAnalytics.buildIntervals(snapshots: snapshots, recharges: [])
        XCTAssertTrue(intervals.isEmpty)
    }

    func testRecentIntervalsWeighMoreThanOldOnes() {
        let now = Date()
        let old = ConsumptionAnalytics.Interval(
            start: now.addingTimeInterval(-60 * 86_400),
            end: now.addingTimeInterval(-56 * 86_400),
            consumed: 400 // 100/day, long ago
        )
        let recent = ConsumptionAnalytics.Interval(
            start: now.addingTimeInterval(-4 * 86_400),
            end: now,
            consumed: 200 // 50/day, now
        )

        let burn = ConsumptionAnalytics.weightedDailyBurn(from: [old, recent], now: now)
        XCTAssertNotNil(burn)
        // Should sit much closer to the recent 50 than the midpoint of 75.
        XCTAssertLessThan(burn!, 60)
    }

    func testSuggestedRechargeCoversFixedCharges() {
        var summary = ConsumptionAnalytics.Summary()
        summary.currentBalance = 100
        summary.dailyBurn = 50
        summary.averageFixedCharges = 130

        // 50 × 30 = 1500, less 100 held, plus 130 charges = 1530 → rounds to 1600.
        let suggested = ConsumptionAnalytics.suggestedRecharge(summary: summary, targetDays: 30)
        XCTAssertEqual(suggested, 1600)
    }

    func testNoForecastWithoutData() {
        var summary = ConsumptionAnalytics.Summary()
        summary.currentBalance = 500
        XCTAssertNil(ConsumptionAnalytics.suggestedRecharge(summary: summary))
        XCTAssertEqual(summary.confidence, .none)
    }
}
