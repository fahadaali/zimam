import Foundation
import Observation

/// The day the screens sort by: «اليوم», «القادم», the calendar, the matrix, the timeline, the
/// sidebar's count and the task row's date chip read `now` here instead of `Date()`, so they draw
/// again when the day turns over with the app open (a window left overnight), and on a change of
/// time zone or clock. Nothing else redraws: what is open or typed stays as it is, and the
/// calendar's selection moves only when it was on today.
@MainActor
@Observable
final class DayClock {
    static let shared = DayClock()

    /// The time the day was last read; it moves only when the day does.
    private(set) var now = Date()
    /// The zone the day is read in. RootView builds the screens' date formatter with it, so a
    /// change of zone moves their «اليوم» as well as `now`.
    private(set) var timeZone = TimeZone.current

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(force: true) }
            })
        }
    }

    /// Reads the day again. A suspended iPhone app misses the midnight notification, so the
    /// app calls this on every return; `now` changes only on a new day, so the screens draw
    /// once a day rather than on every return.
    func refresh(force: Bool = false) {
        let date = Date()
        if force || !Calendar.current.isDate(date, inSameDayAs: now) { now = date }
        let zone = TimeZone.current
        if zone != timeZone { timeZone = zone }
    }
}
