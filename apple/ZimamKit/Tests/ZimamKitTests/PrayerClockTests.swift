import Foundation
import Testing
@testable import ZimamKit

final class PrayerClockTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let day = Date(timeIntervalSince1970: 1_791_882_000) // 2026-10-13 12:00 Riyadh
    lazy var schedule = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, timeZone: riyadh)
    lazy var clock = PrayerClock(schedule: schedule)

    @Test func countsUpForHalfAnHourAfterTheAdhanThenDown() throws {
        let asr = schedule.time(of: .asr, on: day)!
        #expect(clock.state(at: asr.addingTimeInterval(-60)) == .until(.asr, time: asr))
        #expect(clock.state(at: asr) == .since(.asr, adhan: asr))
        #expect(clock.state(at: asr.addingTimeInterval(29 * 60)) == .since(.asr, adhan: asr))
        let maghrib = schedule.time(of: .maghrib, on: day)!
        #expect(clock.state(at: asr.addingTimeInterval(30 * 60)) == .until(.maghrib, time: maghrib))
    }

    @Test func titleSaysWhichWayTheClockCounts() {
        let adhan = Date(timeIntervalSince1970: 0)
        #expect(PrayerClock.State.until(.asr, time: adhan).title == "المتبقي على العصر")
        #expect(PrayerClock.State.since(.maghrib, adhan: adhan).title == "مضى على أذان المغرب")
    }

    @Test func afterIshaCountsDownToTomorrowsFajr() throws {
        let isha = schedule.time(of: .isha, on: day)!
        let state = try #require(clock.state(at: isha.addingTimeInterval(31 * 60)))
        #expect(state.prayer == .fajr)
        #expect(state.time > isha)
        // Just after midnight, the half hour after Isha has long passed and Fajr is still ahead.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = riyadh
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        #expect(clock.state(at: midnight.addingTimeInterval(60))?.prayer == .fajr)
    }

    @Test func upcomingCrossesMidnight() throws {
        let maghrib = schedule.time(of: .maghrib, on: day)!
        let next = clock.upcoming(after: maghrib, count: 3).map(\.prayer)
        #expect(next == [.isha, .fajr, .dhuhr])
    }

    @Test func timelineChangesAtEachAdhanItsHalfHourAndMidnight() throws {
        let start = Calendar(identifier: .gregorian).date(byAdding: .hour, value: -12, to: day)! // midnight
        let changes = clock.changes(from: start, days: 1)
        let asr = schedule.time(of: .asr, on: day)!
        #expect(changes.contains(asr))
        #expect(changes.contains(asr.addingTimeInterval(PrayerClock.elapsedWindow)))
        #expect(changes == changes.sorted())
        #expect(changes.allSatisfy { $0 > start && $0 <= start.addingTimeInterval(86_400) })
    }
}

final class PrayerAlertPlannerTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let day = Date(timeIntervalSince1970: 1_791_882_000) // 2026-10-13 12:00 Riyadh
    lazy var schedule = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, timeZone: riyadh)

    @Test func nothingWithoutAlertsOrPlace() throws {
        #expect(PrayerAlertPlanner.plan(settings: PrayerAlertSettings(), schedule: schedule, now: day).isEmpty)
        var settings = PrayerAlertSettings()
        settings[.asr].adhan = true
        #expect(PrayerAlertPlanner.plan(settings: settings, schedule: nil, now: day).isEmpty)
    }

    @Test func adhanAndIqamaAtTheirTimes() throws {
        var settings = PrayerAlertSettings()
        settings[.asr] = PrayerAlert(adhan: true, iqama: true, iqamaMinutes: 15)
        let planned = PrayerAlertPlanner.plan(settings: settings, schedule: schedule, now: day)
        let asr = schedule.time(of: .asr, on: day)!
        #expect(planned.first?.id == "prayer-asr-adhan@2026-10-13")
        #expect(planned.first?.date == asr)
        #expect(planned.first?.body == "حان الآن وقت صلاة العصر")
        #expect(planned[1].kind == .iqama)
        #expect(planned[1].date == asr.addingTimeInterval(15 * 60))
        #expect(planned[1].body == "حان وقت إقامة صلاة العصر")
        // Today, tomorrow and the day after.
        #expect(planned.count == 6)
    }

    @Test func pastAlertsAreSkippedAndTheBudgetHolds() throws {
        var settings = PrayerAlertSettings()
        for prayer in Prayer.allCases { settings[prayer] = PrayerAlert(adhan: true, iqama: true, iqamaMinutes: 20) }
        let planned = PrayerAlertPlanner.plan(settings: settings, schedule: schedule, now: day)
        #expect(planned.count == PrayerAlertPlanner.limit)
        #expect(planned.allSatisfy { $0.date > day })
        #expect(planned == planned.sorted { $0.date < $1.date })
        #expect(!planned.contains { $0.id == "prayer-fajr-adhan@2026-10-13" })
    }

    @Test func iqamaWaitStaysInRangeAndUsualDefaults() throws {
        #expect(PrayerAlert(iqamaMinutes: 2).iqamaMinutes == 5)
        #expect(PrayerAlert(iqamaMinutes: 90).iqamaMinutes == 60)
        #expect(PrayerAlertSettings()[.fajr].iqamaMinutes == 25)
        #expect(PrayerAlertSettings()[.maghrib].iqamaMinutes == 10)
        #expect(!PrayerAlertSettings()[.isha].adhan)
    }

    @Test func storedKeyedByPrayer() throws {
        var settings = PrayerAlertSettings()
        settings[.asr] = PrayerAlert(adhan: true, iqama: false, iqamaMinutes: 20)
        let data = try JSONEncoder().encode(settings)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["asr"] != nil)
        #expect(try JSONDecoder().decode(PrayerAlertSettings.self, from: data) == settings)
        let unknown = Data(#"{"sunrise":{"adhan":true,"iqama":false,"iqamaMinutes":10}}"#.utf8)
        #expect(try JSONDecoder().decode(PrayerAlertSettings.self, from: unknown) == PrayerAlertSettings())
    }
}
