import XCTest
@testable import ZimamKit

final class RecurrenceTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let ar = Locale(identifier: "ar-SA")

    // 2026-10-13 is a Tuesday.

    func testParsesAndWritesRules() throws {
        let weekly = try XCTUnwrap(Recurrence(rrule: "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TH,MO;COUNT=5"))
        XCTAssertEqual(weekly.frequency, .weekly)
        XCTAssertEqual(weekly.interval, 2)
        XCTAssertEqual(weekly.weekdays, [.monday, .thursday])
        XCTAssertEqual(weekly.count, 5)
        XCTAssertEqual(weekly.rrule, "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;COUNT=5")

        let until = try XCTUnwrap(Recurrence(rrule: "FREQ=DAILY;UNTIL=20261231T235959Z"))
        XCTAssertEqual(until.until, "2026-12-31")
        XCTAssertEqual(until.rrule, "FREQ=DAILY;UNTIL=20261231")

        XCTAssertEqual(Recurrence(rrule: "FREQ=MONTHLY;WKST=SU")?.rrule, "FREQ=MONTHLY")
        XCTAssertEqual(Recurrence(frequency: .yearly).rrule, "FREQ=YEARLY")
    }

    func testRejectsWhatItDoesNotSupport() {
        XCTAssertNil(Recurrence(rrule: ""))
        XCTAssertNil(Recurrence(rrule: "FREQ=HOURLY"))
        XCTAssertNil(Recurrence(rrule: "INTERVAL=2"))
        XCTAssertNil(Recurrence(rrule: "FREQ=DAILY;INTERVAL=0"))
        XCTAssertNil(Recurrence(rrule: "FREQ=WEEKLY;BYDAY=XX"))
        XCTAssertNil(Recurrence(rrule: "FREQ=DAILY;UNTIL=soon"))
    }

    func testDailyAndInterval() {
        XCTAssertEqual(Recurrence(frequency: .daily).nextDay(after: "2026-10-13", timeZone: riyadh), "2026-10-14")
        XCTAssertEqual(Recurrence(frequency: .daily, interval: 3).nextDay(after: "2026-10-13", timeZone: riyadh), "2026-10-16")
        XCTAssertEqual(Recurrence(frequency: .daily).nextDay(after: "2026-12-31", timeZone: riyadh), "2027-01-01")
    }

    func testWeeklyOnChosenDays() {
        let rule = Recurrence(frequency: .weekly, weekdays: [.monday, .thursday])
        XCTAssertEqual(rule.nextDay(after: "2026-10-13", timeZone: riyadh), "2026-10-15")
        XCTAssertEqual(rule.nextDay(after: "2026-10-15", timeZone: riyadh), "2026-10-19")
        XCTAssertEqual(Recurrence(frequency: .weekly).nextDay(after: "2026-10-13", timeZone: riyadh), "2026-10-20")
    }

    func testEveryOtherWeek() {
        let rule = Recurrence(frequency: .weekly, interval: 2, weekdays: [.tuesday])
        XCTAssertEqual(rule.nextDay(after: "2026-10-13", timeZone: riyadh), "2026-10-27")
        let twoDays = Recurrence(frequency: .weekly, interval: 2, weekdays: [.tuesday, .thursday])
        XCTAssertEqual(twoDays.nextDay(after: "2026-10-13", timeZone: riyadh), "2026-10-15")
        XCTAssertEqual(twoDays.nextDay(after: "2026-10-15", timeZone: riyadh), "2026-10-27")
    }

    func testMonthlyAndYearlyClampToTheEndOfTheMonth() {
        XCTAssertEqual(Recurrence(frequency: .monthly).nextDay(after: "2026-10-13", timeZone: riyadh), "2026-11-13")
        XCTAssertEqual(Recurrence(frequency: .monthly).nextDay(after: "2026-01-31", timeZone: riyadh), "2026-02-28")
        XCTAssertEqual(Recurrence(frequency: .yearly).nextDay(after: "2028-02-29", timeZone: riyadh), "2029-02-28")
        XCTAssertEqual(Recurrence(frequency: .yearly, interval: 2).nextDay(after: "2026-10-13", timeZone: riyadh), "2028-10-13")
    }

    func testUntilAndCountEndTheSeries() throws {
        let until = Recurrence(frequency: .daily, until: "2026-10-20")
        XCTAssertEqual(until.nextDay(after: "2026-10-19", timeZone: riyadh), "2026-10-20")
        XCTAssertNil(until.nextDay(after: "2026-10-20", timeZone: riyadh))

        let three = Recurrence(frequency: .daily, count: 3)
        let second = try XCTUnwrap(three.nextOccurrence(after: "2026-10-13", timeZone: riyadh))
        XCTAssertEqual(second.day, "2026-10-14")
        XCTAssertEqual(second.rule.count, 2)
        let third = try XCTUnwrap(second.rule.nextOccurrence(after: second.day, timeZone: riyadh))
        XCTAssertEqual(third.day, "2026-10-15")
        XCTAssertEqual(third.rule.count, 1)
        XCTAssertNil(third.rule.nextOccurrence(after: third.day, timeZone: riyadh))
    }

    func testOverdueTaskMovesToTodayOrLater() throws {
        let weekly = Recurrence(frequency: .weekly, weekdays: [.thursday])
        let next = try XCTUnwrap(weekly.nextOccurrence(after: "2026-09-03", notBefore: "2026-10-13", timeZone: riyadh))
        XCTAssertEqual(next.day, "2026-10-15")
        let daily = Recurrence(frequency: .daily)
        XCTAssertEqual(daily.nextOccurrence(after: "2026-10-01", notBefore: "2026-10-13", timeZone: riyadh)?.day, "2026-10-13")
    }

    func testArabicDescriptions() {
        XCTAssertEqual(Recurrence(frequency: .daily).arabicDescription(locale: ar), "كل يوم")
        XCTAssertEqual(Recurrence(frequency: .daily, interval: 2).arabicDescription(locale: ar), "كل يومين")
        XCTAssertEqual(Recurrence(frequency: .daily, interval: 3).arabicDescription(locale: ar), "كل ٣ أيام")
        XCTAssertEqual(Recurrence(frequency: .daily, interval: 11).arabicDescription(locale: ar), "كل ١١ يوماً")
        XCTAssertEqual(Recurrence(frequency: .weekly).arabicDescription(locale: ar), "كل أسبوع")
        XCTAssertEqual(Recurrence(frequency: .weekly, weekdays: [.thursday]).arabicDescription(locale: ar), "كل أسبوع يوم الخميس")
        XCTAssertEqual(Recurrence(frequency: .weekly, weekdays: [.thursday, .monday]).arabicDescription(locale: ar),
                       "كل أسبوع يومي الإثنين والخميس")
        XCTAssertEqual(Recurrence(frequency: .weekly, weekdays: [.sunday, .tuesday, .thursday]).arabicDescription(locale: ar),
                       "كل أسبوع أيام الأحد والثلاثاء والخميس")
        XCTAssertEqual(Recurrence(frequency: .weekly, interval: 2, weekdays: [.friday]).arabicDescription(locale: ar),
                       "كل أسبوعين يوم الجمعة")
        XCTAssertEqual(Recurrence(frequency: .weekly, weekdays: Weekday.allCases).arabicDescription(locale: ar), "كل يوم")
        XCTAssertEqual(Recurrence(frequency: .monthly).arabicDescription(locale: ar), "كل شهر")
        XCTAssertEqual(Recurrence(frequency: .monthly, interval: 3).arabicDescription(locale: ar), "كل ٣ أشهر")
        XCTAssertEqual(Recurrence(frequency: .yearly).arabicDescription(locale: ar), "كل سنة")
    }
}
