import AppIntents
import WidgetKit
import Foundation

/// The refresh button on the widget.
///
/// Without it, a stale widget means unlocking the phone, finding the app,
/// waiting for a sync and going back — for a number that takes two seconds to
/// fetch. With it, the Home Screen is the whole interaction.
///
/// The widget cannot reach the portal itself, so this marks the shared state as
/// refreshing and asks the app to do the work at its next opportunity; the
/// timeline reloads either way, so the button always feels like it did
/// something.
struct RefreshMeterIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh meter balance"

    /// Opening the app is what actually gets a live reading, and it is what the
    /// user wanted anyway when they reached for a stale widget.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        SharedStore.markRefreshRequested()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
