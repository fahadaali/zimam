import Foundation
import Testing
@testable import ZimamKit

struct CalendarGridTests {
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

    @Test func hijriMonthOfThirtyDays() {
        // Jumada al-Ula 1448: 12 October to 10 November 2026.
        let hijri = grid(.hijri)
        #expect(hijri.numberOfDays(inMonthContaining: on("2026-10-13")) == 30)
        let days = hijri.monthDays(containing: on("2026-10-13")).filter(\.isInPeriod)
        #expect(days.count == 30)
        #expect(days.first?.day == "2026-10-12")
        #expect(days.first?.primaryDay == 1)
        #expect(days.first?.secondaryDay == 12)
        #expect(days.last?.day == "2026-11-10")
        #expect(days.last?.primaryDay == 30)
        #expect(days.last?.secondaryDay == 10)
    }

    @Test func hijriMonthOfTwentyNineDays() {
        // Jumada al-Akhira 1448: 11 November to 9 December 2026.
        let hijri = grid(.hijri)
        #expect(hijri.numberOfDays(inMonthContaining: on("2026-11-20")) == 29)
        let days = hijri.monthDays(containing: on("2026-11-20")).filter(\.isInPeriod)
        #expect(days.count == 29)
        #expect(days.first?.day == "2026-11-11")
        #expect(days.last?.day == "2026-12-09")
        #expect(days.last?.primaryDay == 29)
    }

    @Test func addingHijriMonths() {
        let hijri = grid(.hijri)
        let next = hijri.addingMonths(1, to: on("2026-10-13")) // 2 Jumada al-Ula → 2 Jumada al-Akhira
        #expect(hijri.dayString(from: next) == "2026-11-12")
        // 30 Jumada al-Ula → Jumada al-Akhira has 29 days, so its last day.
        let clamped = hijri.addingMonths(1, to: on("2026-11-10"))
        #expect(hijri.dayString(from: clamped) == "2026-12-09")
    }

    // MARK: Gregorian months

    @Test func gregorianLeapYears() {
        let gregorian = grid(.gregorian)
        #expect(gregorian.numberOfDays(inMonthContaining: on("2024-02-10")) == 29)
        #expect(gregorian.numberOfDays(inMonthContaining: on("2026-02-10")) == 28)
        #expect(gregorian.numberOfDays(inMonthContaining: on("2000-02-10")) == 29)
        #expect(gregorian.numberOfDays(inMonthContaining: on("2100-02-10")) == 28)
        let leap = gregorian.monthDays(containing: on("2024-02-10")).filter(\.isInPeriod)
        #expect(leap.last?.day == "2024-02-29")
        #expect(leap.last?.primaryDay == 29)
    }

    @Test func gregorianCellsCarryTheHijriDay() {
        let days = grid(.gregorian).monthDays(containing: on("2026-10-13")).filter(\.isInPeriod)
        #expect(days.count == 31)
        // 1 October 2026 is 20 Rabi al-Akhir 1448; 12 October is 1 Jumada al-Ula.
        #expect(days[0].primaryDay == 1)
        #expect(days[0].secondaryDay == 20)
        #expect(days[11].secondaryDay == 1)
    }

    // MARK: Week start and padding

    @Test func weekdayOrder() {
        #expect(grid(.gregorian, weekStart: sunday).weekdayOrder == [1, 2, 3, 4, 5, 6, 7])
        #expect(grid(.gregorian, weekStart: saturday).weekdayOrder == [7, 1, 2, 3, 4, 5, 6])
        #expect(grid(.gregorian, weekStart: monday).weekdayOrder == [2, 3, 4, 5, 6, 7, 1])
        #expect(CalendarGrid(firstWeekday: 9).firstWeekday == 1)
    }

    @Test func paddingFollowsWeekStart() {
        // 1 October 2026 is a Thursday; the month has 31 days and ends on a Saturday.
        let fromSunday = grid(.gregorian, weekStart: sunday)
        #expect(fromSunday.leadingPadding(forMonthContaining: on("2026-10-13")) == 4)
        #expect(fromSunday.trailingPadding(forMonthContaining: on("2026-10-13")) == 0)
        let sundayCells = fromSunday.monthDays(containing: on("2026-10-13"))
        #expect(sundayCells.count == 35)
        #expect(sundayCells.first?.day == "2026-09-27")
        #expect(sundayCells.first?.isInPeriod == false)
        #expect(sundayCells[4].day == "2026-10-01")
        #expect(sundayCells[4].isInPeriod == true)

        let fromSaturday = grid(.gregorian, weekStart: saturday)
        #expect(fromSaturday.leadingPadding(forMonthContaining: on("2026-10-13")) == 5)
        #expect(fromSaturday.trailingPadding(forMonthContaining: on("2026-10-13")) == 6)
        let saturdayCells = fromSaturday.monthDays(containing: on("2026-10-13"))
        #expect(saturdayCells.count == 42)
        #expect(saturdayCells.first?.day == "2026-09-26")
        #expect(saturdayCells.last?.day == "2026-11-06")
        #expect(saturdayCells.last?.isInPeriod == false)

        #expect(grid(.gregorian, weekStart: monday).leadingPadding(forMonthContaining: on("2026-10-13")) == 3)
    }

    @Test func hijriPaddingFollowsWeekStart() {
        // 1 Jumada al-Ula 1448 is Monday 12 October 2026; 1 Jumada al-Akhira is Wednesday 11 November.
        #expect(grid(.hijri, weekStart: sunday).leadingPadding(forMonthContaining: on("2026-10-13")) == 1)
        #expect(grid(.hijri, weekStart: saturday).leadingPadding(forMonthContaining: on("2026-10-13")) == 2)
        #expect(grid(.hijri, weekStart: sunday).leadingPadding(forMonthContaining: on("2026-11-20")) == 3)
        #expect(grid(.hijri, weekStart: sunday).trailingPadding(forMonthContaining: on("2026-11-20")) == 3)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = riyadh
        for weekStart in 1...7 {
            let cells = grid(.hijri, weekStart: weekStart).monthDays(containing: on("2026-10-13"))
            #expect((cells.count % 7) == 0)
            #expect(gregorian.component(.weekday, from: cells[0].date) == weekStart)
        }
    }

    @Test func weekDays() {
        // Tuesday 13 October 2026.
        let fromSunday = grid(.hijri, weekStart: sunday).weekDays(containing: on("2026-10-13"))
        #expect(fromSunday.map(\.day) == ["2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14",
                                               "2026-10-15", "2026-10-16", "2026-10-17"])
        #expect(fromSunday[0].primaryDay == 30) // 30 Rabi al-Akhir
        #expect(fromSunday[1].primaryDay == 1) // 1 Jumada al-Ula
        let fromSaturday = grid(.gregorian, weekStart: saturday).weekDays(containing: on("2026-10-13"))
        #expect(fromSaturday.first?.day == "2026-10-10")
        #expect(fromSaturday.last?.day == "2026-10-16")
        // A week starting today begins with today.
        #expect(grid(.gregorian, weekStart: 3).weekDays(containing: on("2026-10-13")).first?.day == "2026-10-13")
    }

    // MARK: Titles

    @Test func monthTitles() {
        let formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
        #expect(formatter.monthTitle(on("2026-10-13"), in: .hijri) == "جمادى الأولى ١٤٤٨هـ، أكتوبر – نوفمبر ٢٠٢٦م")
        #expect(formatter.monthTitle(on("2026-10-13"), in: .gregorian) == "أكتوبر ٢٠٢٦م، ربيع الآخر – جمادى الأولى ١٤٤٨هـ")
        #expect(!formatter.monthTitle(on("2026-10-13"), in: .hijri).contains("·"))
    }

    @Test func weekTitles() {
        let formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
        #expect(formatter.rangeTitle(from: on("2026-10-18"), to: on("2026-10-24"), in: .hijri) == "٧ – ١٣ جمادى الأولى ١٤٤٨هـ، ١٨ – ٢٤ أكتوبر ٢٠٢٦م")
        #expect(formatter.rangeTitle(from: on("2026-10-11"), to: on("2026-10-17"), in: .gregorian) == "١١ – ١٧ أكتوبر ٢٠٢٦م، ٣٠ ربيع الآخر – ٦ جمادى الأولى ١٤٤٨هـ")
    }

    @Test func weekdaySymbolsAndNumbers() {
        let formatter = DualDateFormatter(locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
        #expect(formatter.weekdaySymbols([7, 1], short: false) == ["السبت", "الأحد"])
        #expect(formatter.weekday(on("2026-10-13")) == "الثلاثاء")
        #expect(formatter.number(1448) == "١٤٤٨")
    }
}
