import WidgetKit
import SwiftUI
import AppIntents

/// Home Screen and Lock Screen widgets.
///
/// The widget never opens the database. The app writes a small summary into the
/// shared App Group container after each sync, and the widget reads only that —
/// which keeps the widget process cheap and avoids two processes contending for
/// the same store.
struct BidyutWidget: Widget {
    let kind = "BidyutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BalanceProvider()) { entry in
            BalanceWidgetView(state: entry.state)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Meter balance")
        .description("Your NESCO prepaid balance and how long it should last.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}

struct BalanceEntry: TimelineEntry {
    let date: Date
    let state: SharedStore.WidgetState
}

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry {
        BalanceEntry(date: Date(), state: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        completion(BalanceEntry(date: Date(), state: SharedStore.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        let state = SharedStore.read() ?? .placeholder
        let entry = BalanceEntry(date: Date(), state: state)

        // The widget cannot fetch — only the app can reach the portal — so it
        // simply re-reads the shared file periodically. A low balance is worth
        // refreshing more often, because the days-left figure is then changing
        // fast enough to matter.
        let refreshInterval: TimeInterval = state.isRunningLow ? 1_800 : 3_600
        let next = Date(timeIntervalSinceNow: refreshInterval)

        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct BalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let state: SharedStore.WidgetState

    private var status: Theme.Status {
        .from(daysRemaining: state.daysRemaining, balance: state.balance)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(Formatters.takaShort(state.balance)) · \(Formatters.days(state.daysRemaining))")

        case .accessoryCircular:
            Gauge(value: gaugeFraction) {
                Image(systemName: "bolt.fill")
            } currentValueLabel: {
                Text(Formatters.takaShort(state.balance).replacingOccurrences(of: "৳", with: ""))
                    .minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircularCapacity)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(state.meterName)
                    .font(.caption2)
                    .widgetAccentable()
                Text(Formatters.takaShort(state.balance))
                    .font(.headline)
                Text(state.daysRemaining.map { "~\(Formatters.days($0)) left" } ?? "No forecast yet")
                    .font(.caption2)
            }

        case .systemMedium:
            HStack(spacing: 16) {
                balanceBlock
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    detail("Days left", state.daysRemaining.map { Formatters.days($0) } ?? "—")
                    detail("Per day", Formatters.takaShort(state.dailyBurn))
                    detail("Runs out", state.depletionDate.map { Formatters.dayMonth($0) } ?? "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        default:
            balanceBlock
        }
    }

    private var balanceBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: status.symbol)
                Text(state.meterName)
                    .lineLimit(1)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.color)

            Text(Formatters.takaShort(state.balance))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            if let days = state.daysRemaining {
                Text("~\(Formatters.days(days)) \(L10n.callAttention("left", "বাকি"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.callAttention("Open to sync", "আপডেট করতে খুলুন"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text(Formatters.relative(state.lastSyncedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                // Tappable straight from the Home Screen, so a stale figure
                // costs one tap rather than a trip through the app.
                Button(intent: RefreshMeterIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }

    /// Full gauge at 30 days of runway, which is roughly one recharge cycle.
    private var gaugeFraction: Double {
        guard let days = state.daysRemaining else { return 0 }
        return min(max(days / 30, 0), 1)
    }
}

@main
struct BidyutWidgetBundle: WidgetBundle {
    var body: some Widget {
        BidyutWidget()
        MeterLiveActivity()
    }
}
