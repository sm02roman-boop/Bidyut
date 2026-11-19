import Foundation

/// The bridge between the app and its widget.
///
/// The widget runs in a separate process and must not open the SwiftData store,
/// so the app writes a small summary into the shared App Group container after
/// every sync and the widget only ever reads that.
enum SharedStore {

    /// The App Group this project asks for.
    ///
    /// Not necessarily the one it gets: see `appGroupID`.
    static let requestedAppGroupID = "group.com.codeyo.bidyut"

    /// The App Group actually granted to this build.
    ///
    /// Sideloadly, AltStore and SideStore re-sign with a free Apple ID by
    /// *remapping* the requested group to a team-unique identifier, because a
    /// personal team cannot be granted an arbitrary group name. The entitlement
    /// baked into the signature therefore says something like
    /// `group.ABC123.com.codeyo.bidyut`, and asking for the name in source
    /// would miss it — the widget would read an empty container and show
    /// nothing, with no error anywhere to explain why.
    ///
    /// So the granted name is read from the bundle's own provisioning profile.
    /// The app and the widget each read their own, and because the re-signer
    /// remaps both the same way, they land on the same group.
    static let appGroupID: String = grantedAppGroupID() ?? requestedAppGroupID

    /// Groups this bundle's signature actually grants, newest signature first.
    private static func grantedAppGroupID() -> String? {
        guard let entitlements = provisioningEntitlements(),
              let groups = entitlements["com.apple.security.application-groups"] as? [String],
              !groups.isEmpty
        else { return nil }

        // A remapped name keeps the original as a suffix, so prefer the group
        // that still looks like ours before falling back to the only one there.
        let tail = requestedAppGroupID.replacingOccurrences(of: "group.", with: "")
        return groups.first { $0.hasSuffix(tail) } ?? groups.first
    }

    /// Reads the entitlements dictionary out of `embedded.mobileprovision`.
    ///
    /// The file is a CMS-signed blob with a plain XML property list inside it,
    /// so the plist is located by its own delimiters rather than by decoding
    /// the signature — which needs no crypto and cannot fail on a format change
    /// in the parts we do not read.
    private static func provisioningEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return nil }

        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8))
        else { return nil }

        let plistData = data[start.lowerBound..<end.upperBound]
        guard let profile = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) as? [String: Any] else { return nil }

        return profile["Entitlements"] as? [String: Any]
    }

    private static let fileName = "widget-state.json"

    struct WidgetState: Codable, Equatable {
        var meterName: String
        var customerNumber: String
        var balance: Double?
        var dailyBurn: Double?
        var daysRemaining: Double?
        var depletionDate: Date?
        var lastSyncedAt: Date?
        var isRunningLow: Bool

        static let placeholder = WidgetState(
            meterName: "Home",
            customerNumber: "12345678",
            balance: 842.50,
            dailyBurn: 63.20,
            daysRemaining: 13.3,
            depletionDate: Date().addingTimeInterval(13.3 * 86_400),
            lastSyncedAt: Date(),
            isRunningLow: false
        )
    }

    /// Whether this build can actually reach the App Group.
    ///
    /// A free Apple ID cannot sign the App Groups entitlement, so a
    /// personal-team build has no group container. Everything here degrades to
    /// the app's own sandbox instead of failing: the widget and Live Activity
    /// then cannot see the data, but the app itself works normally.
    static var hasAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    static func write(_ state: WidgetState) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Refresh handshake

    /// The widget cannot reach the portal, so its refresh button leaves a note
    /// here and the app picks it up when it next opens.
    private static let refreshKey = "widget.refreshRequestedAt"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func markRefreshRequested() {
        defaults.set(Date().timeIntervalSince1970, forKey: refreshKey)
    }

    /// True once, if a refresh was asked for in the last few minutes.
    ///
    /// Consuming the flag stops an old tap from forcing a sync days later.
    static func consumeRefreshRequest() -> Bool {
        let stamp = defaults.double(forKey: refreshKey)
        guard stamp > 0 else { return false }

        defaults.removeObject(forKey: refreshKey)
        return Date().timeIntervalSince1970 - stamp < 300
    }

    static func read() -> WidgetState? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetState.self, from: data)
    }
}
