import Foundation
import Testing
@testable import ZimamKit

struct YearProgressTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!

    /// Midday of an API day in Riyadh.
    private func on(_ day: String) -> Date {
        DualDateFormatter(timeZone: riyadh).date(fromDay: day)!.addingTimeInterval(12 * 3600)
    }

    private func day(_ date: Date) -> String {
        DualDateFormatter(timeZone: riyadh).dayString(from: date)
    }

    // MARK: Gregorian

    @Test func gregorianYear() {
        // 9 October 2026 is the 282nd day: 281 days behind, 84 left with today.
        let progress = YearProgress(kind: .gregorian, date: on("2026-10-09"), timeZone: riyadh)
        #expect(progress.year == 2026)
        #expect(progress.totalDays == 365)
        #expect(progress.elapsedDays == 281)
        #expect(progress.remainingDays == 84)
        #expect(abs(progress.fraction - (281.0 / 365.0)) <= 0.000_1)
        #expect(day(progress.start) == "2026-01-01")
        #expect(day(progress.end) == "2027-01-01")
    }

    @Test func gregorianMonthsFill() {
        let progress = YearProgress(kind: .gregorian, date: on("2026-10-09"), timeZone: riyadh)
        #expect(progress.months.count == 12)
        #expect(progress.months.map(\.number) == Array(1...12))
        #expect(progress.months.map(\.days) == [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])
        #expect(progress.months[0..<9].allSatisfy { $0.filled == 1 && !$0.isCurrent })
        let october = progress.months[9]
        #expect(october.isCurrent)
        #expect(october.passedDays == 8)
        #expect(abs(october.filled - (8.0 / 31.0)) <= 0.000_1)
        #expect(progress.currentMonth?.number == 10)
        #expect(progress.months[10...].allSatisfy { $0.filled == 0 && !$0.isCurrent })
    }

    @Test func gregorianLeapYearAndEdges() {
        let leap = YearProgress(kind: .gregorian, date: on("2024-03-01"), timeZone: riyadh)
        #expect(leap.totalDays == 366)
        #expect(leap.months[1].days == 29)
        #expect(leap.elapsedDays == (31 + 29))

        let first = YearProgress(kind: .gregorian, date: on("2026-01-01"), timeZone: riyadh)
        #expect(first.elapsedDays == 0)
        #expect(first.remainingDays == 365)
        #expect(first.fraction == 0)
        #expect(first.months[0].filled == 0)
        #expect(first.months[0].isCurrent)

        let last = YearProgress(kind: .gregorian, date: on("2026-12-31"), timeZone: riyadh)
        #expect(last.remainingDays == 1)
        #expect(last.months[11].passedDays == 30)
    }

    @Test func dayBoundaryFollowsTimeZone() {
        // 23:30 on 31 December in Riyadh is still the old year there, but the new one in Tokyo.
        let lateEvening = DualDateFormatter(timeZone: riyadh).date(fromDay: "2026-12-31")!.addingTimeInterval(23.5 * 3600)
        #expect(YearProgress(kind: .gregorian, date: lateEvening, timeZone: riyadh).year == 2026)
        #expect(YearProgress(kind: .gregorian, date: lateEvening, timeZone: TimeZone(identifier: "Asia/Tokyo")!).year == 2027)
    }

    // MARK: Hijri (Umm al-Qura)

    @Test func hijriYear() {
        // 1448 runs from 16 June 2026 to 5 June 2027: 355 days.
        // 13 October 2026 is 2 Jumada al-Ula, 119 days in.
        let progress = YearProgress(kind: .hijri, date: on("2026-10-13"), timeZone: riyadh)
        #expect(progress.year == 1448)
        #expect(progress.totalDays == 355)
        #expect(day(progress.start) == "2026-06-16")
        #expect(day(progress.end) == "2027-06-06")
        #expect(progress.elapsedDays == 119)
        #expect(progress.remainingDays == 236)
    }

    @Test func hijriMonths() {
        let progress = YearProgress(kind: .hijri, date: on("2026-10-13"), timeZone: riyadh)
        #expect(progress.months.count == 12)
        #expect(progress.months.map(\.days) == [29, 30, 29, 30, 30, 29, 30, 30, 29, 30, 29, 30])
        #expect(progress.months.map(\.days).reduce(0, +) == progress.totalDays)
        #expect(progress.months[0..<4].allSatisfy { $0.filled == 1 })
        let jumada = progress.months[4]
        #expect(jumada.isCurrent)
        #expect(jumada.number == 5)
        #expect(day(jumada.start) == "2026-10-12")
        #expect(jumada.passedDays == 1)
        #expect(progress.months[5...].allSatisfy { $0.passedDays == 0 })
    }

    @Test func hijriYearOf354Days() {
        // 1449 (6 June 2027 to 24 May 2028).
        let progress = YearProgress(kind: .hijri, date: on("2027-12-01"), timeZone: riyadh)
        #expect(progress.year == 1449)
        #expect(progress.totalDays == 354)
        #expect(day(progress.start) == "2027-06-06")
    }

    // MARK: Texts

    @Test func widgetTitles() {
        let formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
        let parts = formatter.monthTitleParts(on("2026-10-13"), in: .hijri)
        #expect(parts.primary == "جمادى الأولى ١٤٤٨هـ")
        #expect(parts.other == "أكتوبر – نوفمبر ٢٠٢٦م")
        #expect("\(parts.primary)، \(parts.other)" == formatter.monthTitle(on("2026-10-13"), in: .hijri))
        #expect(formatter.monthName(on("2026-10-13"), in: .gregorian) == "أكتوبر")
        #expect(formatter.yearTitle(on("2026-10-13"), in: .hijri) == "١٤٤٨هـ")
        #expect(formatter.yearTitle(on("2026-10-13"), in: .gregorian) == "٢٠٢٦م")
    }

    @Test func arabicDayCounts() {
        let ar = Locale(identifier: "ar-SA")
        #expect(ArabicDays.count(1, locale: ar) == "يوم واحد")
        #expect(ArabicDays.count(2, locale: ar) == "يومان")
        #expect(ArabicDays.count(3, locale: ar) == "٣ أيام")
        #expect(ArabicDays.count(10, locale: ar) == "١٠ أيام")
        #expect(ArabicDays.count(84, locale: ar) == "٨٤ يوماً")
        #expect(ArabicDays.count(100, locale: ar) == "١٠٠ يوم")
        #expect(ArabicDays.count(102, locale: ar) == "١٠٢ يوم")
        #expect(ArabicDays.count(236, locale: ar) == "٢٣٦ يوماً")
        #expect(ArabicDays.count(305, locale: ar) == "٣٠٥ أيام")
    }
}
