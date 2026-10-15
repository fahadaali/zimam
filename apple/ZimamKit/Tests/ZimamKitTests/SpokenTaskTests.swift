import XCTest
@testable import ZimamKit

final class SpokenTaskTests: XCTestCase {
    func testTheAssistantsReadingBecomesTheRecord() {
        let suggestion = TaskSuggestion(title: "مراجعة العقد", notes: "  ", dueDate: "2026-10-16", duePrayer: .asr,
                                        duePrayerOffset: 30, priority: .high, tags: ["عمل"])
        let record = SpokenTask(suggestion: suggestion).record(today: "2026-10-15")
        XCTAssertEqual(record.title, "مراجعة العقد")
        XCTAssertNil(record.notes)
        XCTAssertEqual(record.dueDate, "2026-10-16")
        XCTAssertEqual(record.duePrayer, .asr)
        XCTAssertEqual(record.duePrayerOffset, 30)
        XCTAssertNil(record.dueTime)
        XCTAssertEqual(record.priority, .high)
        XCTAssertEqual(record.tags, ["عمل"])
    }

    func testAPrayerWithoutADayIsToday() {
        let record = SpokenTask(suggestion: TaskSuggestion(title: "اتصال بأبي", duePrayer: .maghrib)).record(today: "2026-10-15")
        XCTAssertEqual(record.dueDate, "2026-10-15")
        XCTAssertEqual(record.duePrayerOffset, 0)
    }

    func testATimeNeedsADayAndNoPrayer() {
        let undated = SpokenTask(suggestion: TaskSuggestion(title: "شراء الخبز", dueTime: "21:30")).record(today: "2026-10-15")
        XCTAssertNil(undated.dueDate)
        XCTAssertNil(undated.dueTime)

        let dated = SpokenTask(suggestion: TaskSuggestion(title: "شراء الخبز", dueDate: "2026-10-15", dueTime: "21:30"))
            .record(today: "2026-10-15")
        XCTAssertEqual(dated.dueTime, "21:30")
    }

    func testTheWatchDefaultsToToday() {
        let record = SpokenTask(text: "  اشتر الحليب ", problem: .offline).record(today: "2026-10-15", defaultDueDate: "2026-10-15")
        XCTAssertEqual(record.title, "اشتر الحليب")
        XCTAssertEqual(record.dueDate, "2026-10-15")
        XCTAssertNil(record.duePrayer)
    }

    func testTheSentenceIsKeptWhenTheAssistantCannotReadIt() {
        let spoken = SpokenTask(text: "ذكرني أراجع العقد بعد العصر بكرة", problem: .proRequired)
        XCTAssertFalse(spoken.isRead)
        XCTAssertEqual(spoken.suggestion.title, "ذكرني أراجع العقد بعد العصر بكرة")
        XCTAssertEqual(spoken.suggestion.priority, TaskPriority.none)
        XCTAssertNil(spoken.suggestion.dueDate)
        XCTAssertTrue(SpokenTask(suggestion: TaskSuggestion(title: "مهمة")).isRead)
    }
}
