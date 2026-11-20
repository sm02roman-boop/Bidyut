import Foundation

/// Where the poller lives and the token that opens it.
///
/// Both are typed in once, in Meter settings. Empty means "read the NESCO
/// portal directly from this phone", which only works on a Bangladeshi network.
enum ServerSettings {
    private static let urlKey = "server.url"
    private static let tokenKey = "server.token"

    static var url: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
    }

    static var token: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: tokenKey) }
    }

    static var isConfigured: Bool {
        !url.isEmpty && !token.isEmpty && URL(string: url)?.scheme != nil
    }
}

/// Reads one meter from the Bidyut poller's HTTP API.
///
/// The poller already parsed the portal and kept its own history, so the phone
/// only has to fetch the latest state. `fetchedAt` is the time the poller read
/// the portal, which is what "last synced" should honestly show.
struct ServerClient {

    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    init?(settings: ServerSettings.Type = ServerSettings.self) {
        guard settings.isConfigured, let url = URL(string: settings.url) else { return nil }
        self.baseURL = url
        self.token = settings.token
    }

    func fetchSnapshot(customerNumber: String) async throws -> NescoSnapshot {
        let customer = try NescoClient.validate(customerNumber)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/meter/\(customer)"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NescoError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw NescoError.portalChanged }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw ServerError.unauthorised }
            if http.statusCode == 404 { throw ServerError.meterNotConfigured }
            if http.statusCode == 503 { throw ServerError.noReadingYet }
            throw ServerError.httpStatus(http.statusCode)
        }

        let wire = try JSONDecoder().decode(WirePayload.self, from: data)
        return wire.snapshot(customerNumber: customer)
    }

    // MARK: - Wire format

    /// Mirrors `GET /api/meter/:customerNo` in `server/index.js`.
    /// Every field is optional: the poller omits what the portal did not show.
    private struct WirePayload: Decodable {
        var customerNo: String
        var fetchedAt: String
        var balance: Double?
        var info: [String: String]?
        var recharges: [WireRecharge]?
        var monthly: [WireMonthly]?

        func snapshot(customerNumber: String) -> NescoSnapshot {
            let fields = info ?? [:]
            let date = Self.parseISO(fetchedAt) ?? Date()

            var customerInfo = NescoCustomerInfo()
            customerInfo.name = fields["name"]
            customerInfo.fatherOrHusband = fields["fatherOrHusband"]
            customerInfo.address = fields["address"]
            customerInfo.mobile = fields["mobile"]
            customerInfo.office = fields["office"]
            customerInfo.feeder = fields["feeder"]
            customerInfo.consumerNo = fields["consumerNo"]
            customerInfo.meterNo = fields["meterNo"]
            customerInfo.sanctionedLoad = fields["sanctionedLoad"]
            customerInfo.tariff = fields["tariff"]
            customerInfo.meterType = fields["meterType"]
            customerInfo.meterStatus = fields["meterStatus"]
            customerInfo.installDate = fields["installDate"]
            customerInfo.minimumRecharge = Self.number(fields["minimumRecharge"])
            customerInfo.balance = balance ?? Self.number(fields["balance"])
            customerInfo.readingDate = fields["readingDate"]

            return NescoSnapshot(
                customerNumber: customerNumber,
                info: customerInfo,
                recharges: (recharges ?? []).map { $0.recharge },
                monthly: (monthly ?? []).map { $0.usage },
                fetchedAt: date
            )
        }

        static func number(_ text: String?) -> Double? {
            guard let text else { return nil }
            return Double(text.replacingOccurrences(of: ",", with: ""))
        }

        static func parseISO(_ text: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            return ISO8601DateFormatter().date(from: text)
        }
    }

    /// `date` is the raw portal string (e.g. "08-NOV-2026 12:59 PM"), which the
    /// app already parses with `NescoParser.parseDate`.
    private struct WireRecharge: Decodable {
        var token: String?
        var date: String?
        var totalAmount: Double?
        var electricityAmount: Double?
        var energyUnit: Double?
        var meterRent: Double?
        var demandCharge: Double?
        var vat: Double?
        var pfc: Double?
        var subsidy: Double?
        var method: String?
        var status: String?

        var recharge: NescoRecharge {
            var row = NescoRecharge()
            row.token = token ?? ""
            row.rechargeDate = date ?? ""
            row.totalAmount = totalAmount
            row.electricityAmount = electricityAmount
            row.energyUnit = energyUnit
            row.meterRent = meterRent
            row.demandCharge = demandCharge
            row.vat = vat
            row.pfc = pfc
            row.subsidy = subsidy
            row.method = method ?? ""
            row.status = status ?? ""
            return row
        }
    }

    private struct WireMonthly: Decodable {
        var month: String
        var unit: Double?
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

        var usage: NescoMonthlyUsage {
            NescoMonthlyUsage(
                month: month,
                unit: unit,
                electricityTaka: electricityTaka,
                totalRecharge: totalRecharge,
                rebate: rebate,
                meterRent: meterRent,
                demandCharge: demandCharge,
                pfc: pfc,
                arrears: arrears,
                vat: vat,
                totalDeducted: totalDeducted,
                endBalance: endBalance
            )
        }
    }
}

enum ServerError: LocalizedError, Equatable {
    case unauthorised
    case meterNotConfigured
    case noReadingYet
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorised: return "The server rejected the token. Check it in Meter settings."
        case .meterNotConfigured: return "This meter is not listed in the server's config.json."
        case .noReadingYet: return "The server has not read the portal yet. Try again in a few minutes."
        case .httpStatus(let code): return "The server responded with HTTP \(code)."
        }
    }
}
