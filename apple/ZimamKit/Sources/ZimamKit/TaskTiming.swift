import Foundation

/// When in its day a task falls: all day, at a clock time, or around a prayer. The three are
/// exclusive: a clock time clears the prayer and a prayer clears the clock time.
public enum TaskTimeMode: Equatable, Sendable {
    case allDay
    /// "HH:mm", local.
    case clock(String)
    case prayer(Prayer, offsetMinutes: Int)

    public init(dueTime: String?, prayer: Prayer?, offsetMinutes: Int?) {
        if let prayer {
            self = .prayer(prayer, offsetMinutes: offsetMinutes ?? 0)
        } else if let dueTime, TaskTiming.clockParts(dueTime) != nil {
            self = .clock(dueTime)
        } else {
            self = .allDay
        }
    }

    public var isAllDay: Bool { self == .allDay }

    public var prayer: Prayer? {
        if case .prayer(let prayer, _) = self { return prayer }
        return nil
    }
}

/// Resolves a task's time to an instant on a given day. A prayer-anchored task moves with
/// the prayer through the year, so its time on a day a month away is that day's prayer time,
/// computed the same way as today's.
public enum TaskTiming {
    /// The hour a reminder relative to an all-day task counts from: «قبل يوم» is 9 a.m. the day
    /// before. The server uses the same hour (`ALL_DAY_HOUR` in api/src/push/reminders.ts).
    public static let allDayHour = 9

    /// "21:30" as hour and minute; nil when it is not a time.
    public static func clockParts(_ hhmm: String) -> (hour: Int, minute: Int)? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// The API's "HH:mm" for a date's clock time in `timeZone`.
    public static func clockString(from date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The task's time on `day` ("2026-11-20"), or nil when it needs prayer times and there is no
    /// place. An all-day task resolves to `allDayHour`, the time its relative reminders count from.
    public static func time(of mode: TaskTimeMode, on day: String, schedule: PrayerSchedule?,
                            formatter: DualDateFormatter) -> Date? {
        guard let start = formatter.date(fromDay: day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        switch mode {
        case .allDay:
            return calendar.date(bySettingHour: allDayHour, minute: 0, second: 0, of: start)
        case .clock(let hhmm):
            guard let parts = clockParts(hhmm) else { return nil }
            return calendar.date(bySettingHour: parts.hour, minute: parts.minute, second: 0, of: start)
        case .prayer(let prayer, let offset):
            // Noon of the day: clear of daylight-saving edges.
            return schedule?.time(of: prayer, on: start.addingTimeInterval(12 * 3600), offsetMinutes: offset)
        }
    }

    /// A usual time for each prayer, in minutes after midnight: close enough to order a day's tasks
    /// by when there is no place (the web's `USUAL_PRAYER_MINUTE` in lib/calendar.js).
    public static func usualMinute(of prayer: Prayer) -> Int {
        switch prayer {
        case .fajr: 5 * 60
        case .dhuhr: 12 * 60
        case .asr: 15 * 60
        case .maghrib: 18 * 60
        case .isha: 19 * 60 + 30
        }
    }

    /// Minutes after midnight, to order a day's tasks: nil all day, the clock time, or the prayer's
    /// time with its offset. `prayerTimes` are the day's (`PrayerSchedule.times(on:)`), passed in so a
    /// day's list solves them once; without them a prayer takes its usual time.
    public static func minuteOfDay(_ mode: TaskTimeMode, prayerTimes: [Prayer: Date]?, timeZone: TimeZone) -> Int? {
        switch mode {
        case .allDay:
            return nil
        case .clock(let hhmm):
            return clockParts(hhmm).map { $0.hour * 60 + $0.minute }
        case .prayer(let prayer, let offset):
            guard let time = prayerTimes?[prayer] else { return usualMinute(of: prayer) + offset }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: time.addingTimeInterval(TimeInterval(offset * 60)))
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    /// The same on `day` ("2026-11-20"), solving that day's prayer times when the task needs them.
    public static func minuteOfDay(_ mode: TaskTimeMode, on day: String?, schedule: PrayerSchedule?,
                                   formatter: DualDateFormatter) -> Int? {
        let times: [Prayer: Date]? = mode.prayer == nil ? nil : day
            .flatMap(formatter.date(fromDay:))
            .flatMap { start in schedule?.times(on: start.addingTimeInterval(12 * 3600)) }
        return minuteOfDay(mode, prayerTimes: times, timeZone: formatter.timeZone)
    }

    /// The clock time to show for a task with a time: on its due day, or today when it has none
    /// (a prayer-anchored task without a day repeats every day). Nil for an all-day task.
    public static func shownTime(of mode: TaskTimeMode, dueDay: String?, schedule: PrayerSchedule?,
                                 formatter: DualDateFormatter, now: Date = Date()) -> Date? {
        if mode.isAllDay { return nil }
        return time(of: mode, on: dueDay ?? formatter.dayString(from: now), schedule: schedule, formatter: formatter)
    }
}

/// Text for a reminder relative to its task's time.
public enum RelativeReminderPhrase {
    /// The offsets offered when adding one, in minutes before the task's time.
    public static let presets = [0, -5, -15, -30, -60, -1440]

    /// «عند الموعد», «قبل ١٥ د», «قبل ساعة», «قبل ساعتين», «قبل يوم», «قبل يومين».
    public static func text(_ offsetMinutes: Int, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        if offsetMinutes == 0 { return "عند الموعد" }
        let direction = offsetMinutes < 0 ? "قبل" : "بعد"
        return "\(direction) \(duration(abs(offsetMinutes), locale: locale))"
    }

    static func duration(_ minutes: Int, locale: Locale) -> String {
        let number = { (n: Int) in n.formatted(.number.locale(locale).grouping(.never)) }
        if minutes % 1440 == 0 {
            switch minutes / 1440 {
            case 1: return "يوم"
            case 2: return "يومين"
            default: return "\(number(minutes / 1440)) أيام"
            }
        }
        if minutes % 60 == 0 {
            switch minutes / 60 {
            case 1: return "ساعة"
            case 2: return "ساعتين"
            default: return "\(number(minutes / 60)) س"
            }
        }
        return "\(number(minutes)) د"
    }
}
