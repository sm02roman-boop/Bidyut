import SwiftUI

/// A small palette, built so the balance colour alone tells the user whether to
/// act. Everything else stays quiet.
enum Theme {

    static let accent = Color("AccentColor", bundle: .main)

    /// Status colours for the balance, by how much runway is left.
    enum Status {
        case healthy, warning, critical, unknown

        var color: Color {
            switch self {
            case .healthy: return Color(red: 0.13, green: 0.68, blue: 0.42)
            case .warning: return Color(red: 0.93, green: 0.65, blue: 0.14)
            case .critical: return Color(red: 0.86, green: 0.25, blue: 0.24)
            case .unknown: return Color.secondary
            }
        }

        var label: String {
            switch self {
            case .healthy: return L10n.healthy
            case .warning: return L10n.runningLow
            case .critical: return L10n.rechargeNow
            case .unknown: return L10n.notEnoughData
            }
        }

        var symbol: String {
            switch self {
            case .healthy: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "bolt.slash.fill"
            case .unknown: return "questionmark.circle"
            }
        }

        /// Days remaining is the better signal than a bare taka figure, because
        /// what counts as "low" depends entirely on how fast the meter runs.
        static func from(daysRemaining: Double?, balance: Double?) -> Status {
            if let balance, balance <= 0 { return .critical }
            guard let daysRemaining else {
                guard let balance else { return .unknown }
                return balance < 100 ? .critical : .unknown
            }
            switch daysRemaining {
            case ..<3: return .critical
            case 3..<7: return .warning
            default: return .healthy
            }
        }
    }

    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let pageBackground = Color(.systemGroupedBackground)
    static let cornerRadius: CGFloat = 16
}

/// A plain card used throughout the dashboard.
struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// One label-and-value pair, used in rows of two or three.
struct StatTile: View {
    var label: String
    var value: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
