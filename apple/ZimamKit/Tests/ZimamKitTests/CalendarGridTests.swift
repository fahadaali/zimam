import XCTest
@testable import ZimamKit

final class CalendarGridTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let sunday = 1, monday = 2, saturday = 7

    private func grid(_ kind: CalendarKind, weekStart: Int = 1) -> CalendarGrid {
        CalendarGrid(kind: kind, firstWeekday: weekStart, timeZone: riyadh)
    }

    /// Midday of an API day in Riyadh, so no edge of the day is involved.
    private func on(_ day: String) -> Date {
        DualDateFormatter(timeZone: riyadh).date(fromDay: day)!.addingTimeInterval(12 * 3600)
    }

    // MARK: Hijri months (Umm al-Qura)

    func testHijriMonthOfThirtyDays() {
        // Jumada al-Ula 1448: 12 October to 10 November 2026.
        let hijri = grid(.hijri)
        XCTAssertEqual(hijri.numberOfDays(inMonthContaining: on("2026-10-13")), 30)
        let days = hijri.monthDays(containing: on("2026-10-13")).filter(\.isInPeriod)
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days.first?.day, "2026-10-12")
        XCTAssertEqual(days.first?.primaryDay, 1)
        XCTAssertEqual(days.first?.secondaryDay, 12)
        XCTAssertEqual(days.last?.day, "2026-11-10")
        XCTAssertEqual(days.last?.primaryDay, 30)
        XCTAssertEqual(days.last?.secondaryDay, 10)
    }

    func testHijriMonthOfTwentyNineDays() {
        // Jumada al-Akhira 1448: 11 November to 9 December 2026.
        let hijri = grid(.hijri)
        XCTAssertEqual(hijri.numberOfDays(inMonthContaining: on("2026-11-20")), 29)
        let days = hijri.monthDays(containing: on("2026-11-20")).filter(\.isInPeriod)
        XCTAssertEqual(days.count, 29)
        XCTAssertEqual(days.first?.day, "2026-11-11")
        XCTAssertEqual(days.last?.day, "2026-12-09")
        XCTAssertEqual(days.last?.primaryDay, 29)
    }

    func testAddingHijriMonths() {
        let hijri = grid(.hijri)
        let next = hijri.addingMonths(1, to: on("2026-10-13")) // 2 Jumada al-Ula → 2 Jumada al-Akhira
        XCTAssertEqual(hijri.dayString(from: next), "2026-11-12")
        // 30 Jumada al-Ula → Jumada al-Akhira has 29 days, so its last day.
        let clamped = hijri.addingMonths(1, to: on("2026-11-10"))
        XCTAssertEqual(hijri.dayString(from: clamped), "2026-12-09")
    }

    // MARK: Gregorian months

    func testGregorianLeapYears() {
        let gregorian = grid(.gregorian)
        XCTAssertEqual(gregorian.numberOfDays(inMonthContaining: on("2024-02-10")), 29)
        XCTAssertEqual(gregorian.numberOfDays(inMonthContaining: on("2026-02-10")), 28)
        XCTAssertEqual(gregorian.numberOfDays(inMonthContaining: on("2000-02-10")), 29)
        XCTAssertEqual(gregorian.numberOfDays(inMonthContaining: on("2100-02-10")), 28)
        let leap = gregorian.monthDays(containing: on("2024-02-10")).filter(\.isInPeriod)
        XCTAssertEqual(leap.last?.day, "2024-02-29")
        XCTAssertEqual(leap.last?.primaryDay, 29)
    }

    func testGregorianCellsCarryTheHijriDay() {
        let days = grid(.gregorian).monthDays(containing: on("2026-10-13")).filter(\.isInPeriod)
        XCTAssertEqual(days.count, 31)
        // 1 October 2026 is 20 Rabi al-Akhir 1448; 12 October is 1 Jumada al-Ula.
        XCTAssertEqual(days[0].primaryDay, 1)
        XCTAssertEqual(days[0].secondaryDay, 20)
        XCTAssertEqual(days[11].secondaryDay, 1)
    }

    // MARK: Week start and padding

    func testWeekdayOrder() {
        XCTAssertEqual(grid(.gregorian, weekStart: sunday).weekdayOrder, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(grid(.gregorian, weekStart: saturday).weekdayOrder, [7, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(grid(.gregorian, weekStart: monday).weekdayOrder, [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(CalendarGrid(firstWeekday: 9).firstWeekday, 1)
    }

    func testPaddingFollowsWeekStart() {
        // 1 October 2026 is a Thursday; the month has 31 days and ends on a Saturday.
        let fromSunday = grid(.gregorian, weekStart: sunday)
        XCTAssertEqual(fromSunday.leadingPadding(forMonthContaining: on("2026-10-13")), 4)
        XCTAssertEqual(fromSunday.trailingPadding(forMonthContaining: on("2026-10-13")), 0)
        let sundayCells = fromSunday.monthDays(containing: on("2026-10-13"))
        XCTAssertEqual(sundayCells.count, 35)
        XCTAssertEqual(sundayCells.first?.day, "2026-09-27")
        XCTAssertEqual(sundayCells.first?.isInPeriod, false)
        XCTAssertEqual(sundayCells[4].day, "2026-10-01")
        XCTAssertEqual(sundayCells[4].isInPeriod, true)

        let fromSaturday = grid(.gregorian, weekStart: saturday)
        XCTAssertEqual(fromSaturday.leadingPadding(forMonthContaining: on("2026-10-13")), 5)
        XCTAssertEqual(fromSaturday.trailingPadding(forMonthContaining: on("2026-10-13")), 6)
        let saturdayCells = fromSaturday.monthDays(containing: on("2026-10-13"))
        XCTAssertEqual(saturdayCells.count, 42)
        XCTAssertEqual(saturdayCells.first?.day, "2026-09-26")
        XCTAssertEqual(saturdayCells.last?.day, "2026-11-06")
        XCTAssertEqual(saturdayCells.last?.isInPeriod, false)

        XCTAssertEqual(grid(.gregorian, weekStart: monday).leadingPadding(forMonthContaining: on("2026-10-13")), 3)
    }

    func testHijriPaddingFollowsWeekStart() {
        // 1 Jumada al-Ula 1448 is Monday 12 October 2026; 1 Jumada al-Akhira is Wednesday 11 November.
        XCTAssertEqual(grid(.hijri, weekStart: sunday).leadingPadding(forMonthContaining: on("2026-10-13")), 1)
        XCTAssertEqual(grid(.hijri, weekStart: saturday).leadingPadding(forMonthContaining: on("2026-10-13")), 2)
        XCTAssertEqual(grid(.hijri, weekStart: sunday).leadingPadding(forMonthContaining: on("2026-11-20")), 3)
        XCTAssertEqual(grid(.hijri, weekStart: sunday).trailingPadding(forMonthContaining: on("2026-11-20")), 3)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = riyadh
        for weekStart in 1...7 {
            let cells = grid(.hijri, weekStart: weekStart).monthDays(containing: on("2026-10-13"))
            XCTAssertEqual(cells.count % 7, 0)
            XCTAssertEqual(gregorian.component(.weekday, from: cells[0].date), weekStart)
        }
    }

    func testWeekDays() {
        // Tuesday 13 October 2026.
        let fromSunday = grid(.hijri, weekStart: sunday).weekDays(containing: on("2026-10-13"))
        XCTAssertEqual(fromSunday.map(\.day), ["2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14",
                                               "2026-10-15", "2026-10-16", "2026-10-17"])
        XCTAssertEqual(fromSunday[0].primaryDay, 30) // 30 Rabi al-Akhir
        XCTAssertEqual(fromSunday[1].primaryDay, 1) // 1 Jumada al-Ula
        let fromSaturday = grid(.gregorian, weekStart: saturday).weekDays(containing: on("2026-10-13"))
        XCTAssertEqual(fromSaturday.first?.day, "2026-10-10")
        XCTAssertEqual(fromSaturday.last?.day, "2026-10-16")
        // A week starting today begins with today.
        XCTAssertEqual(grid(.gregorian, weekStart: 3).weekDays(containing: on("2026-10-13")).first?.day, "2026-10-13")
    }

    // MARK: Titles

    func testMonthTitles() {
        let formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
        XCTAssertEqual(formatter.monthTitle(on("2026-10-13"), in: .hijri), "جمادى الأولى ١٤٤٨هـ، أكتوبر – نوفمبر ٢٠٢٦م")
        XCTAssertEqual(formatter.monthTitle(on("2026-10-13"), in: .gregorian), "أكتوبر ٢٠٢٦م، ربيع الآخر – جمادى الأولى ١٤٤٨هـ")
        XCTAssertFalse(formatter.monthTitle(on("2026-10-13"), in: .hijri).contains("·"))
    }

    func testWeekTitles() {
        let formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
        XCTAssertEqual(formatter.rangeTitle(from: on("2026-10-18"), to: on("2026-10-24"), in: .hijri),
                       "٧ – ١٣ جمادى الأولى ١٤٤٨هـ، ١٨ – ٢٤ أكتوبر ٢٠٢٦م")
        XCTAssertEqual(formatter.rangeTitle(from: on("2026-10-11"), to: on("2026-10-17"), in: .gregorian),
                       "١١ – ١٧ أكتوبر ٢٠٢٦م، ٣٠ ربيع الآخر – ٦ جمادى الأولى ١٤٤٨هـ")
    }

    func testWeekdaySymbolsAndNumbers() {
        let formatter = DualDateFormatter(locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
        XCTAssertEqual(formatter.weekdaySymbols([7, 1], short: false), ["السبت", "الأحد"])
        XCTAssertEqual(formatter.weekday(on("2026-10-13")), "الثلاثاء")
        XCTAssertEqual(formatter.number(1448), "١٤٤٨")
    }
}
