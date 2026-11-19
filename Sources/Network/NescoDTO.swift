import Foundation

/// Values scraped from the NESCO customer portal's information block.
/// NESCO exposes no JSON API, so every field arrives as text and may be absent.
struct NescoCustomerInfo: Sendable, Equatable {
    var name: String?
    var fatherOrHusband: String?
    var address: String?
    var mobile: String?
    var office: String?
    var feeder: String?
    var consumerNo: String?
    var meterNo: String?
    var sanctionedLoad: String?
    var tariff: String?
    var meterType: String?
    var meterStatus: String?
    var installDate: String?
    var minimumRecharge: Double?
    var balance: Double?
    var readingDate: String?
}

/// One row of the portal's recharge history table.
///
/// The portal carries the full financial breakdown in `data-*` attributes on the
/// row element, which is richer than the visible cells — it is where the meter
/// rent, demand charge and VAT deductions come from.
struct NescoRecharge: Sendable, Equatable, Identifiable {
    var id: String { token.isEmpty ? "\(order)-\(rechargeDate)" : token }

    var order: String = ""
    var token: String = ""
    var sequence: String = ""

    /// What the customer actually paid.
    var totalAmount: Double?
    /// The portion that became electricity credit, after deductions.
    var electricityAmount: Double?
    /// Energy units purchased, in kWh.
    var energyUnit: Double?

    var meterRent: Double?
    var demandCharge: Double?
    var vat: Double?
    var pfc: Double?
    var subsidy: Double?
    var debtAmount: Double?
    var paidAmount: Double?

    var method: String = ""
    var rechargeDate: String = ""
    var status: String = ""

    var meterNo: String = ""
    var customerNo: String = ""
    var customerName: String = ""
    var tariff: String = ""

    /// Everything deducted from the payment before it became usable credit.
    var totalDeductions: Double? {
        let parts = [meterRent, demandCharge, vat, pfc].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0, +)
    }
}

/// One row of the portal's monthly usage table.
///
/// NESCO publishes consumption monthly only — there is no daily feed. The table
/// is richer than it first appears: alongside units and spend it carries the
/// meter's balance at each month end, which gives the app a real history to work
/// from on the very first sync instead of waiting days to accumulate readings.
struct NescoMonthlyUsage: Sendable, Equatable, Identifiable {
    /// Formatted `yyyy-MM`.
    var month: String

    /// Electricity consumed, in kWh.
    var unit: Double?
    /// Electricity consumed, in taka — the figure the daily burn rate is built on.
    var electricityTaka: Double?
    /// Everything recharged during the month.
    var totalRecharge: Double?
    /// Rebate, reported by the portal as a negative number.
    var rebate: Double?

    var meterRent: Double?
    var demandCharge: Double?
    var pfc: Double?
    var arrears: Double?
    var vat: Double?

    /// Electricity plus every charge taken during the month.
    var totalDeducted: Double?
    /// Meter balance at the close of the month.
    var endBalance: Double?

    var id: String { month }

    /// Fixed charges only — what the meter costs before any electricity is used.
    var fixedCharges: Double? {
        let parts = [meterRent, demandCharge, pfc, vat].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// A complete read of one meter from the portal.
struct NescoSnapshot: Sendable, Equatable {
    var customerNumber: String
    var info: NescoCustomerInfo
    var recharges: [NescoRecharge]
    var monthly: [NescoMonthlyUsage]
    var fetchedAt: Date

    var balance: Double? { info.balance }
}

enum NescoError: LocalizedError, Equatable {
    case invalidCustomerNumber
    case noCSRFToken
    case httpStatus(Int)
    case accountNotFound
    case portalChanged
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidCustomerNumber:
            return "Customer number must be 5 to 14 digits."
        case .noCSRFToken:
            return "NESCO portal did not return a security token. The portal layout may have changed."
        case .httpStatus(let code):
            return "NESCO portal responded with HTTP \(code)."
        case .accountNotFound:
            return "No NESCO account found for this customer number."
        case .portalChanged:
            return "NESCO returned no usable data. The portal may have changed or blocked this request."
        case .offline:
            return "Could not reach the NESCO portal. Check your connection."
        }
    }

    /// The portal blocks requests from outside Bangladesh, which is worth
    /// surfacing distinctly — it is the most common cause of a sudden 403.
    var recoverySuggestion: String? {
        switch self {
        case .httpStatus(403):
            return "The portal blocks non-Bangladeshi networks. Turn off any VPN and try again on your mobile data or local Wi-Fi."
        case .offline:
            return "The NESCO portal is only reachable from Bangladesh."
        default:
            return nil
        }
    }
}
