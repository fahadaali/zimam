import Foundation

/// What the Lock Screen widgets (iPhone) and the watch complications show: today's open
/// tasks in brief, how many are open and how many are done.
///
/// On the iPhone the widget builds it from the shared store at each timeline reload. On the
/// watch there is no local store, so the watch app writes it to the watch's own App Group
/// (`GlanceStore`) after each refresh, completion and addition, and the complications read it.
struct GlanceSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: UUID
        var title: String
        /// «بعد العصر بـ٢٠ د» for a task tied to a prayer.
        var prayerText: String?
        /// When it falls today, if known: its time, or its prayer's time where the place is known.
        var time: Date?
        /// Due on an earlier day.
        var isOverdue: Bool
    }

    var isSignedIn: Bool
    /// The user's primary calendar, `CalendarKind.rawValue` ("hijri" or "gregorian").
    var calendar: String
    /// The API day this was made for ("2026-10-15").
    var day: String
    /// Today's open top-level tasks (due today or overdue).
    var openCount: Int
    /// Top-level tasks due today and already done.
    var doneCount: Int
    /// The first open tasks, in the Today screen's order. A few are enough to pick the next one.
    var items: [Item]

    static let maxItems = 8

    static func signedOut(day: String) -> GlanceSnapshot {
        GlanceSnapshot(isSignedIn: false, calendar: "hijri", day: day, openCount: 0, doneCount: 0, items: [])
    }

    /// For previews and the widget gallery.
    static let placeholder = GlanceSnapshot(
        isSignedIn: true, calendar: "hijri", day: "", openCount: 3, doneCount: 2,
        items: [
            Item(id: UUID(), title: "مراجعة العقد", prayerText: "بعد العصر بـ٢٠ د", time: nil, isOverdue: false),
            Item(id: UUID(), title: "الاتصال بالوالدة", prayerText: nil, time: nil, isOverdue: false),
        ]
    )

    /// The task to show as «التالي»: the soonest one with a time still ahead today, otherwise
    /// the first open task (overdue ones come first in the Today order).
    func next(at date: Date) -> Item? {
        let ahead = items.filter { item in
            guard let time = item.time else { return false }
            return time > date
        }
        if let soonest = ahead.min(by: { ($0.time ?? date) < ($1.time ?? date) }) {
            return soonest
        }
        return items.first
    }

    /// Share of today's tasks done, 0...1. A day with nothing on it counts as complete.
    var progress: Double {
        let total = openCount + doneCount
        return total == 0 ? 1 : Double(doneCount) / Double(total)
    }

    /// The moments the next task changes today, for the widget timeline.
    func changeTimes(after date: Date, before end: Date) -> [Date] {
        let times = Set(items.compactMap(\.time).filter { $0 > date && $0 < end })
        return Array(times.sorted().prefix(10))
    }

    /// The snapshot as it reads on `day`. One saved on an earlier day still lists open tasks
    /// (now overdue), but its times belonged to that day, so they are dropped.
    func reading(on day: String) -> GlanceSnapshot {
        guard isSignedIn, day != self.day else { return self }
        var copy = self
        copy.day = day
        copy.doneCount = 0
        copy.items = items.map { item in
            var moved = item
            moved.time = nil
            moved.isOverdue = true
            return moved
        }
        return copy
    }
}

/// The watch's own App Group, shared by the watch app and its complications. The iPhone's
/// group does not reach the watch (another device), so this is a separate one.
/// Register it in the developer account (see docs/setup.md).
enum GlanceStore {
    static let watchAppGroup = "group.app.zimam.ios.watch"
    private static let key = "glance.snapshot"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: watchAppGroup) }

    static func read() -> GlanceSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GlanceSnapshot.self, from: data)
    }

    /// Saves the snapshot; returns whether it changed, so callers reload the timelines only then.
    @discardableResult
    static func write(_ snapshot: GlanceSnapshot) -> Bool {
        guard let defaults else { return false }
        if read() == snapshot { return false }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}

extension GlanceSnapshot {
    /// "HH:mm" on the API day `day` (Gregorian, whatever calendar the system uses), in the
    /// device's time zone.
    static func time(_ hhmm: String?, onDay day: String, timeZone: TimeZone = .current) -> Date? {
        guard let hhmm else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = hhmm.split(separator: ":").compactMap { Int($0) }
        let date = day.split(separator: "-").compactMap { Int($0) }
        guard clock.count >= 2, date.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: date[0], month: date[1], day: date[2], hour: clock[0], minute: clock[1]))
    }
}
