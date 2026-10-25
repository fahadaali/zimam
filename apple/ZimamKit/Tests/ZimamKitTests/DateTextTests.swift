import Foundation
import Testing
@testable import ZimamKit

final class DateTextTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    // 2026-10-13 12:00 in Riyadh: 2 Jumada al-Ula 1448, a Tuesday.
    lazy var tuesday = Date(timeIntervalSince1970: 1_791_882_000)
    lazy var formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)

    @Test func hijriAndGregorianUseArabicDigits() {
        #expect(formatter.hijri(tuesday) == "٢ جمادى الأولى")
        #expect(formatter.hijri(tuesday, withYear: true) == "٢ جمادى الأولى ١٤٤٨هـ")
        #expect(formatter.gregorian(tuesday) == "١٣ أكتوبر")
    }

    @Test func dualPutsPrimaryCalendarFirstWithArabicComma() {
        #expect(formatter.dual(tuesday) == "٢ جمادى الأولى، ١٣ أكتوبر")
        var gregorianFirst = formatter
        gregorianFirst.primary = .gregorian
        #expect(gregorianFirst.dual(tuesday) == "١٣ أكتوبر، ٢ جمادى الأولى")
        #expect(!formatter.dual(tuesday).contains("·"))
    }

    @Test func nearbyDaysUseOneWord() {
        let day: TimeInterval = 86_400
        #expect(formatter.label(for: tuesday, now: tuesday) == "اليوم")
        #expect(formatter.label(for: tuesday + day, now: tuesday) == "غداً")
        #expect(formatter.label(for: tuesday - day, now: tuesday) == "أمس")
        #expect(formatter.label(for: tuesday + 2 * day, now: tuesday) == "الخميس")
        #expect(formatter.label(for: tuesday + 10 * day, now: tuesday) == "١٢ جمادى الأولى، ٢٣ أكتوبر")
    }

    @Test func dayStringsRoundTrip() {
        #expect(formatter.dayString(from: tuesday) == "2026-10-13")
        let parsed = formatter.date(fromDay: "2026-10-13")!
        #expect(formatter.dayString(from: parsed) == "2026-10-13")
        #expect(formatter.date(fromDay: "13/10/2026") == nil)
    }

    @Test func prayerPhrases() {
        let ar = Locale(identifier: "ar-SA")
        #expect(PrayerPhrase.text(.asr, offsetMinutes: 20, locale: ar) == "بعد العصر بـ٢٠ د")
        #expect(PrayerPhrase.text(.maghrib, offsetMinutes: -10, locale: ar) == "قبل المغرب بـ١٠ د")
        #expect(PrayerPhrase.text(.fajr, offsetMinutes: nil, locale: ar) == "عند الفجر")
        #expect(PrayerPhrase.text(.dhuhr, offsetMinutes: 60, locale: ar) == "بعد الظهر بساعة")
        #expect(PrayerPhrase.text(.isha, offsetMinutes: 120, locale: ar) == "بعد العشاء بساعتين")
    }
}
