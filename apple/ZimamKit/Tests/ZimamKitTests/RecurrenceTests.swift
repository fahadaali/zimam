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

        #expect(Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=31")?.rrule == "FREQ=MONTHLY;BYMONTHDAY=31")
        #expect(Recurrence(rrule: "FREQ=YEARLY;BYMONTHDAY=29;BYMONTH=2;COUNT=3")?.rrule == "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;COUNT=3")
        #expect(Recurrence(rrule: "FREQ=YEARLY;BYMONTH=3")?.month == 3)
        // Every day on some weekdays is weekly on them: the Saudi working week.
        let workdays = try #require(Recurrence(rrule: "FREQ=DAILY;BYDAY=SU,MO,TU,WE,TH"))
        #expect(workdays.frequency == .weekly)
        #expect(workdays.rrule == "FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH")
        #expect(workdays.nextDay(after: "2026-10-15", timeZone: riyadh) == "2026-10-18")
    }

    @Test func rejectsWhatItDoesNotSupport() {
        #expect(Recurrence(rrule: "") == nil)
        #expect(Recurrence(rrule: "FREQ=HOURLY") == nil)
        #expect(Recurrence(rrule: "INTERVAL=2") == nil)
        #expect(Recurrence(rrule: "FREQ=DAILY;INTERVAL=0") == nil)
        #expect(Recurrence(rrule: "FREQ=WEEKLY;BYDAY=XX") == nil)
        #expect(Recurrence(rrule: "FREQ=DAILY;UNTIL=soon") == nil)
    }

    /// Rules with days Zimam cannot follow are not read as a plainer rule that would put the next
    /// occurrence on another day: they read as «تكرار مخصص», and completing adds none.
    @Test func rejectsPartsThatPickOtherDays() {
        #expect(Recurrence(rrule: "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=1") == nil)
        #expect(Recurrence(rrule: "FREQ=MONTHLY;BYSETPOS=-1;BYDAY=FR") == nil)
        #expect(Recurrence(rrule: "FREQ=MONTHLY;BYDAY=MO") == nil)
        #expect(Recurrence(rrule: "FREQ=WEEKLY;BYDAY=1MO") == nil)
        #expect(Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=1,15") == nil)
        #expect(Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=-1") == nil)
        #expect(Recurrence(rrule: "FREQ=YEARLY;BYMONTH=1,7") == nil)
        #expect(Recurrence(rrule: "FREQ=YEARLY;BYMONTHDAY=15") == nil)
        #expect(Recurrence(rrule: "FREQ=WEEKLY;BYMONTHDAY=3") == nil)
        #expect(Recurrence(rrule: "FREQ=MONTHLY;BYMONTH=3") == nil)
        #expect(Recurrence(rrule: "FREQ=DAILY;INTERVAL=2;BYDAY=MO") == nil)
        #expect(Recurrence(rrule: "FREQ=DAILY;BYHOUR=9") == nil)
        #expect(Recurrence(rrule: "FREQ=YEARLY;BYYEARDAY=100") == nil)
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

    /// The series' day survives a short month: the 31st, then 28 February, then the 31st again.
    @Test func aMonthlySeriesKeepsItsDay() throws {
        let rule = Recurrence(frequency: .monthly)
        let february = try #require(rule.nextOccurrence(after: "2026-01-31", timeZone: riyadh))
        #expect(february.day == "2026-02-28")
        #expect(february.rule.rrule == "FREQ=MONTHLY;BYMONTHDAY=31")
        let march = try #require(february.rule.nextOccurrence(after: february.day, timeZone: riyadh))
        #expect(march.day == "2026-03-31")
        #expect(march.rule.rrule == "FREQ=MONTHLY")
        let april = try #require(march.rule.nextOccurrence(after: march.day, timeZone: riyadh))
        #expect(april.day == "2026-04-30")
        // Completed late: the months on the way do not move it either.
        #expect(rule.nextOccurrence(after: "2026-01-31", notBefore: "2026-04-15", timeZone: riyadh)?.day == "2026-04-30")
    }

    @Test func aYearlySeriesOnTheLeapDayComesBackToIt() throws {
        var day = "2028-02-29"
        var rule = Recurrence(frequency: .yearly)
        var days: [String] = []
        for _ in 0..<4 {
            let next = try #require(rule.nextOccurrence(after: day, timeZone: riyadh))
            days.append(next.day)
            day = next.day
            rule = next.rule
        }
        #expect(days == ["2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"])
        #expect(rule.rrule == "FREQ=YEARLY")
    }

    /// A month day other than the task's own: the next one is on it, this month if still to come.
    @Test func monthDayPicksTheDay() throws {
        let first = try #require(Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=1"))
        let next = try #require(first.nextOccurrence(after: "2026-10-24", timeZone: riyadh))
        #expect(next.day == "2026-11-01")
        #expect(next.rule.rrule == "FREQ=MONTHLY")
        #expect(Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=20")?.nextDay(after: "2026-10-15", timeZone: riyadh) == "2026-10-20")
        #expect(Recurrence(rrule: "FREQ=YEARLY;BYMONTH=3")?.nextOccurrence(after: "2026-10-24", timeZone: riyadh)?.day == "2027-03-24")
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
