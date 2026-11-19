import Foundation

/// Talks to the NESCO customer portal.
///
/// NESCO publishes no API. The portal renders everything server-side inside a
/// session that begins with a CSRF token and a cookie, so this client recreates
/// the browser's own three-step flow:
///
///   1. `GET  /pre/panel`  → CSRF token + session cookie
///   2. `POST /pre/panel`  with `submit = রিচার্জ হিস্ট্রি` → customer info + recharges
///   3. `POST /pre/panel`  with `submit = মাসিক ব্যবহার`   → monthly consumption
///
/// The portal is reachable only from Bangladeshi networks; a VPN will produce a
/// 403. All HTML handling lives in `NescoParser` so a portal redesign is a
/// one-file fix.
actor NescoClient {

    static let portalOrigin = "https://customer.nesco.gov.bd"
    static let panelURL = URL(string: "\(portalOrigin)/pre/panel")!

    /// The portal identifies its actions by the Bengali text of the submit button.
    private enum SubmitAction: String {
        case rechargeHistory = "রিচার্জ হিস্ট্রি"
        case monthlyUsage = "মাসিক ব্যবহার"
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // A fresh cookie jar per client keeps the portal session isolated and
            // carries the cookie from the GET into the POST automatically.
            configuration.httpCookieStorage = HTTPCookieStorage()
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Public API

    /// Reads everything the portal knows about one meter.
    ///
    /// Monthly usage is treated as a bonus: if that second request fails, the
    /// balance and recharge history are still returned.
    func fetchSnapshot(customerNumber: String) async throws -> NescoSnapshot {
        let customer = try Self.validate(customerNumber)
        let session = try await startSession()

        let historyHTML = try await submit(action: .rechargeHistory, customer: customer, session: session)

        let info = NescoParser.parseCustomerInfo(from: historyHTML)
        let recharges = NescoParser.parseRecharges(from: historyHTML)

        guard info.consumerNo != nil || info.meterNo != nil || info.name != nil || !recharges.isEmpty else {
            throw NescoParser.looksLikeAccountNotFound(historyHTML)
                ? NescoError.accountNotFound
                : NescoError.portalChanged
        }

        var monthly: [NescoMonthlyUsage] = []
        if let monthlyHTML = try? await submit(action: .monthlyUsage, customer: customer, session: session) {
            monthly = NescoParser.parseMonthlyUsage(from: monthlyHTML)
        }

        var resolved = info
        // Older portal versions leave the info block empty but still populate the
        // recharge rows, which carry the same identity fields.
        if resolved.consumerNo == nil, let first = recharges.first {
            resolved.consumerNo = first.customerNo.isEmpty ? customer : first.customerNo
            resolved.meterNo = resolved.meterNo ?? (first.meterNo.isEmpty ? nil : first.meterNo)
            resolved.name = resolved.name ?? (first.customerName.isEmpty ? nil : first.customerName)
            resolved.tariff = resolved.tariff ?? (first.tariff.isEmpty ? nil : first.tariff)
        }

        return NescoSnapshot(
            customerNumber: customer,
            info: resolved,
            recharges: recharges.sorted { lhs, rhs in
                let left = NescoParser.parseDate(lhs.rechargeDate) ?? .distantPast
                let right = NescoParser.parseDate(rhs.rechargeDate) ?? .distantPast
                return left > right
            },
            monthly: monthly,
            fetchedAt: Date()
        )
    }

    // MARK: - Session flow

    private struct PortalSession {
        let token: String
    }

    private func startSession() async throws -> PortalSession {
        var request = URLRequest(url: Self.panelURL)
        request.httpMethod = "GET"
        request.setValue(Self.portalOrigin + "/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await perform(request)
        try Self.checkStatus(response)

        let html = Self.decode(data)
        guard let token = NescoParser.csrfToken(in: html) else {
            throw NescoError.noCSRFToken
        }
        return PortalSession(token: token)
    }

    private func submit(action: SubmitAction, customer: String, session: PortalSession) async throws -> String {
        var request = URLRequest(url: Self.panelURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.portalOrigin, forHTTPHeaderField: "Origin")
        request.setValue(Self.panelURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        request.httpBody = Self.formBody([
            "_token": session.token,
            "cust_no": customer,
            "submit": action.rawValue
        ])

        let (data, response) = try await perform(request)
        try Self.checkStatus(response)
        return Self.decode(data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .timedOut, .dnsLookupFailed:
                throw NescoError.offline
            default:
                throw error
            }
        }
    }

    // MARK: - Helpers

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func validate(_ raw: String) throws -> String {
        let digits = raw.filter(\.isNumber)
        guard (5...14).contains(digits.count) else {
            throw NescoError.invalidCustomerNumber
        }
        return digits
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NescoError.httpStatus(http.statusCode)
        }
    }

    /// The submit labels are Bengali, so the body must be UTF-8 percent-encoded.
    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let encoded = fields.map { key, value in
            let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let safeValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(safeKey)=\(safeValue)"
        }
        return encoded.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    /// The portal serves UTF-8 but has been seen mislabelling its charset.
    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
