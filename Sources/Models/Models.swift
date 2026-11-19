import Foundation
import SwiftData

/// A prepaid meter the user tracks.
@Model
final class Meter {
    /// NESCO customer number — the only identifier the portal accepts.
    @Attribute(.unique) var customerNumber: String

    var nickname: String
    var meterNumber: String?
    var customerName: String?
    var address: String?
    var tariff: String?
    var office: String?
    var feeder: String?
    var sanctionedLoad: String?
    var minimumRecharge: Double?
    /// 1P or 3P keypad, which decides the emergency credit limit.
    var meterType: String?

    var createdAt: Date
    var lastSyncedAt: Date?

    /// Balance below which the app warns. Zero means use the global default.
    var lowBalanceThreshold: Double
    var notificationsEnabled: Bool
    var isPrimary: Bool

    @Relationship(deleteRule: .cascade, inverse: \BalanceSnapshot.meter)
    var snapshots: [BalanceSnapshot] = []

    @Relationship(deleteRule: .cascade, inverse: \Recharge.meter)
    var recharges: [Recharge] = []

    @Relationship(deleteRule: .cascade, inverse: \MonthlyUsage.meter)
    var monthlyUsage: [MonthlyUsage] = []

    init(
        customerNumber: String,
        nickname: String,
        lowBalanceThreshold: Double = 0,
        notificationsEnabled: Bool = true,
        isPrimary: Bool = false
    ) {
        self.customerNumber = customerNumber
        self.nickname = nickname
        self.createdAt = Date()
        self.lowBalanceThreshold = lowBalanceThreshold
        self.notificationsEnabled = notificationsEnabled
        self.isPrimary = isPrimary
    }

    var latestSnapshot: BalanceSnapshot? {
        snapshots.max { $0.capturedAt < $1.capturedAt }
    }

    var currentBalance: Double? {
        latestSnapshot?.balance
    }

    var displayName: String {
        nickname.isEmpty ? (customerName ?? customerNumber) : nickname
    }
}

/// One reading of the meter's balance at a point in time.
///
/// NESCO publishes consumption monthly only, so these snapshots are what the app
/// differentiates to derive a daily burn rate. Every sync appends one.
@Model
final class BalanceSnapshot {
    var capturedAt: Date
    var balance: Double
    var meter: Meter?

    init(capturedAt: Date = Date(), balance: Double, meter: Meter? = nil) {
        self.capturedAt = capturedAt
        self.balance = balance
        self.meter = meter
    }
}

/// A recharge as recorded by the portal, with its full deduction breakdown.
@Model
final class Recharge {
    @Attribute(.unique) var key: String

    var token: String
    var date: Date
    /// What the customer paid.
    var totalAmount: Double
    /// The portion that became electricity credit after deductions.
    var electricityAmount: Double?
    var energyUnit: Double?

    var meterRent: Double?
    var demandCharge: Double?
    var vat: Double?
    var pfc: Double?
    var subsidy: Double?

    var method: String?
    var status: String?

    var meter: Meter?

    init(
        key: String,
        token: String,
        date: Date,
        totalAmount: Double,
        electricityAmount: Double? = nil,
        energyUnit: Double? = nil,
        meterRent: Double? = nil,
        demandCharge: Double? = nil,
        vat: Double? = nil,
        pfc: Double? = nil,
        subsidy: Double? = nil,
        method: String? = nil,
        status: String? = nil,
        meter: Meter? = nil
    ) {
        self.key = key
        self.token = token
        self.date = date
        self.totalAmount = totalAmount
        self.electricityAmount = electricityAmount
        self.energyUnit = energyUnit
        self.meterRent = meterRent
        self.demandCharge = demandCharge
        self.vat = vat
        self.pfc = pfc
        self.subsidy = subsidy
        self.method = method
        self.status = status
        self.meter = meter
    }

    var totalDeductions: Double? {
        let parts = [meterRent, demandCharge, vat, pfc].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// Share of the payment lost to fixed charges, useful for spotting a month
    /// where arrears or demand charges ate an unusual amount of the recharge.
    var deductionShare: Double? {
        guard let deductions = totalDeductions, totalAmount > 0 else { return nil }
        return deductions / totalAmount
    }

    var isSuccessful: Bool {
        guard let status, !status.isEmpty else { return true }
        let failureMarkers = ["fail", "ব্যর্থ", "cancel", "বাতিল"]
        return !failureMarkers.contains { status.localizedCaseInsensitiveContains($0) }
    }
}

/// One month of consumption as published by NESCO.
///
/// `endBalance` is the useful surprise here: NESCO records the meter's balance
/// at the close of each month, so a newly added meter has months of real history
/// to forecast from rather than nothing.
@Model
final class MonthlyUsage {
    @Attribute(.unique) var key: String

    /// Formatted `yyyy-MM`.
    var month: String
    var unit: Double?
    /// Electricity consumed during the month, in taka.
    var electricityTaka: Double?
    var totalRecharge: Double?
    var rebate: Double?
    var meterRent: Double?
    var demandCharge: Double?
    var pfc: Double?
    var arrears: Double?
    var vat: Double?
    var totalDeducted: Double?
    var endBalance: Double?

    var meter: Meter?

    init(
        key: String,
        month: String,
        unit: Double? = nil,
        electricityTaka: Double? = nil,
        totalRecharge: Double? = nil,
        rebate: Double? = nil,
        meterRent: Double? = nil,
        demandCharge: Double? = nil,
        pfc: Double? = nil,
        arrears: Double? = nil,
        vat: Double? = nil,
        totalDeducted: Double? = nil,
        endBalance: Double? = nil,
        meter: Meter? = nil
    ) {
        self.key = key
        self.month = month
        self.unit = unit
        self.electricityTaka = electricityTaka
        self.totalRecharge = totalRecharge
        self.rebate = rebate
        self.meterRent = meterRent
        self.demandCharge = demandCharge
        self.pfc = pfc
        self.arrears = arrears
        self.vat = vat
        self.totalDeducted = totalDeducted
        self.endBalance = endBalance
        self.meter = meter
    }

    /// Fixed charges only — what the meter costs before any electricity is used.
    var fixedCharges: Double? {
        let parts = [meterRent, demandCharge, pfc, vat].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// Average taka per day of electricity across the month.
    var dailyAverage: Double? {
        guard let electricityTaka, let date, electricityTaka > 0 else { return nil }
        let days = Calendar.dhaka.range(of: .day, in: .month, for: date)?.count ?? 30
        return electricityTaka / Double(days)
    }

    /// The last instant of this month, in Dhaka time — when `endBalance` was read.
    var endOfMonth: Date? {
        guard let date,
              let range = Calendar.dhaka.range(of: .day, in: .month, for: date),
              let start = Calendar.dhaka.date(bySettingHour: 23, minute: 59, second: 0, of: date)
        else { return nil }
        return Calendar.dhaka.date(byAdding: .day, value: range.count - 1, to: start)
    }

    var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Dhaka")
        formatter.dateFormat = "yyyy-MM"
        return formatter.date(from: month)
    }

    var shortLabel: String {
        guard let date else { return month }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }
}
