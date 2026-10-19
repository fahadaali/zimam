import Foundation
import Testing
@testable import ZimamKit

struct RecurrenceTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let ar = Locale(identifier: "ar-SA")

    // 2026-10-13 is a Tuesday.

    @Test func parsesAndWritesRules() throws {
        let weekly = try #require(Recurrence(rrule: "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TH,MO;COUNT=5"))
        #expect(weekly.frequency == .weekly)
        #expect(weekly.interval == 2)
        #expect(weekly.weekdays == [.monday, .thursday])
        #expect(weekly.count == 5)
        #expect(weekly.rrule == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;COUNT=5")

        let until = try #require(Recurrence(rrule: "FREQ=DAILY;UNTIL=20261231T235959Z"))
        #expect(until.until == "2026-12-31")
        #expect(until.rrule == "FREQ=DAILY;UNTIL=20261231")

        #expect(Recurrence(rrule: "FREQ=MONTHLY;WKST=SU")?.rrule == "FREQ=MONTHLY")
        #expect(Recurrence(frequency: .yearly).rrule == "FREQ=YEARLY")
    }

    @Test func rejectsWhatItDoesNotSupport() {
        #expect(Recurrence(rrule: "") == nil)
        #expect(Recurrence(rrule: "FREQ=HOURLY") == nil)
        #expect(Recurrence(rrule: "INTERVAL=2") == nil)
        #expect(Recurrence(rrule: "FREQ=DAILY;INTERVAL=0") == nil)
        #expect(Recurrence(rrule: "FREQ=WEEKLY;BYDAY=XX") == nil)
        #expect(Recurrence(rrule: "FREQ=DAILY;UNTIL=soon") == nil)
    }

    @Test func dailyAndInterval() {
        #expect(Recurrence(frequency: .daily).nextDay(after: "2026-10-13", timeZone: riyadh) == "2026-10-14")
        #expect(Recurrence(frequency: .daily, interval: 3).nextDay(after: "2026-10-13", timeZone: riyadh) == "2026-10-16")
        #expect(Recurrence(frequency: .daily).nextDay(after: "2026-12-31", timeZone: riyadh) == "2027-01-01")
    }

    @Test func weeklyOnChosenDays() {
        let rule = Recurrence(frequency: .weekly, weekdays: [.monday, .thursday])
        #expect(rule.nextDay(after: "2026-10-13", timeZone: riyadh) == "2026-10-15")
        #expect(rule.nextDay(after: "2026-10-15", timeZone: riyadh) == "2026-10-19")
        #expect(Recurrence(frequency: .weekly).nextDay(after: "2026-10-13", timeZone: riyadh) == "2026-10-20")
    }

    @Test func everyOtherWeek() {
        let rule = Recurrence(frequency: .weekly, interval: 2, weekdays: [.tuesday])
        #expect(rule.nextDay(after: "2026-10-13", timeZone: riyadh) == "2026-10-27")
        let twoDays = Recurrence(frequency: .weekly, interval: 2, weekdays: [.tuesday, .thursday])
        #expect(twoDays.nextDay(after: "2026-10-13", timeZone: riyadh) == "2026-10-15")
        #expect(twoDays.nextDay(after: "2026-10-15", timeZone: riyadh) == "2026-10-27")
    }

    @Test func monthlyAndYearlyClampToTheEndOfTheMonth() {
        #expect(Recurrence(frequency: .monthly).nextDay(after: "2026-10-13", timeZone: riyadh) == "2026-11-13")
        #expect(Recurrence(frequency: .monthly).nextDay(after: "2026-01-31", timeZone: riyadh) == "2026-02-28")
        #expect(Recurrence(frequency: .yearly).nextDay(after: "2028-02-29", timeZone: riyadh) == "2029-02-28")
        #expect(Recurrence(frequency: .yearly, interval: 2).nextDay(after: "2026-10-13", timeZone: riyadh) == "2028-10-13")
    }

    @Test func untilAndCountEndTheSeries() throws {
        let until = Recurrence(frequency: .daily, until: "2026-10-20")
        #expect(until.nextDay(after: "2026-10-19", timeZone: riyadh) == "2026-10-20")
        #expect(until.nextDay(after: "2026-10-20", timeZone: riyadh) == nil)

        let three = Recurrence(frequency: .daily, count: 3)
        let second = try #require(three.nextOccurrence(after: "2026-10-13", timeZone: riyadh))
        #expect(second.day == "2026-10-14")
        #expect(second.rule.count == 2)
        let third = try #require(second.rule.nextOccurrence(after: second.day, timeZone: riyadh))
        #expect(third.day == "2026-10-15")
        #expect(third.rule.count == 1)
        #expect(third.rule.nextOccurrence(after: third.day, timeZone: riyadh) == nil)
    }

    @Test func overdueTaskMovesToTodayOrLater() throws {
        let weekly = Recurrence(frequency: .weekly, weekdays: [.thursday])
        let next = try #require(weekly.nextOccurrence(after: "2026-09-03", notBefore: "2026-10-13", timeZone: riyadh))
        #expect(next.day == "2026-10-15")
        let daily = Recurrence(frequency: .daily)
        #expect(daily.nextOccurrence(after: "2026-10-01", notBefore: "2026-10-13", timeZone: riyadh)?.day == "2026-10-13")
    }

    @Test func arabicDescriptions() {
        #expect(Recurrence(frequency: .daily).arabicDescription(locale: ar) == "كل يوم")
        #expect(Recurrence(frequency: .daily, interval: 2).arabicDescription(locale: ar) == "كل يومين")
        #expect(Recurrence(frequency: .daily, interval: 3).arabicDescription(locale: ar) == "كل ٣ أيام")
        #expect(Recurrence(frequency: .daily, interval: 11).arabicDescription(locale: ar) == "كل ١١ يوماً")
        #expect(Recurrence(frequency: .weekly).arabicDescription(locale: ar) == "كل أسبوع")
        #expect(Recurrence(frequency: .weekly, weekdays: [.thursday]).arabicDescription(locale: ar) == "كل أسبوع يوم الخميس")
        #expect(Recurrence(frequency: .weekly, weekdays: [.thursday, .monday]).arabicDescription(locale: ar) == "كل أسبوع يومي الإثنين والخميس")
        #expect(Recurrence(frequency: .weekly, weekdays: [.sunday, .tuesday, .thursday]).arabicDescription(locale: ar) == "كل أسبوع أيام الأحد والثلاثاء والخميس")
        #expect(Recurrence(frequency: .weekly, interval: 2, weekdays: [.friday]).arabicDescription(locale: ar) == "كل أسبوعين يوم الجمعة")
        #expect(Recurrence(frequency: .weekly, weekdays: Weekday.allCases).arabicDescription(locale: ar) == "كل يوم")
        #expect(Recurrence(frequency: .monthly).arabicDescription(locale: ar) == "كل شهر")
        #expect(Recurrence(frequency: .monthly, interval: 3).arabicDescription(locale: ar) == "كل ٣ أشهر")
        #expect(Recurrence(frequency: .yearly).arabicDescription(locale: ar) == "كل سنة")
    }
}
