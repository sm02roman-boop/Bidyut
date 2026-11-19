import Foundation

/// Pure parsing functions for the NESCO portal's HTML.
///
/// These are deliberately free of networking so they can be tested against saved
/// fixtures. When NESCO redesigns the portal, this file is the only one to fix.
enum NescoParser {

    // MARK: - CSRF token

    /// The portal issues a Laravel CSRF token, either as a meta tag or as a
    /// hidden form input depending on the portal version.
    static func csrfToken(in html: String) -> String? {
        let patterns = [
            #"name=["']_token["'][^>]*value=["']([^"']+)["']"#,
            #"value=["']([^"']+)["'][^>]*name=["']_token["']"#,
            #"<meta[^>]+name=["']csrf-token["'][^>]+content=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            if let match = html.firstCapture(pattern: pattern) {
                return match
            }
        }
        return nil
    }

    // MARK: - Customer information

    /// Fields inside `#con_info_div` are plain `<input value="...">` elements with
    /// no stable names, so they are read positionally. The order below is the
    /// portal's own and is cross-checked against two reference implementations.
    private enum InfoIndex {
        static let name = 0
        static let fatherOrHusband = 1
        static let address = 2
        static let mobile = 3
        static let office = 4
        static let feeder = 5
        static let consumerNo = 6
        static let meterNo = 7
        static let sanctionedLoad = 8
        static let tariff = 9
        static let meterType = 10
        static let meterStatus = 11
        static let installDate = 12
        static let minimumRecharge = 13
        static let balance = 14
    }

    static func parseCustomerInfo(from html: String) -> NescoCustomerInfo {
        var info = NescoCustomerInfo()

        let segment = infoSegment(of: html) ?? html
        let values = inputValues(in: segment)

        func value(_ index: Int) -> String? {
            guard index < values.count else { return nil }
            let trimmed = values[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        info.name = value(InfoIndex.name)
        info.fatherOrHusband = value(InfoIndex.fatherOrHusband)
        info.address = value(InfoIndex.address)
        info.mobile = value(InfoIndex.mobile)
        info.office = value(InfoIndex.office)
        info.feeder = value(InfoIndex.feeder)
        info.consumerNo = value(InfoIndex.consumerNo)
        info.meterNo = value(InfoIndex.meterNo)
        info.sanctionedLoad = value(InfoIndex.sanctionedLoad)
        info.tariff = value(InfoIndex.tariff)
        info.meterType = value(InfoIndex.meterType)
        info.meterStatus = value(InfoIndex.meterStatus)
        info.installDate = value(InfoIndex.installDate)
        info.minimumRecharge = value(InfoIndex.minimumRecharge).flatMap(Self.number)
        info.balance = value(InfoIndex.balance).flatMap(Self.number)

        // Some portal versions move the balance out of the info block and into a
        // card header, so fall back to searching for it by label.
        if info.balance == nil {
            info.balance = fallbackBalance(in: html)
        }

        info.readingDate = html.firstCapture(
            pattern: #"(\d{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4})"#
        )

        return info
    }

    private static func infoSegment(of html: String) -> String? {
        guard let start = html.range(of: "id=\"con_info_div\"")
            ?? html.range(of: "id='con_info_div'") else { return nil }

        let tail = html[start.lowerBound...]
        for marker in ["consumerRechargeData", "arrear_notice_div"] {
            if let end = tail.range(of: marker) {
                return String(tail[..<end.lowerBound])
            }
        }
        return String(tail.prefix(40_000))
    }

    private static func fallbackBalance(in html: String) -> Double? {
        let patterns = [
            #"অবশিষ্ট\s*ব্যালেন্স[\s\S]{0,300}?value\s*=\s*["']\s*(-?[\d,.]+)\s*["']"#,
            #"(?:remaining|অবশিষ্ট)\s*(?:balance|ব্যালেন্স)[\s\S]{0,300}?(-?\d[\d,]*\.?\d*)"#,
            #"data-balance\s*=\s*["'](-?[\d,.]+)["']"#
        ]
        for pattern in patterns {
            if let raw = canonical(html).firstCapture(pattern: canonical(pattern)), let value = number(raw) {
                return value
            }
        }
        return nil
    }

    // MARK: - Recharge history

    /// Recharge rows are identified by carrying a `data-totalamount` attribute.
    /// Every figure the app needs is in that row's `data-*` attributes.
    static func parseRecharges(from html: String) -> [NescoRecharge] {
        let rowPattern = #"<[^>]*?data-totalamount\s*=\s*["'][^"']*["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: rowPattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [NescoRecharge] = []

        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: html) else { return }
            let tag = String(html[range])

            var record = NescoRecharge()
            record.order = dataAttribute(tag, "order") ?? ""
            record.token = dataAttribute(tag, "token") ?? ""
            record.sequence = dataAttribute(tag, "seq") ?? ""

            record.totalAmount = dataAttribute(tag, "totalamount").flatMap(number)
            record.electricityAmount = dataAttribute(tag, "purchaseamount").flatMap(number)
            record.energyUnit = dataAttribute(tag, "purchaseenergy").flatMap(number)

            record.meterRent = dataAttribute(tag, "rent").flatMap(number)
            record.demandCharge = dataAttribute(tag, "demandcharge").flatMap(number)
            record.vat = dataAttribute(tag, "tax").flatMap(number)
            record.pfc = dataAttribute(tag, "pfc").flatMap(number)
            record.subsidy = dataAttribute(tag, "subsidyamount").flatMap(number)
            record.debtAmount = dataAttribute(tag, "debtamount").flatMap(number)
            record.paidAmount = dataAttribute(tag, "paidamount").flatMap(number)

            record.method = dataAttribute(tag, "salename") ?? ""
            record.rechargeDate = dataAttribute(tag, "purchasedate") ?? ""
            record.meterNo = dataAttribute(tag, "meterno") ?? ""
            record.customerNo = dataAttribute(tag, "customerno") ?? ""
            record.customerName = dataAttribute(tag, "customername") ?? ""
            record.tariff = dataAttribute(tag, "tariff") ?? ""

            record.status = rowStatus(in: html, after: range.upperBound)

            results.append(record)
        }

        return results
    }

    /// The success/failure label sits in the row's last `<td>`.
    private static func rowStatus(in html: String, after index: String.Index) -> String {
        let limit = html.index(index, offsetBy: 20_000, limitedBy: html.endIndex) ?? html.endIndex
        let window = html[index..<limit]
        let rowEnd = window.range(of: "</tr>")?.lowerBound ?? limit
        let cells = String(html[index..<rowEnd]).allCaptures(pattern: #"<td[^>]*>([\s\S]*?)</td>"#)

        let last = cells
            .map { stripTags($0) }
            .last { !$0.isEmpty } ?? ""

        // Anything long is a stray cell rather than a status label.
        return last.count > 30 ? "" : last
    }

    // MARK: - Monthly usage

    static func parseMonthlyUsage(from html: String) -> [NescoMonthlyUsage] {
        let tables = html.allMatches(pattern: #"<table[\s\S]*?</table>"#)
        let candidates = tables.isEmpty ? [html] : tables

        for table in candidates {
            let rows = monthlyRows(in: table)
            if !rows.isEmpty {
                // Keep the first row seen for each month, oldest first.
                var seen = Set<String>()
                return rows
                    .filter { seen.insert($0.month).inserted }
                    .sorted { $0.month < $1.month }
            }
        }
        return []
    }

    /// Each column the monthly table carries, and how to recognise its header.
    ///
    /// Several headers end in "(টাকা)", so a loose match on that word would pick
    /// the wrong column — the patterns below key on the distinguishing words and
    /// are tried in order against each header.
    private enum MonthlyColumn: CaseIterable {
        case units, electricityTaka, totalRecharge, rebate
        case meterRent, demandCharge, pfc, arrears, vat
        case totalDeducted, endBalance

        var pattern: String {
            switch self {
            case .units: return #"কি\.ও\.আ|kwh|unit"#
            case .electricityTaka: return #"ব্যবহৃত\s*বিদ্যুৎ\s*\(\s*টাকা"#
            case .totalRecharge: return #"সর্বমোট\s*রিচার্জ|total\s*recharge"#
            case .rebate: return #"রেয়াত|rebate"#
            case .meterRent: return #"মিটার\s*রেন্ট|meter\s*rent"#
            case .demandCharge: return #"ডিমান্ড|demand"#
            case .pfc: return #"পিএফসি|pfc"#
            case .arrears: return #"বকেয়া|জরিমানা|arrear|penalty"#
            case .vat: return #"ভ্যাট|vat"#
            case .totalDeducted: return #"সর্বমোট\s*ব্যবহার|কর্তন"#
            case .endBalance: return #"মাস\s*শেষে|শেষে\s*মিটার\s*ব্যালেন্স|closing\s*balance"#
            }
        }

        /// The column's position in the portal's current layout, used when the
        /// header text cannot be matched.
        var fallbackIndex: Int {
            switch self {
            case .totalRecharge: return 2
            case .rebate: return 3
            case .electricityTaka: return 4
            case .meterRent: return 5
            case .demandCharge: return 6
            case .pfc: return 7
            case .arrears: return 8
            case .vat: return 9
            case .totalDeducted: return 10
            case .endBalance: return 11
            case .units: return 12
            }
        }
    }

    private static func monthlyRows(in table: String) -> [NescoMonthlyUsage] {
        let headers = (table.firstCapture(pattern: #"<thead[^>]*>([\s\S]*?)</thead>"#) ?? "")
            .allCaptures(pattern: #"<th[^>]*>([\s\S]*?)</th>"#)
            .map { stripTags($0) }

        var columnIndex: [MonthlyColumn: Int] = [:]
        for column in MonthlyColumn.allCases {
            if let index = headers.firstIndex(where: { matches($0, column.pattern) }) {
                columnIndex[column] = index
            } else if headers.isEmpty {
                columnIndex[column] = column.fallbackIndex
            }
        }

        var rows: [NescoMonthlyUsage] = []

        for rowHTML in table.allCaptures(pattern: #"<tr[^>]*>([\s\S]*?)</tr>"#) {
            let cells = rowHTML.allCaptures(pattern: #"<td[^>]*>([\s\S]*?)</td>"#).map { stripTags($0) }
            guard cells.count >= 4 else { continue }

            var month: String?
            var year: String?
            for cell in cells {
                if month == nil { month = monthNumber(from: cell) }
                if year == nil,
                   cell.trimmingCharacters(in: .whitespaces).range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil {
                    year = cell.trimmingCharacters(in: .whitespaces)
                }
            }
            guard let month, let year else { continue }

            func value(_ column: MonthlyColumn) -> Double? {
                guard let index = columnIndex[column] ?? (headers.isEmpty ? column.fallbackIndex : nil),
                      index < cells.count else { return nil }
                return number(cells[index])
            }

            rows.append(
                NescoMonthlyUsage(
                    month: "\(year)-\(month)",
                    unit: value(.units),
                    electricityTaka: value(.electricityTaka),
                    totalRecharge: value(.totalRecharge),
                    rebate: value(.rebate),
                    meterRent: value(.meterRent),
                    demandCharge: value(.demandCharge),
                    pfc: value(.pfc),
                    arrears: value(.arrears),
                    vat: value(.vat),
                    totalDeducted: value(.totalDeducted),
                    endBalance: value(.endBalance)
                )
            )
        }

        return rows
    }

    private static let monthNames: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7,
        "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
        "জানুয়ারি": 1, "ফেব্রুয়ারি": 2, "মার্চ": 3, "এপ্রিল": 4, "মে": 5, "জুন": 6,
        "জুলাই": 7, "আগস্ট": 8, "সেপ্টেম্বর": 9, "অক্টোবর": 10, "নভেম্বর": 11, "ডিসেম্বর": 12
    ]

    private static func monthNumber(from cell: String) -> String? {
        let value = canonical(cell.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if value.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
            return String(value.suffix(2))
        }
        // Longest first, so "september" is not shadowed by "sep".
        for (name, month) in monthNames.sorted(by: { $0.key.count > $1.key.count })
        where value.contains(canonical(name)) {
            return String(format: "%02d", month)
        }
        return nil
    }

    // MARK: - Not-found detection

    static func looksLikeAccountNotFound(_ html: String) -> Bool {
        let text = stripTags(html)
        let patterns = [
            #"কোনো\s*তথ্য\s*পাওয়া\s*যায়নি"#,
            #"তথ্য\s*পাওয়া\s*যায়নি"#,
            #"no\s+(?:data|customer)\s+found"#,
            #"invalid\s+customer"#
        ]
        return patterns.contains { matches(text, $0) }
    }

    // MARK: - Helpers

    static func inputValues(in html: String) -> [String] {
        html.allMatches(pattern: #"<input\b[^>]*>"#).compactMap { tag in
            guard let value = tag.firstCapture(pattern: #"value\s*=\s*["']([^"']*)["']"#) else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func dataAttribute(_ tag: String, _ name: String) -> String? {
        tag.firstCapture(pattern: "data-\(name)\\s*=\\s*[\"']([^\"']*)[\"']")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// NESCO prints figures with thousands separators and stray currency marks.
    static func number(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: #"[^\d.\-]"#, with: "", options: .regularExpression)
        guard !cleaned.isEmpty, cleaned != "-", cleaned != "." else { return nil }
        return Double(cleaned)
    }

    /// Puts Bengali text into one canonical form before it is matched.
    ///
    /// Several Bengali letters have two equally valid encodings — য় is either
    /// U+09DF or য + a nukta — and the portal uses the precomposed form while a
    /// Swift source literal typically carries the decomposed one. They look
    /// identical and compare unequal, so every pattern and every piece of text
    /// is passed through here first.
    static func canonical(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// Case-insensitive regex test with both sides canonicalised.
    static func matches(_ text: String, _ pattern: String) -> Bool {
        canonical(text).range(
            of: canonical(pattern),
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func stripTags(_ html: String) -> String {
        var text = html
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<[^>]*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Portal dates, in Dhaka time.
    ///
    /// The recharge rows use `08-NOV-2026 12:59 PM` — an upper-cased month
    /// abbreviation and a single-digit hour. `DateFormatter` will not match an
    /// upper-cased month against `MMM`, so the month is title-cased first. The
    /// other formats are kept for the fields that use them.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let text = normalizeMonthCase(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return nil }

        let formats = [
            "dd-MMM-yyyy h:mm a",       // 03-Nov-2026 2:22 PM
            "dd-MMM-yyyy hh:mm a",      // 08-Nov-2026 12:59 PM
            "dd-MMM-yyyy HH:mm",
            "dd-MMM-yyyy",
            "dd/MM/yyyy HH:mm:ss",
            "dd/MM/yyyy",
            "dd-MM-yyyy",
            "d MMMM yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Dhaka")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// `08-NOV-2026` becomes `08-Nov-2026`.
    private static func normalizeMonthCase(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Z]{3})\b"#) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        var result = text
        // Replace back to front so earlier ranges stay valid.
        for match in regex.matches(in: text, range: range).reversed() {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let token = String(text[matchRange])
            guard monthAbbreviations.contains(token) else { continue }
            result.replaceSubrange(matchRange, with: token.prefix(1) + token.dropFirst().lowercased())
        }
        return result
    }

    private static let monthAbbreviations: Set<String> = [
        "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"
    ]
}

// MARK: - Regex conveniences

extension String {
    /// First capture group of the first match, or nil.
    func firstCapture(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[captureRange])
    }

    /// First capture group of every match.
    func allCaptures(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: self) else { return nil }
            return String(self[captureRange])
        }
    }

    /// Whole text of every match.
    func allMatches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: self) else { return nil }
            return String(self[matchRange])
        }
    }
}
