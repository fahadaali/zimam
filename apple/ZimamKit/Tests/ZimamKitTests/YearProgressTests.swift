import XCTest
@testable import ZimamKit

final class YearProgressTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!

    /// Midday of an API day in Riyadh.
    private func on(_ day: String) -> Date {
        DualDateFormatter(timeZone: riyadh).date(fromDay: day)!.addingTimeInterval(12 * 3600)
    }

    private func day(_ date: Date) -> String {
        DualDateFormatter(timeZone: riyadh).dayString(from: date)
    }

    // MARK: Gregorian

    func testGregorianYear() {
        // 9 October 2026 is the 282nd day: 281 days behind, 84 left with today.
        let progress = YearProgress(kind: .gregorian, date: on("2026-10-09"), timeZone: riyadh)
        XCTAssertEqual(progress.year, 2026)
        XCTAssertEqual(progress.totalDays, 365)
        XCTAssertEqual(progress.elapsedDays, 281)
        XCTAssertEqual(progress.remainingDays, 84)
        XCTAssertEqual(progress.fraction, 281.0 / 365.0, accuracy: 0.000_1)
        XCTAssertEqual(day(progress.start), "2026-01-01")
        XCTAssertEqual(day(progress.end), "2027-01-01")
    }

    func testGregorianMonthsFill() {
        let progress = YearProgress(kind: .gregorian, date: on("2026-10-09"), timeZone: riyadh)
        XCTAssertEqual(progress.months.count, 12)
        XCTAssertEqual(progress.months.map(\.number), Array(1...12))
        XCTAssertEqual(progress.months.map(\.days), [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])
        XCTAssertTrue(progress.months[0..<9].allSatisfy { $0.filled == 1 && !$0.isCurrent })
        let october = progress.months[9]
        XCTAssertTrue(october.isCurrent)
        XCTAssertEqual(october.passedDays, 8)
        XCTAssertEqual(october.filled, 8.0 / 31.0, accuracy: 0.000_1)
        XCTAssertEqual(progress.currentMonth?.number, 10)
        XCTAssertTrue(progress.months[10...].allSatisfy { $0.filled == 0 && !$0.isCurrent })
    }

    func testGregorianLeapYearAndEdges() {
        let leap = YearProgress(kind: .gregorian, date: on("2024-03-01"), timeZone: riyadh)
        XCTAssertEqual(leap.totalDays, 366)
        XCTAssertEqual(leap.months[1].days, 29)
        XCTAssertEqual(leap.elapsedDays, 31 + 29)

        let first = YearProgress(kind: .gregorian, date: on("2026-01-01"), timeZone: riyadh)
        XCTAssertEqual(first.elapsedDays, 0)
        XCTAssertEqual(first.remainingDays, 365)
        XCTAssertEqual(first.fraction, 0)
        XCTAssertEqual(first.months[0].filled, 0)
        XCTAssertTrue(first.months[0].isCurrent)

        let last = YearProgress(kind: .gregorian, date: on("2026-12-31"), timeZone: riyadh)
        XCTAssertEqual(last.remainingDays, 1)
        XCTAssertEqual(last.months[11].passedDays, 30)
    }

    func testDayBoundaryFollowsTimeZone() {
        // 23:30 on 31 December in Riyadh is still the old year there, but the new one in Tokyo.
        let lateEvening = DualDateFormatter(timeZone: riyadh).date(fromDay: "2026-12-31")!.addingTimeInterval(23.5 * 3600)
        XCTAssertEqual(YearProgress(kind: .gregorian, date: lateEvening, timeZone: riyadh).year, 2026)
        XCTAssertEqual(YearProgress(kind: .gregorian, date: lateEvening, timeZone: TimeZone(identifier: "Asia/Tokyo")!).year, 2027)
    }

    // MARK: Hijri (Umm al-Qura)

    func testHijriYear() {
        // 1448 runs from 16 June 2026 to 5 June 2027: 355 days.
        // 13 October 2026 is 2 Jumada al-Ula, 119 days in.
        let progress = YearProgress(kind: .hijri, date: on("2026-10-13"), timeZone: riyadh)
        XCTAssertEqual(progress.year, 1448)
        XCTAssertEqual(progress.totalDays, 355)
        XCTAssertEqual(day(progress.start), "2026-06-16")
        XCTAssertEqual(day(progress.end), "2027-06-06")
        XCTAssertEqual(progress.elapsedDays, 119)
        XCTAssertEqual(progress.remainingDays, 236)
    }

    func testHijriMonths() {
        let progress = YearProgress(kind: .hijri, date: on("2026-10-13"), timeZone: riyadh)
        XCTAssertEqual(progress.months.count, 12)
        XCTAssertEqual(progress.months.map(\.days), [29, 30, 29, 30, 30, 29, 30, 30, 29, 30, 29, 30])
        XCTAssertEqual(progress.months.map(\.days).reduce(0, +), progress.totalDays)
        XCTAssertTrue(progress.months[0..<4].allSatisfy { $0.filled == 1 })
        let jumada = progress.months[4]
        XCTAssertTrue(jumada.isCurrent)
        XCTAssertEqual(jumada.number, 5)
        XCTAssertEqual(day(jumada.start), "2026-10-12")
        XCTAssertEqual(jumada.passedDays, 1)
        XCTAssertTrue(progress.months[5...].allSatisfy { $0.passedDays == 0 })
    }

    func testHijriYearOf354Days() {
        // 1449 (6 June 2027 to 24 May 2028).
        let progress = YearProgress(kind: .hijri, date: on("2027-12-01"), timeZone: riyadh)
        XCTAssertEqual(progress.year, 1449)
        XCTAssertEqual(progress.totalDays, 354)
        XCTAssertEqual(day(progress.start), "2027-06-06")
    }

    // MARK: Texts

    func testWidgetTitles() {
        let formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
        let parts = formatter.monthTitleParts(on("2026-10-13"), in: .hijri)
        XCTAssertEqual(parts.primary, "جمادى الأولى ١٤٤٨هـ")
        XCTAssertEqual(parts.other, "أكتوبر – نوفمبر ٢٠٢٦م")
        XCTAssertEqual("\(parts.primary)، \(parts.other)", formatter.monthTitle(on("2026-10-13"), in: .hijri))
        XCTAssertEqual(formatter.monthName(on("2026-10-13"), in: .gregorian), "أكتوبر")
        XCTAssertEqual(formatter.yearTitle(on("2026-10-13"), in: .hijri), "١٤٤٨هـ")
        XCTAssertEqual(formatter.yearTitle(on("2026-10-13"), in: .gregorian), "٢٠٢٦م")
    }

    func testArabicDayCounts() {
        let ar = Locale(identifier: "ar-SA")
        XCTAssertEqual(ArabicDays.count(1, locale: ar), "يوم واحد")
        XCTAssertEqual(ArabicDays.count(2, locale: ar), "يومان")
        XCTAssertEqual(ArabicDays.count(3, locale: ar), "٣ أيام")
        XCTAssertEqual(ArabicDays.count(10, locale: ar), "١٠ أيام")
        XCTAssertEqual(ArabicDays.count(84, locale: ar), "٨٤ يوماً")
        XCTAssertEqual(ArabicDays.count(100, locale: ar), "١٠٠ يوم")
        XCTAssertEqual(ArabicDays.count(102, locale: ar), "١٠٢ يوم")
        XCTAssertEqual(ArabicDays.count(236, locale: ar), "٢٣٦ يوماً")
        XCTAssertEqual(ArabicDays.count(305, locale: ar), "٣٠٥ أيام")
    }
}
