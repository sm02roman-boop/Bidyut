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

    /// Frosted glass: the material blurs whatever sits behind a card, so the
    /// backdrop below has to carry colour for the effect to show.
    static let cardBackground: Material = .ultraThinMaterial
    static let cornerRadius: CGFloat = 16

    /// A dark, colour-rich backdrop with soft glows, which the glass cards refract.
    struct GlassBackdrop: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.04, green: 0.05, blue: 0.14), Color(red: 0.09, green: 0.04, blue: 0.24), Color(red: 0.02, green: 0.13, blue: 0.16)]
                        : [Color(red: 0.86, green: 0.91, blue: 1.0), Color(red: 0.93, green: 0.88, blue: 1.0), Color(red: 0.84, green: 0.97, blue: 0.96)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(red: 0.11, green: 0.44, blue: 0.85).opacity(colorScheme == .dark ? 0.55 : 0.35))
                    .frame(width: 320, height: 320)
                    .blur(radius: 60)
                    .offset(x: -120, y: -260)
                Circle()
                    .fill(Color(red: 0.71, green: 0.27, blue: 0.23).opacity(colorScheme == .dark ? 0.35 : 0.2))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: 140, y: 80)
                Circle()
                    .fill(Color(red: 0.09, green: 0.50, blue: 0.48).opacity(colorScheme == .dark ? 0.4 : 0.25))
                    .frame(width: 280, height: 280)
                    .blur(radius: 60)
                    .offset(x: -100, y: 360)
            }
            .ignoresSafeArea()
        }
    }
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
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.45), .white.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
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
