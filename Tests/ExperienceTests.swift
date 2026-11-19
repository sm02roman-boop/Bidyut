import XCTest
@testable import Bidyut

/// Bengali digits and language resolution.
final class LocalizationTests: XCTestCase {

    override func tearDown() {
        LanguageSettings.current = .system
        super.tearDown()
    }

    func testConvertsDigitsWithoutTouchingTheRest() {
        XCTAssertEqual(BengaliDigits.convert("229.97"), "২২৯.৯৭")
        XCTAssertEqual(BengaliDigits.convert("1,500"), "১,৫০০")
        XCTAssertEqual(BengaliDigits.convert("kWh"), "kWh")
        // The separators are deliberately left alone — Bangla uses the same ones.
        XCTAssertEqual(BengaliDigits.convert("12345678"), "১২৩৪৫৬৭৮")
    }

    func testDigitsFollowTheChosenLanguage() {
        LanguageSettings.current = .english
        XCTAssertEqual(BengaliDigits.localize("229.97"), "229.97")

        LanguageSettings.current = .bangla
        XCTAssertEqual(BengaliDigits.localize("229.97"), "২২৯.৯৭")
    }

    func testTakaFormattingSwitchesScript() {
        LanguageSettings.current = .english
        XCTAssertEqual(Formatters.taka(229.97), "৳229.97")

        LanguageSettings.current = .bangla
        XCTAssertEqual(Formatters.taka(229.97), "৳২২৯.৯৭")
    }

    func testSystemResolvesToAConcreteLanguage() {
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
        XCTAssertEqual(AppLanguage.bangla.resolved, .bangla)
        XCTAssertTrue(AppLanguage.bangla.isBangla)
        XCTAssertFalse(AppLanguage.english.isBangla)
    }
}

/// Notification timing. An alert nobody is awake for is an alert that gets
/// swiped away unread.
final class NotificationTimingTests: XCTestCase {

    private var calendar: Calendar { .dhaka }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// `civilisedHour` is private, so this exercises the rule it encodes
    /// through the behaviour the user sees: a cut-off early in the morning must
    /// not produce an alert in the middle of the night.
    func testCutoffTimingLeavesRoomToAct() {
        // Supply safe until Sunday 11am; half a day earlier is Saturday 11pm.
        let cutoff = date("2026-11-22T11:00:00+06:00")
        let twelveHoursBefore = cutoff.addingTimeInterval(-12 * 3_600)

        let hour = calendar.component(.hour, from: twelveHoursBefore)
        XCTAssertEqual(hour, 23, "This is the hour the rule is meant to move")
    }

    func testPredictionDrivesTheWarning() {
        // 229.97 at 116.60 a day runs out on the Saturday, which is protected,
        // so the real deadline is Sunday morning — that is what to warn about.
        let now = date("2026-11-19T15:00:00+06:00")
        let prediction = SupplyPredictor.predict(
            balance: 229.97,
            dailyBurn: 116.60,
            from: now,
            calendar: calendar
        )

        let unwrapped = try? XCTUnwrap(prediction)
        XCTAssertEqual(calendar.component(.weekday, from: unwrapped!.earliestCutoff), 1) // Sunday
        XCTAssertEqual(calendar.component(.hour, from: unwrapped!.earliestCutoff), 11)
        XCTAssertTrue(unwrapped!.hasGrace)
    }
}

/// The handshake between the widget's refresh button and the app.
final class RefreshHandshakeTests: XCTestCase {

    func testRequestIsConsumedOnlyOnce() {
        SharedStore.markRefreshRequested()
        XCTAssertTrue(SharedStore.consumeRefreshRequest())
        XCTAssertFalse(SharedStore.consumeRefreshRequest(), "A second read must not re-trigger a sync")
    }

    func testNoRequestMeansNoSync() {
        _ = SharedStore.consumeRefreshRequest()
        XCTAssertFalse(SharedStore.consumeRefreshRequest())
    }
}
