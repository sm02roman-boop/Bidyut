import ActivityKit
import WidgetKit
import SwiftUI

/// The Lock Screen and Dynamic Island faces of the countdown.
///
/// Everything here is already-computed state. The widget process does no work
/// beyond drawing, which is what keeps a Live Activity cheap enough to leave
/// running for two days.
struct MeterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeterActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.meterName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(Formatters.takaShort(context.state.balance))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(tint(context.state))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Formatters.days(context.state.daysRemaining))
                            .font(.subheadline.weight(.semibold))
                        Text(Formatters.taka(context.state.dailyBurn) + " / " + L10n.callAttention("day", "দিন"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    cutoffLine(context)
                }
            } compactLeading: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(tint(context.state))
            } compactTrailing: {
                Text(Formatters.takaShort(context.state.balance))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint(context.state))
            } minimal: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(tint(context.state))
            }
        }
    }

    // MARK: - Lock Screen

    private func lockScreen(_ context: ActivityViewContext<MeterActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.meterName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Formatters.taka(context.state.balance))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(tint(context.state))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Formatters.days(context.state.daysRemaining))
                        .font(.headline)
                    Text(Formatters.taka(context.state.dailyBurn) + " / " + L10n.callAttention("day", "দিন"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            cutoffLine(context)

            if context.state.onEmergencyCredit {
                Label(
                    L10n.callAttention("Emergency credit in use", "জরুরি ব্যালেন্স চলছে"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
            }
        }
        .padding(16)
    }

    /// The line that does the work: not when the balance empties, but when the
    /// power could actually stop.
    private func cutoffLine(_ context: ActivityViewContext<MeterActivityAttributes>) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.callAttention("Supply safe until", "লাইন নিরাপদ"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(context.state.cutoffAt, style: .relative)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func tint(_ state: MeterActivityAttributes.ContentState) -> Color {
        if state.balance <= 0 { return .red }
        switch state.daysRemaining {
        case ..<1: return .red
        case ..<2: return .orange
        default: return .primary
        }
    }
}
