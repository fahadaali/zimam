import Foundation
import Testing
@testable import ZimamKit

final class PrayerTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    lazy var schedule = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, method: .ummAlQura, timeZone: riyadh)

    @Test func prayersAreInOrderOnTheSameLocalDay() throws {
        let day = Date(timeIntervalSince1970: 1_791_882_000) // 2026-10-13 12:00 Riyadh
        let times = schedule.times(on: day)
        #expect(times.count == 5)
        let ordered = Prayer.allCases.map { times[$0]! }
        #expect(ordered == ordered.sorted())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = riyadh
        for time in ordered { #expect(calendar.isDate(time, inSameDayAs: day)) }
    }

    @Test func ummAlQuraIshaIs90MinutesAfterMaghribAnd120InRamadan() throws {
        let october = schedule.times(on: Date(timeIntervalSince1970: 1_791_882_000))
        #expect(abs(october[.isha]!.timeIntervalSince(october[.maghrib]!) - (90 * 60)) <= 60)
        let ramadan = schedule.times(on: Date(timeIntervalSince1970: 1_802_682_000)) // 2027-02-15, 8 Ramadan 1448
        #expect(abs(ramadan[.isha]!.timeIntervalSince(ramadan[.maghrib]!) - (120 * 60)) <= 60)
    }

    @Test func offsetsAndNextPrayer() throws {
        let day = Date(timeIntervalSince1970: 1_791_882_000)
        let asr = schedule.time(of: .asr, on: day)!
        #expect(schedule.time(of: .asr, on: day, offsetMinutes: 20)!.timeIntervalSince(asr) == (20 * 60))
        let next = schedule.next(after: asr.addingTimeInterval(1))!
        #expect(next.prayer == .maghrib)
        let afterIsha = schedule.next(after: schedule.time(of: .isha, on: day)!.addingTimeInterval(1))!
        #expect(afterIsha.prayer == .fajr)
        #expect(afterIsha.time > day)
    }
}

final class PrayerMadhabTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let day = Date(timeIntervalSince1970: 1_791_882_000) // 2026-10-13 12:00 Riyadh

    @Test func hanafiAsrIsLaterAndTheRestStay() throws {
        let shafi = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, timeZone: riyadh).times(on: day)
        let hanafi = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, madhab: .hanafi, timeZone: riyadh).times(on: day)
        #expect(hanafi[.asr]!.timeIntervalSince(shafi[.asr]!) > 30 * 60)
        #expect(hanafi[.dhuhr] == shafi[.dhuhr])
        #expect(hanafi[.maghrib] == shafi[.maghrib])
    }

    @Test func sunriseFallsBetweenFajrAndDhuhr() throws {
        let schedule = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, timeZone: riyadh)
        let times = schedule.times(on: day)
        let sunrise = try #require(schedule.sunrise(on: day))
        #expect(sunrise > times[.fajr]! && sunrise < times[.dhuhr]!)
    }
}
