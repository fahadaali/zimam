import Foundation

extension CalendarKind {
    /// The calendar shown beside this one.
    public var other: CalendarKind { self == .hijri ? .gregorian : .hijri }

    /// The Foundation calendar: Umm al-Qura for Hijri.
    public var identifier: Calendar.Identifier { self == .hijri ? .islamicUmmAlQura : .gregorian }

    /// Written right after a year: «١٤٤٨هـ», «٢٠٢٦م».
    public var yearSuffix: String { self == .hijri ? "هـ" : "م" }
}

/// One cell of a calendar grid. Days are keyed by the API's local Gregorian day ("2026-10-13"),
/// whichever calendar the grid is laid out in.
public struct CalendarDay: Hashable, Sendable, Identifiable {
    /// The local day as the API stores it: "2026-10-13".
    public let day: String
    /// The start of that day in the grid's time zone.
    public let date: Date
    /// The day of the month in the grid's calendar (the large number).
    public let primaryDay: Int
    /// The day of the month in the other calendar (the small number).
    public let secondaryDay: Int
    /// False for the padding days that fill the first and last weeks of a month grid.
    public let isInPeriod: Bool

    public var id: String { day }
}

/// The days of a month or a week, laid out in weeks of seven, in Hijri (Umm al-Qura) or Gregorian.
/// Pure date logic for the calendar screen: no formatting, no UI.
public struct CalendarGrid: Sendable {
    /// The calendar the grid is laid out in; the other one gives each cell its small number.
    public var kind: CalendarKind
    /// The first column: 1 = Sunday … 7 = Saturday, as `Calendar.firstWeekday`.
    public var firstWeekday: Int
    public var timeZone: TimeZone

    public init(kind: CalendarKind = .hijri, firstWeekday: Int = 1, timeZone: TimeZone = .current) {
        self.kind = kind
        self.firstWeekday = (1...7).contains(firstWeekday) ? firstWeekday : 1
        self.timeZone = timeZone
    }

    /// The grid's calendar, in its time zone, starting weeks on `firstWeekday`.
    public var calendar: Calendar { Self.makeCalendar(kind, timeZone: timeZone, firstWeekday: firstWeekday) }

    /// The other calendar, for the small day numbers.
    public var otherCalendar: Calendar { Self.makeCalendar(kind.other, timeZone: timeZone, firstWeekday: firstWeekday) }

    /// The weekday of each column, leading column first (1 = Sunday … 7 = Saturday).
    public var weekdayOrder: [Int] {
        (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
    }

    // MARK: Months

    /// The first day of the month (in the grid's calendar) that contains `date`.
    public func startOfMonth(containing date: Date) -> Date {
        let calendar = self.calendar
        return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// How many days the month containing `date` has: 29 or 30 in Hijri, 28 to 31 in Gregorian.
    public func numberOfDays(inMonthContaining date: Date) -> Int {
        let calendar = self.calendar
        guard let month = calendar.dateInterval(of: .month, for: date) else { return 30 }
        return calendar.dateComponents([.day], from: month.start, to: month.end).day ?? 30
    }

    /// Empty cells before the month's first day, so it falls under its weekday.
    public func leadingPadding(forMonthContaining date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: startOfMonth(containing: date))
        return (weekday - firstWeekday + 7) % 7
    }

    /// Empty cells after the month's last day, to complete its last week.
    public func trailingPadding(forMonthContaining date: Date) -> Int {
        let used = leadingPadding(forMonthContaining: date) + numberOfDays(inMonthContaining: date)
        return (7 - used % 7) % 7
    }

    /// The month containing `date` in whole weeks: the padding days of the months before and
    /// after (`isInPeriod == false`), then the month's days, then padding again. Always a
    /// multiple of seven, in column order.
    public func monthDays(containing date: Date) -> [CalendarDay] {
        let start = startOfMonth(containing: date)
        let count = numberOfDays(inMonthContaining: date)
        let leading = leadingPadding(forMonthContaining: date)
        let trailing = trailingPadding(forMonthContaining: date)
        return (-leading ..< count + trailing).compactMap { offset in
            day(offset, from: start, inPeriod: (0..<count).contains(offset))
        }
    }

    /// The same day of the month `months` months away; the last day when that month is shorter.
    public func addingMonths(_ months: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: months, to: date) ?? date
    }

    // MARK: Weeks

    /// The seven days of the week containing `date`, starting on `firstWeekday`.
    public func weekDays(containing date: Date) -> [CalendarDay] {
        let calendar = self.calendar
        let start = calendar.startOfDay(for: date)
        let back = (calendar.component(.weekday, from: start) - firstWeekday + 7) % 7
        return (0..<7).compactMap { day($0 - back, from: start, inPeriod: true) }
    }

    /// `days` days later (or earlier when negative).
    public func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    // MARK: Days

    /// The API's local day string for a date: "2026-10-13".
    public func dayString(from date: Date) -> String {
        DualDateFormatter(timeZone: timeZone).dayString(from: date)
    }

    /// The start of an API day ("2026-10-13") in the grid's time zone.
    public func date(fromDay day: String) -> Date? {
        DualDateFormatter(timeZone: timeZone).date(fromDay: day)
    }

    private func day(_ offset: Int, from start: Date, inPeriod: Bool) -> CalendarDay? {
        let calendar = self.calendar
        guard let moved = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
        let date = calendar.startOfDay(for: moved)
        return CalendarDay(day: dayString(from: date), date: date,
                           primaryDay: calendar.component(.day, from: date),
                           secondaryDay: otherCalendar.component(.day, from: date),
                           isInPeriod: inPeriod)
    }

    private static func makeCalendar(_ kind: CalendarKind, timeZone: TimeZone, firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday
        return calendar
    }
}

// MARK: Calendar titles

extension DualDateFormatter {
    /// A month grid's title: the month in `kind` with its year, then the months of the other
    /// calendar it spans, separated by the Arabic comma.
    /// «جمادى الأولى ١٤٤٨هـ، أكتوبر – نوفمبر ٢٠٢٦م», «أكتوبر ٢٠٢٦م، ربيع الآخر – جمادى الأولى ١٤٤٨هـ».
    public func monthTitle(_ date: Date, in kind: CalendarKind) -> String {
        let calendar = Self.makeCalendar(kind, timeZone: timeZone)
        guard let month = calendar.dateInterval(of: .month, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: month.end) else { return "" }
        return "\(monthYear(month.start, in: kind))، \(monthSpan(from: month.start, to: last, in: kind.other))"
    }

    /// A span of days in both calendars, `kind` first:
    /// «٧ – ١٣ جمادى الأولى ١٤٤٨هـ، ١٨ – ٢٤ أكتوبر ٢٠٢٦م».
    public func rangeTitle(from start: Date, to end: Date, in kind: CalendarKind) -> String {
        "\(daySpan(from: start, to: end, in: kind))، \(daySpan(from: start, to: end, in: kind.other))"
    }

    /// The weekday's name: «الثلاثاء».
    public func weekday(_ date: Date) -> String {
        part(date, in: .gregorian, pattern: "EEEE")
    }

    /// Weekday names in column order (1 = Sunday … 7 = Saturday): «ح», «ن»… when `short`,
    /// the full names otherwise.
    public func weekdaySymbols(_ order: [Int], short: Bool) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = short ? calendar.veryShortWeekdaySymbols : calendar.weekdaySymbols
        return order.map { symbols[($0 - 1 + 7) % 7] }
    }

    /// A number in the locale's digits, ungrouped: «١٤٤٨».
    public func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale).grouping(.never))
    }

    /// «جمادى الأولى ١٤٤٨هـ».
    func monthYear(_ date: Date, in kind: CalendarKind) -> String {
        "\(part(date, in: kind, pattern: "MMMM")) \(part(date, in: kind, pattern: "y"))\(kind.yearSuffix)"
    }

    /// «أكتوبر ٢٠٢٦م», «أكتوبر – نوفمبر ٢٠٢٦م», «ديسمبر ٢٠٢٦م – يناير ٢٠٢٧م».
    func monthSpan(from start: Date, to end: Date, in kind: CalendarKind) -> String {
        let calendar = Self.makeCalendar(kind, timeZone: timeZone)
        let a = calendar.dateComponents([.year, .month], from: start)
        let b = calendar.dateComponents([.year, .month], from: end)
        if a == b { return monthYear(start, in: kind) }
        if a.year == b.year {
            return "\(part(start, in: kind, pattern: "MMMM")) – \(monthYear(end, in: kind))"
        }
        return "\(monthYear(start, in: kind)) – \(monthYear(end, in: kind))"
    }

    /// «١٨ – ٢٤ أكتوبر ٢٠٢٦م», «٣٠ ربيع الآخر – ٦ جمادى الأولى ١٤٤٨هـ», across years with both years.
    func daySpan(from start: Date, to end: Date, in kind: CalendarKind) -> String {
        let calendar = Self.makeCalendar(kind, timeZone: timeZone)
        let a = calendar.dateComponents([.year, .month], from: start)
        let b = calendar.dateComponents([.year, .month], from: end)
        let endText = "\(part(end, in: kind, pattern: "d MMMM y"))\(kind.yearSuffix)"
        if a == b {
            return "\(part(start, in: kind, pattern: "d")) – \(endText)"
        }
        if a.year == b.year {
            return "\(part(start, in: kind, pattern: "d MMMM")) – \(endText)"
        }
        return "\(part(start, in: kind, pattern: "d MMMM y"))\(kind.yearSuffix) – \(endText)"
    }

    private func part(_ date: Date, in kind: CalendarKind, pattern: String) -> String {
        DateFormatterCache.string(from: date, calendar: kind.identifier, locale: locale, timeZone: timeZone, pattern: pattern)
    }

    private static func makeCalendar(_ kind: CalendarKind, timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.timeZone = timeZone
        return calendar
    }
}
