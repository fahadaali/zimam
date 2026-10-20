import Foundation
import Testing
@testable import ZimamKit

struct TaskTimingTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    var formatter: DualDateFormatter { DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh) }
    var schedule: PrayerSchedule { PrayerSchedule(latitude: 24.7136, longitude: 46.6753, method: .ummAlQura, timeZone: riyadh) }

    @Test func modesAreExclusiveAndPrayerWins() {
        #expect(TaskTimeMode(dueTime: nil, prayer: nil, offsetMinutes: nil) == .allDay)
        #expect(TaskTimeMode(dueTime: "15:30", prayer: nil, offsetMinutes: nil) == .clock("15:30"))
        #expect(TaskTimeMode(dueTime: "15:30", prayer: .asr, offsetMinutes: -10) == .prayer(.asr, offsetMinutes: -10))
        #expect(TaskTimeMode(dueTime: "later", prayer: nil, offsetMinutes: nil) == .allDay)
    }

    @Test func clockTimeOnItsDay() {
        let time = TaskTiming.time(of: .clock("15:30"), on: "2026-10-14", schedule: nil, formatter: formatter)
        #expect(time == formatter.date(fromDay: "2026-10-14")!.addingTimeInterval(15.5 * 3600))
        #expect(TaskTiming.clockString(from: time!, timeZone: riyadh) == "15:30")
    }

    @Test func allDayCountsFromNine() {
        let time = TaskTiming.time(of: .allDay, on: "2026-10-14", schedule: nil, formatter: formatter)
        #expect(time == formatter.date(fromDay: "2026-10-14")!.addingTimeInterval(9 * 3600))
    }

    /// A month ahead, the time is that day's Asr, not today's.
    @Test func prayerTimeOnADayAMonthAway() {
        let day = "2026-11-20"
        let time = TaskTiming.time(of: .prayer(.asr, offsetMinutes: -10), on: day, schedule: schedule, formatter: formatter)
        let noon = formatter.date(fromDay: day)!.addingTimeInterval(12 * 3600)
        #expect(time == schedule.time(of: .asr, on: noon, offsetMinutes: -10))
        let today = TaskTiming.time(of: .prayer(.asr, offsetMinutes: -10), on: "2026-10-20", schedule: schedule, formatter: formatter)
        #expect(time.map { TaskTiming.clockString(from: $0, timeZone: riyadh) } != today.map { TaskTiming.clockString(from: $0, timeZone: riyadh) })
    }

    @Test func prayerTimeNeedsAPlace() {
        #expect(TaskTiming.time(of: .prayer(.asr, offsetMinutes: 0), on: "2026-10-14", schedule: nil, formatter: formatter) == nil)
    }

    @Test func shownTimeUsesTodayForAnUndatedPrayer() {
        let now = formatter.date(fromDay: "2026-10-14")!.addingTimeInterval(8 * 3600)
        let shown = TaskTiming.shownTime(of: .prayer(.maghrib, offsetMinutes: 0), dueDay: nil, schedule: schedule,
                                         formatter: formatter, now: now)
        #expect(shown == schedule.time(of: .maghrib, on: now.addingTimeInterval(4 * 3600)))
        #expect(TaskTiming.shownTime(of: .allDay, dueDay: "2026-10-14", schedule: schedule, formatter: formatter) == nil)
    }

    @Test func relativePhrases() {
        let locale = Locale(identifier: "ar-SA")
        #expect(RelativeReminderPhrase.text(0, locale: locale) == "عند الموعد")
        #expect(RelativeReminderPhrase.text(-15, locale: locale) == "قبل ١٥ د")
        #expect(RelativeReminderPhrase.text(-60, locale: locale) == "قبل ساعة")
        #expect(RelativeReminderPhrase.text(-120, locale: locale) == "قبل ساعتين")
        #expect(RelativeReminderPhrase.text(-1440, locale: locale) == "قبل يوم")
        #expect(RelativeReminderPhrase.text(-2880, locale: locale) == "قبل يومين")
    }
}
