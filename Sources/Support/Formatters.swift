import Foundation

enum Formatters {

    /// Figures carry Bengali digits when the app is in Bangla, because the
    /// numbers are the part of this screen people actually read.
    static func taka(_ value: Double?, decimals: Int = 2) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = decimals
        formatter.groupingSeparator = ","
        let number = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "৳\(BengaliDigits.localize(number))"
    }

    /// Whole taka, for places where the decimals are noise.
    static func takaShort(_ value: Double?) -> String {
        taka(value, decimals: 0)
    }

    static func units(_ value: Double?) -> String {
        guard let value else { return "—" }
        let number = BengaliDigits.localize(String(format: "%.1f", value))
        return "\(number) \(L10n.callAttention("kWh", "ইউনিট"))"
    }

    static func days(_ value: Double?) -> String {
        guard let value else { return "—" }

        if value < 1 {
            let hours = Int((value * 24).rounded())
            if hours <= 1 { return L10n.callAttention("under an hour", "এক ঘণ্টারও কম") }
            return "\(BengaliDigits.localize("\(hours)")) \(L10n.callAttention("hours", "ঘণ্টা"))"
        }

        let number = value < 10
            ? String(format: "%.1f", value)
            : "\(Int(value.rounded()))"

        return "\(BengaliDigits.localize(number)) \(L10n.callAttention("days", "দিন"))"
    }

    static func hours(_ value: Double) -> String {
        if value < 1 {
            return "\(Int((value * 60).rounded())) minutes"
        }
        if value == value.rounded() {
            return "\(Int(value)) hour\(value == 1 ? "" : "s")"
        }
        return String(format: "%.1f hours", value)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func dayMonth(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Dhaka")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    static func fullDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Dhaka")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
