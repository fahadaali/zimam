import Foundation
import Testing
@testable import ZimamKit

/// 2026-10-13 is a Tuesday; `now` is 12:00 in Riyadh.
struct SpokenTimeTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let now = Date(timeIntervalSince1970: 1_791_882_000)

    func read(_ text: String, schedule: PrayerSchedule? = nil) -> SpokenTime.Reading {
        SpokenTime.read(text, now: now, timeZone: riyadh, schedule: schedule)
    }

    @Test func aPrayerWithADurationBeforeIt() {
        let reading = read("ذكرني أراجع العقد قبل المغرب بربع ساعة بكرة")
        #expect(reading.title == "أراجع العقد")
        #expect(reading.duePrayer == .maghrib)
        #expect(reading.duePrayerOffset == -15)
        #expect(reading.dueDate == "2026-10-14")
        #expect(reading.dueTime == nil)
    }

    @Test func afterAndAtAPrayer() {
        #expect(read("اتصل بأبي بعد صلاة العصر بنص ساعة").duePrayerOffset == 30)
        #expect(read("اتصل بأبي بعد العصر بعشر").duePrayerOffset == 10)
        #expect(read("اتصل بأبي بعد العشاء بساعتين").duePrayerOffset == 120)
        #expect(read("اتصل بأبي بعد العشاء بـ٢٠ دقيقة").duePrayerOffset == 20)
        let at = read("أقرأ الورد عند الفجر")
        #expect(at.duePrayer == .fajr)
        #expect(at.duePrayerOffset == 0)
        #expect(at.title == "أقرأ الورد")
        #expect(at.dueDate == "2026-10-13")
    }

    @Test func beforeAPrayerAloneIsAQuarterOfAnHour() {
        let reading = read("أتوضأ قبل المغرب")
        #expect(reading.duePrayerOffset == -SpokenTime.defaultBeforeMinutes)
    }

    @Test func aDurationSaidBeforeThePrayer() {
        let reading = read("أشغّل المكيف بنص ساعة قبل العشاء")
        #expect(reading.duePrayer == .isha)
        #expect(reading.duePrayerOffset == -30)
        #expect(reading.title == "أشغّل المكيف")
    }

    @Test func aPrayerThatPassedTodayIsTomorrow() {
        let schedule = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, timeZone: riyadh)
        #expect(read("أقرأ الورد بعد الفجر", schedule: schedule).dueDate == "2026-10-14")
        #expect(read("أقرأ الورد بعد العصر", schedule: schedule).dueDate == "2026-10-13")
    }

    @Test func fridayPrayerAndSpecialTimes() {
        let friday = read("أبكّر بعد صلاة الجمعة")
        #expect(friday.duePrayer == .dhuhr)
        #expect(friday.dueDate == "2026-10-16")
        let between = read("أراجع الحفظ بين المغرب والعشاء")
        #expect(between.duePrayer == .maghrib)
        #expect(between.duePrayerOffset == 30)
        let lastNight = read("أصلي آخر الليل")
        #expect(lastNight.duePrayer == .fajr)
        #expect(lastNight.duePrayerOffset == -60)
        #expect(read("أشحن الجوال قبل النوم").dueTime == "22:00")
    }

    @Test func days() {
        #expect(read("أدفع الفاتورة بكرة").dueDate == "2026-10-14")
        #expect(read("أدفع الفاتورة بعد بكرة").dueDate == "2026-10-15")
        #expect(read("أدفع الفاتورة بعد ٣ أيام").dueDate == "2026-10-16")
        #expect(read("أدفع الفاتورة يوم الخميس").dueDate == "2026-10-15")
        #expect(read("أدفع الفاتورة الثلاثاء الجاي").dueDate == "2026-10-20")
        #expect(read("أدفع الفاتورة الأسبوع الجاي").dueDate == "2026-10-20")
        let today = read("أدفع الفاتورة اليوم")
        #expect(today.dueDate == "2026-10-13")
        #expect(today.title == "أدفع الفاتورة")
    }

    @Test func clockTimes() {
        let reading = read("اتصل بأحمد الخميس الساعة ٥ العصر")
        #expect(reading.title == "اتصل بأحمد")
        #expect(reading.dueDate == "2026-10-15")
        #expect(reading.dueTime == "17:00")
        #expect(read("اجتماع الساعة 5:30").dueTime == "17:30")
        #expect(read("اجتماع الساعة ٥ ونص").dueTime == "17:30")
        #expect(read("اجتماع الساعة ٥ إلا ربع").dueTime == "16:45")
        #expect(read("أمشي ٩ الصبح").dueTime == "09:00")
        // 9 in the morning has passed at noon, so tomorrow.
        #expect(read("أمشي ٩ الصبح").dueDate == "2026-10-14")
        #expect(read("أمشي ١٠ الليل").dueTime == "22:00")
    }

    @Test func partsOfTheDay() {
        #expect(read("أراجع البريد بكرة الصبح").dueTime == "09:00")
        #expect(read("أقرأ الضحى").dueTime == "09:30")
        let tonight = read("أتصل بخالي الليلة")
        #expect(tonight.dueDate == "2026-10-13")
        #expect(tonight.dueTime == "21:00")
    }

    @Test func fromNow() {
        let reading = read("أطفي الفرن بعد ساعتين")
        #expect(reading.title == "أطفي الفرن")
        #expect(reading.dueDate == "2026-10-13")
        #expect(reading.dueTime == "14:00")
        #expect(read("أطفي الفرن بعد نص ساعة").dueTime == "12:30")
        #expect(read("أطفي الفرن بعد ٢٠ دقيقة").dueTime == "12:20")
    }

    @Test func aSentenceWithoutATimeStaysAsItIs() {
        let reading = read("ذكرني أشتري خبز")
        #expect(reading.title == "أشتري خبز")
        #expect(!reading.hasWhen)
        #expect(read("بعد").title == "بعد")
    }

    @Test func theLocalReadingFillsInForTheAssistant() {
        let spoken = SpokenTask.local("ذكرني أراجع العقد بعد العصر بكرة", problem: .offline, now: now, timeZone: riyadh)
        #expect(spoken.problem == .offline)
        #expect(spoken.readLocally)
        #expect(spoken.suggestion.title == "أراجع العقد")
        let record = spoken.record(today: "2026-10-13")
        #expect(record.duePrayer == .asr)
        #expect(record.dueDate == "2026-10-14")
    }
}
