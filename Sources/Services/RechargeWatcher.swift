import Foundation
import UserNotifications

/// Notices when a recharge goes wrong.
///
/// A failed recharge is the one event in this whole app where money may already
/// have left the user's wallet without electricity arriving — and the portal
/// reports it quietly, as a word in the last cell of a row nobody scrolls to.
/// This meter's own history carries four of them.
///
/// The app sees every sync, so it can say something the portal never does:
/// *this one failed, here is the hotline.*
@MainActor
enum RechargeWatcher {

    /// Recharges already surfaced, so a failure is reported once and not on
    /// every sync for the rest of its life.
    private static let seenKey = "recharge.flagged"

    private static var store: UserDefaults {
        UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
    }

    private static var flagged: Set<String> {
        get { Set(store.stringArray(forKey: seenKey) ?? []) }
        set { store.set(Array(newValue), forKey: seenKey) }
    }

    /// Failures from the last fortnight that the user has not been told about.
    ///
    /// Older ones are left alone: nothing can be done about a failure from
    /// three months ago, and raising it would be noise.
    static func newFailures(in meter: Meter, now: Date = Date()) -> [Recharge] {
        let cutoff = now.addingTimeInterval(-14 * 86_400)
        let seen = flagged

        return meter.recharges
            .filter { !$0.isSuccessful && $0.date >= cutoff && !seen.contains($0.key) }
            .sorted { $0.date > $1.date }
    }

    /// Reports new failures and remembers them.
    static func reportFailures(in meter: Meter, now: Date = Date()) async {
        let failures = newFailures(in: meter, now: now)
        guard !failures.isEmpty else { return }

        var seen = flagged
        for failure in failures { seen.insert(failure.key) }
        flagged = seen

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        for failure in failures.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = L10n.callAttention(
                "Recharge failed",
                "রিচার্জ ব্যর্থ হয়েছে"
            )
            content.body = L10n.callAttention(
                "\(Formatters.takaShort(failure.totalAmount)) on \(Formatters.dayMonth(failure.date)) via \(failure.method ?? "your wallet") did not go through. If the money left your account, call NESCO on 16603.",
                "\(Formatters.dayMonth(failure.date)) তারিখে \(failure.method ?? "ওয়ালেট") দিয়ে \(Formatters.takaShort(failure.totalAmount)) রিচার্জ হয়নি। টাকা কেটে থাকলে নেসকো ১৬৬০৩ এ কল করুন।"
            )
            content.sound = .default
            content.userInfo = ["customerNumber": meter.customerNumber, "rechargeKey": failure.key]

            let request = UNNotificationRequest(
                identifier: "failed-\(failure.key)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
            )
            try? await center.add(request)
        }
    }

    /// Confirms a recharge that landed, so the user does not have to go and
    /// check whether it worked.
    ///
    /// The number worth reporting is what reached the balance, not what was
    /// paid — those differ by the deductions, and the gap is what surprises
    /// people.
    static func confirmCredit(for recharge: Recharge, meter: Meter) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let credited = recharge.electricityAmount ?? recharge.totalAmount

        let content = UNMutableNotificationContent()
        content.title = L10n.callAttention("Recharge credited", "রিচার্জ যোগ হয়েছে")
        content.body = L10n.callAttention(
            "\(Formatters.takaShort(recharge.totalAmount)) paid — \(Formatters.taka(credited)) reached the meter after deductions.",
            "\(Formatters.takaShort(recharge.totalAmount)) দিয়েছেন — কর্তনের পর মিটারে পৌঁছেছে \(Formatters.taka(credited))।"
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "credited-\(recharge.key)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        )
        try? await center.add(request)
    }

    /// Forgets the record of what has been reported — used when a meter is removed.
    static func forget(meter: Meter) {
        let keys = Set(meter.recharges.map(\.key))
        flagged = flagged.subtracting(keys)
    }
}
