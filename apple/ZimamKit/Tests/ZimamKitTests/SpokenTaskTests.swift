import Foundation
import Testing
@testable import ZimamKit

struct SpokenTaskTests {
    @Test func theAssistantsReadingBecomesTheRecord() {
        let suggestion = TaskSuggestion(title: "مراجعة العقد", notes: "  ", dueDate: "2026-10-16", duePrayer: .asr,
                                        duePrayerOffset: 30, priority: .high, tags: ["عمل"])
        let record = SpokenTask(suggestion: suggestion).record(today: "2026-10-15")
        #expect(record.title == "مراجعة العقد")
        #expect(record.notes == nil)
        #expect(record.dueDate == "2026-10-16")
        #expect(record.duePrayer == .asr)
        #expect(record.duePrayerOffset == 30)
        #expect(record.dueTime == nil)
        #expect(record.priority == .high)
        #expect(record.tags == ["عمل"])
    }

    @Test func aPrayerWithoutADayIsToday() {
        let record = SpokenTask(suggestion: TaskSuggestion(title: "اتصال بأبي", duePrayer: .maghrib)).record(today: "2026-10-15")
        #expect(record.dueDate == "2026-10-15")
        #expect(record.duePrayerOffset == 0)
    }

    @Test func aTimeNeedsADayAndNoPrayer() {
        let undated = SpokenTask(suggestion: TaskSuggestion(title: "شراء الخبز", dueTime: "21:30")).record(today: "2026-10-15")
        #expect(undated.dueDate == nil)
        #expect(undated.dueTime == nil)

        let dated = SpokenTask(suggestion: TaskSuggestion(title: "شراء الخبز", dueDate: "2026-10-15", dueTime: "21:30"))
            .record(today: "2026-10-15")
        #expect(dated.dueTime == "21:30")
    }

    @Test func theWatchDefaultsToToday() {
        let record = SpokenTask(text: "  اشتر الحليب ", problem: .offline).record(today: "2026-10-15", defaultDueDate: "2026-10-15")
        #expect(record.title == "اشتر الحليب")
        #expect(record.dueDate == "2026-10-15")
        #expect(record.duePrayer == nil)
    }

    @Test func theSentenceIsKeptWhenTheAssistantCannotReadIt() {
        let spoken = SpokenTask(text: "ذكرني أراجع العقد بعد العصر بكرة", problem: .proRequired)
        #expect(!spoken.isRead)
        #expect(spoken.suggestion.title == "ذكرني أراجع العقد بعد العصر بكرة")
        #expect(spoken.suggestion.priority == TaskPriority.none)
        #expect(spoken.suggestion.dueDate == nil)
        #expect(SpokenTask(suggestion: TaskSuggestion(title: "مهمة")).isRead)
    }
}
