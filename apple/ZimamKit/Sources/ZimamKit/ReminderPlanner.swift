import Foundation

/// What the planner needs to know about a task.
public struct PlannerTask: Sendable {
    public var id: UUID
    public var title: String
    /// Local day, "2026-10-15".
    public var dueDay: String?
    public var duePrayer: Prayer?
    public var duePrayerOffset: Int?
    public var isDone: Bool

    public init(id: UUID, title: String, dueDay: String? = nil, duePrayer: Prayer? = nil, duePrayerOffset: Int? = nil,
                isDone: Bool = false) {
        self.id = id
        self.title = title
        self.dueDay = dueDay
        self.duePrayer = duePrayer
        self.duePrayerOffset = duePrayerOffset
        self.isDone = isDone
    }
}

/// What the planner needs to know about a reminder.
public struct PlannerReminder: Sendable {
    public var id: UUID
    public var taskId: UUID
    public var kind: ReminderRecord.Kind
    /// ISO 8601 with offset, for `.time`.
    public var at: String?
    public var prayer: Prayer?
    public var offsetMinutes: Int?
    /// For `.location`; its place is watched by `PlaceWatchPlanner` or `LocationReminderPlanner`.
    /// With `at` too, this planner schedules the time, which competes with the place.
    public var location: ReminderRecord.Location?
    /// When the place came first, for a `.location` reminder with a time.
    public var firedAt: Milliseconds?

    public init(id: UUID, taskId: UUID, kind: ReminderRecord.Kind, at: String? = nil, prayer: Prayer? = nil,
                offsetMinutes: Int? = nil, location: ReminderRecord.Location? = nil, firedAt: Milliseconds? = nil) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.at = at
        self.prayer = prayer
        self.offsetMinutes = offsetMinutes
        self.location = location
        self.firedAt = firedAt
    }

    /// Where a `.location` reminder stands: every visit, waiting for the place or the time, or done.
    public func firing(now: Date) -> ReminderFiring {
        ReminderFiring(at: at.flatMap(ReminderPlanner.date(fromISO:)), firedAt: firedAt, now: now)
    }
}

/// One local notification to schedule.
public struct PlannedNotification: Equatable, Sendable {
    /// Stable across runs, so rescheduling replaces rather than duplicates.
    public let id: String
    public let taskId: UUID
    public let date: Date
    public let title: String
    public let body: String

    public init(id: String, taskId: UUID, date: Date, title: String, body: String) {
        self.id = id
        self.taskId = taskId
        self.date = date
        self.title = title
        self.body = body
    }
}

/// Chooses the local notifications to schedule. iOS keeps at most 64 per app,
/// so this returns the soonest ones in a rolling window; the app recomputes the
/// window after every change and on launch.
///
/// - A time reminder fires at its time.
/// - A prayer reminder, and a task anchored to a prayer, fire at that prayer
///   (plus the offset) on the task's due day, or every day when it has none.
/// - A location reminder's place is not planned here but by `PlaceWatchPlanner` (or, without
///   «دائماً», `LocationReminderPlanner`, which takes some of the same budget). Its time, when it
///   has one and the place has not come first, is planned here under the same id, so the device
///   that arrives first can take it back (`PlaceMonitor`).
public enum ReminderPlanner {
    public static let defaultLimit = 60
    /// The server pushes what fires beyond this window after the device's last pull
    /// (`LOCAL_WINDOW_MS` in api/src/push/reminders.ts). Change both together.
    public static let windowDays = 14

    public static func plan(
        tasks: [PlannerTask],
        reminders: [PlannerReminder],
        schedule: PrayerSchedule?,
        now: Date,
        formatter: DualDateFormatter,
        limit: Int = defaultLimit
    ) -> [PlannedNotification] {
        let end = now.addingTimeInterval(TimeInterval(windowDays) * 86_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let today = calendar.startOfDay(for: now)
        // Noon of each day in the window: clear of daylight-saving edges.
        var noons: [Date] = []
        for offset in 0...windowDays {
            if let start = calendar.date(byAdding: .day, value: offset, to: today) {
                noons.append(start.addingTimeInterval(12 * 3600))
            }
        }

        var openTasks: [UUID: PlannerTask] = [:]
        for task in tasks where !task.isDone { openTasks[task.id] = task }

        var planned: [PlannedNotification] = []

        func consider(_ notification: PlannedNotification) {
            if notification.date > now && notification.date <= end { planned.append(notification) }
        }

        func anchored(_ task: PlannerTask, prayer: Prayer, offset: Int, idPrefix: String) {
            guard let schedule else { return }
            let body = PrayerPhrase.text(prayer, offsetMinutes: offset, locale: formatter.locale)
            if let dueDay = task.dueDay {
                guard let start = formatter.date(fromDay: dueDay) else { return }
                guard let time = schedule.time(of: prayer, on: start.addingTimeInterval(12 * 3600), offsetMinutes: offset) else { return }
                consider(PlannedNotification(id: "\(idPrefix)@\(dueDay)", taskId: task.id, date: time, title: task.title, body: body))
            } else {
                for noon in noons {
                    guard let time = schedule.time(of: prayer, on: noon, offsetMinutes: offset) else { continue }
                    let day = formatter.dayString(from: noon)
                    consider(PlannedNotification(id: "\(idPrefix)@\(day)", taskId: task.id, date: time, title: task.title, body: body))
                }
            }
        }

        for task in openTasks.values {
            if let prayer = task.duePrayer {
                anchored(task, prayer: prayer, offset: task.duePrayerOffset ?? 0, idPrefix: "task-\(task.id.uuidString)")
            }
        }

        for reminder in reminders {
            guard let task = openTasks[reminder.taskId] else { continue }
            switch reminder.kind {
            case .time:
                guard let at = reminder.at, let fireDate = ReminderPlanner.date(fromISO: at) else { continue }
                consider(PlannedNotification(id: "reminder-\(reminder.id.uuidString)", taskId: task.id, date: fireDate,
                                             title: task.title,
                                             body: ReminderPlanner.timeBody(task, firing: fireDate, formatter: formatter)))
            case .prayer:
                guard let prayer = reminder.prayer else { continue }
                anchored(task, prayer: prayer, offset: reminder.offsetMinutes ?? 0, idPrefix: "reminder-\(reminder.id.uuidString)")
            case .location:
                guard case .waiting(let fireDate) = reminder.firing(now: now), let place = reminder.location else { continue }
                consider(PlannedNotification(id: "reminder-\(reminder.id.uuidString)", taskId: task.id, date: fireDate,
                                             title: task.title,
                                             body: LocationReminderPlanner.timeCameFirstBody(place)))
            }
        }

        planned.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }

        // One notification per task per minute, even if a reminder repeats the task's own anchor.
        var seen = Set<String>()
        var result: [PlannedNotification] = []
        for notification in planned {
            let key = "\(notification.taskId.uuidString)|\(Int(notification.date.timeIntervalSince1970 / 60))"
            if seen.insert(key).inserted { result.append(notification) }
            if result.count >= limit { break }
        }
        return result
    }

    /// «موعدها غداً», or a plain line for a task with no due day.
    static func timeBody(_ task: PlannerTask, firing date: Date, formatter: DualDateFormatter) -> String {
        guard let dueDay = task.dueDay, let due = formatter.date(fromDay: dueDay) else { return "تذكير بمهمتك" }
        return "موعدها \(formatter.label(for: due, now: date))"
    }

    // MARK: ISO 8601

    /// The API's reminder time: "2026-10-13T15:00:00+03:00".
    public static func isoString(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Reads an ISO 8601 date-time with an offset, with or without fractional seconds.
    public static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
