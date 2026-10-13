import XCTest
@testable import ZimamKit

final class DateTextTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    // 2026-10-13 12:00 in Riyadh: 2 Jumada al-Ula 1448, a Tuesday.
    lazy var tuesday = Date(timeIntervalSince1970: 1_791_882_000)
    lazy var formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)

    func testHijriAndGregorianUseArabicDigits() {
        XCTAssertEqual(formatter.hijri(tuesday), "٢ جمادى الأولى")
        XCTAssertEqual(formatter.gregorian(tuesday), "١٣ أكتوبر")
    }

    func testDualPutsPrimaryCalendarFirstWithArabicComma() {
        XCTAssertEqual(formatter.dual(tuesday), "٢ جمادى الأولى، ١٣ أكتوبر")
        var gregorianFirst = formatter
        gregorianFirst.primary = .gregorian
        XCTAssertEqual(gregorianFirst.dual(tuesday), "١٣ أكتوبر، ٢ جمادى الأولى")
        XCTAssertFalse(formatter.dual(tuesday).contains("·"))
    }

    func testNearbyDaysUseOneWord() {
        let day: TimeInterval = 86_400
        XCTAssertEqual(formatter.label(for: tuesday, now: tuesday), "اليوم")
        XCTAssertEqual(formatter.label(for: tuesday + day, now: tuesday), "غداً")
        XCTAssertEqual(formatter.label(for: tuesday - day, now: tuesday), "أمس")
        XCTAssertEqual(formatter.label(for: tuesday + 2 * day, now: tuesday), "الخميس")
        XCTAssertEqual(formatter.label(for: tuesday + 10 * day, now: tuesday), "١٢ جمادى الأولى، ٢٣ أكتوبر")
    }

    func testDayStringsRoundTrip() {
        XCTAssertEqual(formatter.dayString(from: tuesday), "2026-10-13")
        let parsed = formatter.date(fromDay: "2026-10-13")!
        XCTAssertEqual(formatter.dayString(from: parsed), "2026-10-13")
        XCTAssertNil(formatter.date(fromDay: "13/10/2026"))
    }

    func testPrayerPhrases() {
        let ar = Locale(identifier: "ar-SA")
        XCTAssertEqual(PrayerPhrase.text(.asr, offsetMinutes: 20, locale: ar), "بعد العصر بـ٢٠ د")
        XCTAssertEqual(PrayerPhrase.text(.maghrib, offsetMinutes: -10, locale: ar), "قبل المغرب بـ١٠ د")
        XCTAssertEqual(PrayerPhrase.text(.fajr, offsetMinutes: nil, locale: ar), "عند الفجر")
        XCTAssertEqual(PrayerPhrase.text(.dhuhr, offsetMinutes: 60, locale: ar), "بعد الظهر بساعة")
        XCTAssertEqual(PrayerPhrase.text(.isha, offsetMinutes: 120, locale: ar), "بعد العشاء بساعتين")
    }
}
