import Foundation

/// Which calendar a user sees first. The other one is always shown beside it.
public enum CalendarKind: String, Codable, Sendable {
    case hijri, gregorian
}

/// Formats dates the Zimam way: Hijri (Umm al-Qura) and Gregorian together,
/// separated by the Arabic comma, with Arabic-Indic digits from the locale,
/// and one word for nearby days.
public struct DualDateFormatter {
    public var primary: CalendarKind
    public var locale: Locale
    public var timeZone: TimeZone

    public init(primary: CalendarKind = .hijri, locale: Locale = Locale(identifier: "ar-SA"), timeZone: TimeZone = .current) {
        self.primary = primary
        self.locale = locale
        self.timeZone = timeZone
    }

    /// «٢ جمادى الأولى» or «٢ جمادى الأولى ١٤٤٨».
    public func hijri(_ date: Date, withYear: Bool = false) -> String {
        format(date, calendar: .islamicUmmAlQura, pattern: withYear ? "d MMMM y" : "d MMMM")
    }

    /// «١٣ أكتوبر» or «١٣ أكتوبر ٢٠٢٦».
    public func gregorian(_ date: Date, withYear: Bool = false) -> String {
        format(date, calendar: .gregorian, pattern: withYear ? "d MMMM y" : "d MMMM")
    }

    /// Both calendars, the user's primary first: «٢ جمادى الأولى، ١٣ أكتوبر».
    public func dual(_ date: Date, withYear: Bool = false) -> String {
        let parts = [hijri(date, withYear: withYear), gregorian(date, withYear: withYear)]
        return (primary == .hijri ? parts : parts.reversed()).joined(separator: "، ")
    }

    /// The clock time in the user's locale: «٣:٠٠ م».
    public func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// «اليوم», «غداً», «أمس», or the weekday for the coming week; nil further out.
    public func relativeWord(for date: Date, now: Date = Date()) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "اليوم"
        case 1: return "غداً"
        case -1: return "أمس"
        case 2...6: return format(date, calendar: .gregorian, pattern: "EEEE")
        default: return nil
        }
    }

    /// The label for a due date: a word when close, both calendars otherwise.
    public func label(for date: Date, now: Date = Date()) -> String {
        relativeWord(for: date, now: now) ?? dual(date)
    }

    /// Parses the API's local `dueDate` ("2026-10-15") as the start of that day.
    public func date(fromDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The API's local day string for a date.
    public func dayString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func format(_ date: Date, calendar identifier: Calendar.Identifier, pattern: String) -> String {
        let formatter = DateFormatter()
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Text for a prayer-anchored time, as the prayer chip shows it.
public enum PrayerPhrase {
    /// «بعد العصر بـ٢٠ د», «قبل المغرب بـ١٠ د», «عند الفجر», «بعد الظهر بساعة».
    public static func text(_ prayer: Prayer, offsetMinutes: Int?, locale: Locale = Locale(identifier: "ar-SA")) -> String {
        let offset = offsetMinutes ?? 0
        if offset == 0 { return "عند \(prayer.arabicName)" }
        let direction = offset > 0 ? "بعد" : "قبل"
        return "\(direction) \(prayer.arabicName) \(duration(abs(offset), locale: locale))"
    }

    static func duration(_ minutes: Int, locale: Locale) -> String {
        let number = { (n: Int) in n.formatted(.number.locale(locale).grouping(.never)) }
        if minutes % 60 == 0 {
            switch minutes / 60 {
            case 1: return "بساعة"
            case 2: return "بساعتين"
            default: return "بـ\(number(minutes / 60)) س"
            }
        }
        return "بـ\(number(minutes)) د"
    }
}
