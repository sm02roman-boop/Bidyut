import Foundation
import SwiftUI

/// Which language the app speaks.
///
/// The meter, the portal and the hotline all speak Bangla, so the app offering
/// only English puts a translation step between the user and their own meter.
/// The choice is explicit rather than purely system-driven, because a phone set
/// to English is not a statement about which language someone wants their
/// electricity bill in.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case bangla
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .bangla: return "বাংলা"
        case .english: return "English"
        }
    }

    /// The language actually in force, once `system` is resolved.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("bn") ? .bangla : .english
    }

    var isBangla: Bool { resolved == .bangla }
}

/// The current language, readable from anywhere including the widget.
enum LanguageSettings {
    private static let key = "app.language"

    static var current: AppLanguage {
        get {
            let store = UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
            return AppLanguage(rawValue: store.string(forKey: key) ?? "") ?? .system
        }
        set {
            let store = UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
            store.set(newValue.rawValue, forKey: key)
        }
    }
}

/// Every user-facing string, in both languages.
///
/// Kept as a table rather than `.strings` files so the language can be switched
/// inside the app without relaunching — which matters here, because a household
/// often has one person who reads English and another who does not.
enum L10n {

    static var language: AppLanguage { LanguageSettings.current.resolved }

    static func callAttention(_ en: String, _ bn: String) -> String {
        language == .bangla ? bn : en
    }

    // Status
    static var rechargeNow: String { callAttention("Recharge now", "এখনই রিচার্জ করুন") }
    static var runningLow: String { callAttention("Running low", "ব্যালেন্স কমে আসছে") }
    static var healthy: String { callAttention("Healthy", "পর্যাপ্ত ব্যালেন্স") }
    static var notEnoughData: String { callAttention("Not enough data", "যথেষ্ট তথ্য নেই") }

    // Dashboard
    static var forecast: String { callAttention("Forecast", "পূর্বাভাস") }
    static var daysLeft: String { callAttention("Days left", "কত দিন চলবে") }
    static var dailyUsage: String { callAttention("Daily usage", "দৈনিক খরচ") }
    static var perDay: String { callAttention("per day", "প্রতিদিন") }
    static var avgLoad: String { callAttention("Avg load", "গড় লোড") }
    static var unitsLeft: String { callAttention("Left", "বাকি আছে") }
    static var perUnit: String { callAttention("per unit", "প্রতি ইউনিট") }
    static var updated: String { callAttention("Updated", "আপডেট") }
    static var thisMonth: String { callAttention("This month", "এই মাসে") }
    static var unitsSoFar: String { callAttention("units so far", "ইউনিট ব্যবহৃত") }
    static var meter: String { callAttention("Meter", "মিটার") }
    static var customerNumber: String { callAttention("Customer no.", "গ্রাহক নম্বর") }
    static var meterNumber: String { callAttention("Meter no.", "মিটার নম্বর") }
    static var sanctionedLoad: String { callAttention("Sanctioned load", "অনুমোদিত লোড") }
    static var tariff: String { callAttention("Tariff", "ট্যারিফ") }

    // Recharge
    static var recharge: String { callAttention("Recharge", "রিচার্জ") }
    static var rechargeSuggestion: String { callAttention("Recharge suggestion", "রিচার্জ পরামর্শ") }
    static var rechargeHistory: String { callAttention("Recharge history", "রিচার্জ ইতিহাস") }
    static var recharges: String { callAttention("Recharges", "রিচার্জসমূহ") }
    static var creditedToBalance: String { callAttention("Credited to balance", "ব্যালেন্সে যোগ হয়েছে") }
    static var meterRent: String { callAttention("Meter rent", "মিটার ভাড়া") }
    static var demandCharge: String { callAttention("Demand charge", "ডিমান্ড চার্জ") }
    static var vat: String { callAttention("VAT", "ভ্যাট") }
    static var deductions: String { callAttention("Deductions", "কর্তন") }
    static var ofPayment: String { callAttention("of payment", "পেমেন্টের") }
    static var token: String { callAttention("Token", "টোকেন") }
    static var copy: String { callAttention("Copy", "কপি") }
    static var copied: String { callAttention("Copied", "কপি হয়েছে") }
    static var failed: String { callAttention("Failed", "ব্যর্থ") }
    static var success: String { callAttention("Success", "সফল") }

    // Supply
    static var whenSupplyStops: String { callAttention("When supply would stop", "বিদ্যুৎ কখন যাবে") }
    static var balanceHitsZero: String { callAttention("Balance hits zero", "ব্যালেন্স শূন্য হবে") }
    static var supplyCouldCut: String { callAttention("Supply could cut", "লাইন কাটতে পারে") }
    static var friendlyHour: String { callAttention("Friendly Hour", "ফ্রেন্ডলি আওয়ার") }
    static var holiday: String { callAttention("Holiday", "ছুটির দিন") }
    static var cutoffWindow: String { callAttention("Cut-off window", "কাটার সময়") }
    static var rightNow: String { callAttention("Right now", "এই মুহূর্তে") }

    // Slab
    static var whereMonthSits: String { callAttention("Where this month sits", "এই মাস কোথায় দাঁড়িয়ে") }
    static var monthEnd: String { callAttention("month end", "মাস শেষে") }
    static var now: String { callAttention("now", "এখন") }
    static var runningCost: String { callAttention("What does it cost to run?", "চালাতে কত খরচ?") }
    static var power: String { callAttention("Power", "ক্ষমতা") }
    static var runningTime: String { callAttention("Running time", "কত সময় চলবে") }
    static var aMonthIfDaily: String { callAttention("a month, if run daily", "মাসে, রোজ চালালে") }

    // Settings and actions
    static var settings: String { callAttention("Settings", "সেটিংস") }
    static var language: String { callAttention("Language", "ভাষা") }
    static var done: String { callAttention("Done", "সম্পন্ন") }
    static var cancel: String { callAttention("Cancel", "বাতিল") }
    static var addMeter: String { callAttention("Add meter", "মিটার যোগ করুন") }
    static var syncNow: String { callAttention("Sync now", "এখন আপডেট করুন") }
    static var callNesco: String { callAttention("Call NESCO 16603", "নেসকো ১৬৬০৩ এ কল") }
    static var alerts: String { callAttention("Alerts", "সতর্কবার্তা") }

    // Appliances
    static var ceilingFan: String { callAttention("Ceiling fan", "সিলিং ফ্যান") }
    static var fridge: String { callAttention("Fridge", "ফ্রিজ") }
    static var airConditioner: String { callAttention("1 ton AC", "১ টন এসি") }
    static var waterPump: String { callAttention("Water pump", "পানির পাম্প") }
    static var iron: String { callAttention("Iron", "ইস্ত্রি") }
}

/// Bengali digits, because a number is the thing people actually read on this
/// screen and `২২৯.৯৭` is what a Bangla reader expects to see.
enum BengaliDigits {
    private static let map: [Character: Character] = [
        "0": "০", "1": "১", "2": "২", "3": "৩", "4": "৪",
        "5": "৫", "6": "৬", "7": "৭", "8": "৮", "9": "৯"
    ]

    static func convert(_ text: String) -> String {
        String(text.map { map[$0] ?? $0 })
    }

    /// Applies only when the app is in Bangla, so English stays untouched.
    static func localize(_ text: String) -> String {
        L10n.language == .bangla ? convert(text) : text
    }
}
