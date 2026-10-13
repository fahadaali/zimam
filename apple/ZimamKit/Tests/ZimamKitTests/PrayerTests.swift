import XCTest
@testable import ZimamKit

final class PrayerTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    lazy var schedule = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, method: .ummAlQura, timeZone: riyadh)

    func testPrayersAreInOrderOnTheSameLocalDay() throws {
        let day = Date(timeIntervalSince1970: 1_791_882_000) // 2026-10-13 12:00 Riyadh
        let times = schedule.times(on: day)
        XCTAssertEqual(times.count, 5)
        let ordered = Prayer.allCases.map { times[$0]! }
        XCTAssertEqual(ordered, ordered.sorted())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = riyadh
        for time in ordered { XCTAssertTrue(calendar.isDate(time, inSameDayAs: day)) }
    }

    func testUmmAlQuraIshaIs90MinutesAfterMaghribAnd120InRamadan() throws {
        let october = schedule.times(on: Date(timeIntervalSince1970: 1_791_882_000))
        XCTAssertEqual(october[.isha]!.timeIntervalSince(october[.maghrib]!), 90 * 60, accuracy: 60)
        let ramadan = schedule.times(on: Date(timeIntervalSince1970: 1_802_682_000)) // 2027-02-15, 8 Ramadan 1448
        XCTAssertEqual(ramadan[.isha]!.timeIntervalSince(ramadan[.maghrib]!), 120 * 60, accuracy: 60)
    }

    func testOffsetsAndNextPrayer() throws {
        let day = Date(timeIntervalSince1970: 1_791_882_000)
        let asr = schedule.time(of: .asr, on: day)!
        XCTAssertEqual(schedule.time(of: .asr, on: day, offsetMinutes: 20)!.timeIntervalSince(asr), 20 * 60)
        let next = schedule.next(after: asr.addingTimeInterval(1))!
        XCTAssertEqual(next.prayer, .maghrib)
        let afterIsha = schedule.next(after: schedule.time(of: .isha, on: day)!.addingTimeInterval(1))!
        XCTAssertEqual(afterIsha.prayer, .fajr)
        XCTAssertGreaterThan(afterIsha.time, day)
    }
}
