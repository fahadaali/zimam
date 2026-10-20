import SwiftUI
import ZimamKit

/// Links from the widgets (`AppLink`): `zimam://task/<id>` opens the task through `TaskOpener`,
/// like Siri and Spotlight; `zimam://today`, `zimam://calendar` and `zimam://day/<day>` go to
/// that place through `PlaceOpener`. Kept until the main screen exists, so a cold launch (or
/// signing in first) still arrives there.
enum AppLinks {
    /// Takes the URL if it is one of the widget links; false leaves it to other handlers.
    @MainActor
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let link = AppLink(url: url) else { return false }
        switch link {
        case .task(let id):
            TaskOpener.shared.pending = id
        case .today, .calendar, .day, .prayer:
            PlaceOpener.shared.pending = link
        }
        return true
    }
}

/// The place a widget link asked for. `MainView` switches to «اليوم» or «التقويم» and clears it,
/// except for a day, which `CalendarView` selects and then clears, and «أوقات الصلاة», which
/// `TodayView` opens and then clears.
@MainActor
@Observable
final class PlaceOpener {
    static let shared = PlaceOpener()

    var pending: AppLink?

    private init() {}

    /// The day a link asked the calendar to show, if that is what is pending.
    var pendingDay: String? {
        if case .day(let day) = pending { return day }
        return nil
    }
}
