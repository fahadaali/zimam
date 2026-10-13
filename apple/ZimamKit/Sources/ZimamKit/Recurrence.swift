import Foundation

/// A day of the week, numbered as `Calendar` numbers them (1 = Sunday).
public enum Weekday: Int, CaseIterable, Codable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    /// The two-letter code RFC 5545 uses in `BYDAY`.
    public var code: String {
        switch self {
        case .sunday: "SU"
        case .monday: "MO"
        case .tuesday: "TU"
        case .wednesday: "WE"
        case .thursday: "TH"
        case .friday: "FR"
        case .saturday: "SA"
        }
    }

    public init?(code: String) {
        guard let day = Weekday.allCases.first(where: { $0.code == code.uppercased() }) else { return nil }
        self = day
    }

    public var arabicName: String {
        switch self {
        case .sunday: "الأحد"
        case .monday: "الإثنين"
        case .tuesday: "الثلاثاء"
        case .wednesday: "الأربعاء"
        case .thursday: "الخميس"
        case .friday: "الجمعة"
        case .saturday: "السبت"
        }
    }
}

/// The subset of an RFC 5545 RRULE that Zimam understands:
/// `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `BYDAY` (weekly only, `MO`..`SU`),
/// `COUNT` and `UNTIL`. Days are the API's local day strings ("2026-10-15").
///
/// Each new occurrence is a new task, so `COUNT` here means the occurrences left
/// including the current one: the next task carries `COUNT - 1`, and a task
/// with `COUNT=1` is the last.
public struct Recurrence: Equatable, Sendable {
    public enum Frequency: String, CaseIterable, Sendable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    }

    public var frequency: Frequency
    /// 1 or more: every `interval` days, weeks, months or years.
    public var interval: Int
    /// Weekly only; empty means the weekday of the current occurrence. Kept sorted from Sunday.
    public var weekdays: [Weekday]
    public var count: Int?
    /// The last day an occurrence may fall on, "yyyy-MM-dd".
    public var until: String?

    public init(frequency: Frequency, interval: Int = 1, weekdays: [Weekday] = [], count: Int? = nil, until: String? = nil) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = Recurrence.normalized(weekdays)
        self.count = count
        self.until = until
    }

    /// Parses "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH", with or without a leading "RRULE:".
    /// Returns nil for a frequency or value Zimam does not support.
    public init?(rrule: String) {
        var text = rrule.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("RRULE:") { text = String(text.dropFirst(6)) }
        var frequency: Frequency?
        var interval = 1
        var weekdays: [Weekday] = []
        var count: Int?
        var until: String?
        for part in text.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { String($0) }
            guard pair.count == 2 else { return nil }
            let key = pair[0].uppercased()
            let value = pair[1]
            switch key {
            case "FREQ":
                guard let parsed = Frequency(rawValue: value.uppercased()) else { return nil }
                frequency = parsed
            case "INTERVAL":
                guard let parsed = Int(value), parsed >= 1 else { return nil }
                interval = parsed
            case "BYDAY":
                var days: [Weekday] = []
                for code in value.split(separator: ",") {
                    guard let day = Weekday(code: String(code)) else { return nil }
                    days.append(day)
                }
                weekdays = days
            case "COUNT":
                guard let parsed = Int(value), parsed >= 1 else { return nil }
                count = parsed
            case "UNTIL":
                guard let parsed = Recurrence.dayString(fromUntil: value) else { return nil }
                until = parsed
            default:
                continue // WKST and the like do not change the days Zimam computes.
            }
        }
        guard let frequency else { return nil }
        self.init(frequency: frequency, interval: interval,
                  weekdays: frequency == .weekly ? weekdays : [], count: count, until: until)
    }

    /// The rule as the API stores it: "FREQ=WEEKLY;BYDAY=MO,TH".
    public var rrule: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if frequency == .weekly && !weekdays.isEmpty {
            parts.append("BYDAY=" + weekdays.map(\.code).joined(separator: ","))
        }
        if let count { parts.append("COUNT=\(count)") }
        if let until { parts.append("UNTIL=" + until.replacingOccurrences(of: "-", with: "")) }
        return parts.joined(separator: ";")
    }

    // MARK: Next occurrence

    /// The day of the occurrence that follows `day`, or nil when the series ends.
    public func nextDay(after day: String, timeZone: TimeZone) -> String? {
        if let count, count <= 1 { return nil }
        let calendar = Recurrence.calendar(timeZone)
        guard let start = Recurrence.noon(of: day, calendar: calendar) else { return nil }
        let next: Date?
        switch frequency {
        case .daily:
            next = calendar.date(byAdding: .day, value: interval, to: start)
        case .weekly:
            next = nextWeekly(after: start, calendar: calendar)
        case .monthly:
            next = calendar.date(byAdding: .month, value: interval, to: start)
        case .yearly:
            next = calendar.date(byAdding: .year, value: interval, to: start)
        }
        guard let next else { return nil }
        let result = Recurrence.dayString(next, calendar: calendar)
        if let until, result > until { return nil }
        return result
    }

    /// The rule the next occurrence carries: one fewer occurrence left when `COUNT` is set.
    public var afterOneOccurrence: Recurrence {
        var copy = self
        if let count { copy.count = max(1, count - 1) }
        return copy
    }

    /// The next occurrence after `day`, skipping any that fall before `notBefore`
    /// (completing an overdue task schedules the next one from today, not in the past).
    public func nextOccurrence(after day: String, notBefore: String? = nil, timeZone: TimeZone) -> (day: String, rule: Recurrence)? {
        var rule = self
        var current = day
        for _ in 0..<1000 {
            guard let next = rule.nextDay(after: current, timeZone: timeZone) else { return nil }
            rule = rule.afterOneOccurrence
            if let notBefore, next < notBefore {
                current = next
                continue
            }
            return (day: next, rule: rule)
        }
        return nil
    }

    private func nextWeekly(after start: Date, calendar: Calendar) -> Date? {
        guard !weekdays.isEmpty else {
            return calendar.date(byAdding: .day, value: 7 * interval, to: start)
        }
        let wanted = Set(weekdays.map(\.rawValue))
        let startWeek = Recurrence.mondayOfWeek(start, calendar: calendar)
        for offset in 1...(7 * interval + 7) {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            guard wanted.contains(calendar.component(.weekday, from: candidate)) else { continue }
            let week = Recurrence.mondayOfWeek(candidate, calendar: calendar)
            let days = calendar.dateComponents([.day], from: startWeek, to: week).day ?? 0
            if (days / 7) % interval == 0 { return candidate }
        }
        return nil
    }

    // MARK: Arabic text

    /// «كل يوم»، «كل ٣ أيام»، «كل أسبوع يوم الخميس»، «كل شهر»، «كل سنة».
    public func arabicDescription(locale: Locale = Locale(identifier: "ar-SA")) -> String {
        let number = { (n: Int) in n.formatted(.number.locale(locale).grouping(.never)) }
        switch frequency {
        case .daily:
            return "كل " + Recurrence.counted(interval, one: "يوم", two: "يومين", few: "أيام", many: "يوماً", number: number)
        case .weekly:
            if interval == 1 && weekdays.count == 7 { return "كل يوم" }
            let base = "كل " + Recurrence.counted(interval, one: "أسبوع", two: "أسبوعين", few: "أسابيع", many: "أسبوعاً", number: number)
            let names = weekdays.map(\.arabicName)
            switch names.count {
            case 0: return base
            case 1: return "\(base) يوم \(names[0])"
            case 2: return "\(base) يومي \(names[0]) و\(names[1])"
            default: return "\(base) أيام " + names.joined(separator: " و")
            }
        case .monthly:
            return "كل " + Recurrence.counted(interval, one: "شهر", two: "شهرين", few: "أشهر", many: "شهراً", number: number)
        case .yearly:
            return "كل " + Recurrence.counted(interval, one: "سنة", two: "سنتين", few: "سنوات", many: "سنة", number: number)
        }
    }

    /// Arabic number agreement: «يوم»، «يومين»، «٣ أيام»، «١١ يوماً».
    private static func counted(_ n: Int, one: String, two: String, few: String, many: String, number: (Int) -> String) -> String {
        switch n {
        case 1: return one
        case 2: return two
        case 3...10: return "\(number(n)) \(few)"
        default: return "\(number(n)) \(many)"
        }
    }

    // MARK: Days

    private static func normalized(_ days: [Weekday]) -> [Weekday] {
        Array(Set(days)).sorted { $0.rawValue < $1.rawValue }
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Noon keeps day arithmetic clear of daylight-saving shifts.
    private static func noon(of day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// RFC 5545 weeks start on Monday unless WKST says otherwise.
    private static func mondayOfWeek(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        let sinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -sinceMonday, to: date) ?? date
    }

    /// "20261231" or "20261231T235959Z" → "2026-12-31".
    private static func dayString(fromUntil value: String) -> String? {
        let digits = Array(value.prefix(8))
        guard digits.count == 8, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let text = String(digits)
        return "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))"
    }
}
