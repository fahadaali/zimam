import Foundation

/// How far through its year a day is: the Hijri year (Umm al-Qura, 354 or 355 days) or the
/// Gregorian year (365 or 366), month by month. For the «تقدّم السنة» widget; no formatting.
///
/// Days are whole local days: today is not yet behind, so on the year's first day nothing has
/// passed and every day is left, and on its last day one day is left.
public struct YearProgress: Equatable, Sendable {
    public struct Month: Equatable, Sendable, Identifiable {
        /// 1…12 in the year's calendar.
        public let number: Int
        /// The month's first day, at the start of the day.
        public let start: Date
        /// 29 or 30 in Hijri, 28 to 31 in Gregorian.
        public let days: Int
        /// Days of the month already behind, 0…`days`.
        public let passedDays: Int
        /// The month that contains the day.
        public let isCurrent: Bool

        public var id: Int { number }

        /// Share of the month behind: 1 for months gone, 0 for months ahead, part of the current one.
        public var filled: Double { days == 0 ? 0 : Double(passedDays) / Double(days) }
    }

    public let kind: CalendarKind
    /// 1448 or 2026.
    public let year: Int
    /// The year's first day.
    public let start: Date
    /// The next year's first day.
    public let end: Date
    public let totalDays: Int
    /// Whole days of the year before the day.
    public let elapsedDays: Int
    public let months: [Month]

    /// Days left in the year, the day itself included.
    public var remainingDays: Int { totalDays - elapsedDays }

    /// Share of the year behind, 0…1.
    public var fraction: Double { totalDays == 0 ? 0 : Double(elapsedDays) / Double(totalDays) }

    /// The year containing `date` in `kind`, in `timeZone`.
    public init(kind: CalendarKind, date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: date)
        let interval = calendar.dateInterval(of: .year, for: today)
            ?? DateInterval(start: today, duration: 365 * 86_400)

        self.kind = kind
        year = calendar.component(.year, from: today)
        start = interval.start
        end = interval.end
        totalDays = Self.days(from: interval.start, to: interval.end, in: calendar)
        elapsedDays = Self.days(from: interval.start, to: today, in: calendar)

        var months: [Month] = []
        var monthStart = interval.start
        var number = 1
        while monthStart < interval.end, number <= 13 {
            let next = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? interval.end
            let days = Self.days(from: monthStart, to: next, in: calendar)
            let passed = min(max(Self.days(from: monthStart, to: today, in: calendar), 0), days)
            months.append(Month(number: calendar.component(.month, from: monthStart), start: monthStart, days: days,
                                passedDays: passed, isCurrent: today >= monthStart && today < next))
            monthStart = next
            number += 1
        }
        self.months = months
    }

    /// The month that contains the day.
    public var currentMonth: Month? { months.first(where: \.isCurrent) }

    private static func days(from start: Date, to end: Date, in calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}
