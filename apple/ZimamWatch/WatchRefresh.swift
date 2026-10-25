import Foundation
import WatchKit

/// Keeps the complications current while the watch app is closed. Only the app can reach the
/// API (the token is its own), so watchOS wakes it now and then in the background
/// (`.backgroundTask(.appRefresh)` in `ZimamWatchApp`): it asks for today's tasks again, which
/// saves a new snapshot when something changed on another device, and after midnight one for
/// the new day.
enum WatchRefresh {
    /// On watchOS, SwiftUI matches the scheduled refresh to `.appRefresh(identifier)` by this
    /// string, passed as its `userInfo`.
    static let identifier = "app.zimam.watch.refresh"

    /// Asks to be woken in half an hour, or just after midnight when that comes first. A watch
    /// face with a Zimam complication gets regular wakes; watchOS decides when.
    static func schedule() {
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let date = min(now.addingTimeInterval(30 * 60), midnight.addingTimeInterval(60))
        // A @Sendable closure, not tied to the main actor: WatchKit may call it back on another
        // thread, where a main-actor closure would stop the app. A refused request is tried
        // again at the next launch or wake.
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: identifier as NSString) { @Sendable _ in }
    }

    /// One wake: the next is asked for first, so a refresh that fails is tried again then.
    static func run() async {
        schedule()
        await WatchModel.shared.refresh()
    }
}
