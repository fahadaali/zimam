import XCTest
@testable import ZimamKit

final class AssistantTests: XCTestCase {
    private let formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"),
                                              timeZone: TimeZone(identifier: "Asia/Riyadh")!)

    func testDecodesTaskSuggestionInTheServerShape() throws {
        // As in api/test/assistant-ai.test.ts: a prayer-anchored task with a named priority.
        let json = #"{"title":"مراجعة العقد","dueDate":"2026-10-15","duePrayer":"maghrib","duePrayerOffset":0,"priority":"medium","tags":["عمل"]}"#
        let suggestion = try JSONDecoder().decode(TaskSuggestion.self, from: Data(json.utf8))
        XCTAssertEqual(suggestion.title, "مراجعة العقد")
        XCTAssertEqual(suggestion.dueDate, "2026-10-15")
        XCTAssertNil(suggestion.dueTime)
        XCTAssertEqual(suggestion.duePrayer, .maghrib)
        XCTAssertEqual(suggestion.duePrayerOffset, 0)
        XCTAssertEqual(suggestion.priority, .medium)
        XCTAssertEqual(suggestion.tags, ["عمل"])
        XCTAssertNil(suggestion.projectId)
        XCTAssertNil(suggestion.notes)
    }

    func testDecodesSuggestionWithTimeAndLowercaseProject() throws {
        let json = #"{"title":"شراء الخبز","dueDate":"2026-10-13","dueTime":"21:30","priority":"high","tags":[],"projectId":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","notes":"من المخبز"}"#
        let suggestion = try JSONDecoder().decode(TaskSuggestion.self, from: Data(json.utf8))
        XCTAssertEqual(suggestion.dueTime, "21:30")
        XCTAssertEqual(suggestion.priority, .high)
        XCTAssertEqual(suggestion.projectId, UUID(uuidString: "2A3B4C5D-6E7F-4801-9234-56789ABCDEF0"))
        XCTAssertEqual(suggestion.notes, "من المخبز")
        XCTAssertNil(suggestion.duePrayer)
    }

    func testSuggestionToleratesMissingAndUnknownFields() throws {
        // Only the title is required; a numeric priority and an unknown prayer still decode.
        let minimal = try JSONDecoder().decode(TaskSuggestion.self, from: Data(#"{"title":"مهمة"}"#.utf8))
        XCTAssertEqual(minimal.priority, TaskPriority.none)
        XCTAssertEqual(minimal.tags, [])

        let odd = try JSONDecoder().decode(TaskSuggestion.self, from: Data(#"{"title":"مهمة","priority":2,"duePrayer":"jumuah"}"#.utf8))
        XCTAssertEqual(odd.priority, .medium)
        XCTAssertNil(odd.duePrayer)
    }

    func testPriorityNames() {
        XCTAssertEqual(TaskPriority(name: "none"), TaskPriority.none)
        XCTAssertEqual(TaskPriority(name: "low"), .low)
        XCTAssertEqual(TaskPriority(name: "HIGH"), .high)
        XCTAssertNil(TaskPriority(name: "urgent"))
        XCTAssertEqual(TaskPriority.high.arabicName, "عالية")
    }

    func testDecodesSubtasksAndSummary() throws {
        let subtasks = try JSONDecoder().decode(SubtaskSuggestions.self,
                                                from: Data(#"{"subtasks":["جمع المستندات","تعبئة النموذج","حجز الموعد"]}"#.utf8))
        XCTAssertEqual(subtasks.subtasks.count, 3)
        XCTAssertEqual(subtasks.subtasks[0], "جمع المستندات")

        let summary = try JSONDecoder().decode(DaySummary.self,
                                               from: Data(#"{"date":"2026-10-20","text":"لا مهام لهذا اليوم ولا مهام متأخرة. يومك متاح."}"#.utf8))
        XCTAssertEqual(summary, DaySummary(date: "2026-10-20", text: "لا مهام لهذا اليوم ولا مهام متأخرة. يومك متاح."))
    }

    func testClassifiesAssistantErrors() {
        let quota = APIError(status: 429, code: "ai_quota_exceeded", message: "", limit: 300, resetsOn: "2026-11-01")
        XCTAssertEqual(AssistantProblem(quota), .quotaExceeded(limit: 300, resetsOn: "2026-11-01"))
        XCTAssertEqual(AssistantProblem(APIError(status: 503, code: "ai_unavailable", message: "")), .unavailable)
        XCTAssertEqual(AssistantProblem(APIError(status: 404, code: "not_found", message: "")), .notFound)
        XCTAssertEqual(AssistantProblem(APIError(status: 400, code: "invalid", message: "")), .invalidInput)
        XCTAssertEqual(AssistantProblem(APIError(status: 401, code: "unauthorized", message: "")), .signedOut)
        XCTAssertEqual(AssistantProblem(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(AssistantProblem(URLError(.badServerResponse)), .other)
    }

    func testQuotaMessageNamesTheLimitAndBothCalendars() {
        let message = AssistantProblem.quotaExceeded(limit: 300, resetsOn: "2026-11-01").message(formatter: formatter)
        XCTAssertTrue(message.contains("٣٠٠"), message)
        XCTAssertTrue(message.contains("لم يبقَ"), message)
        // 1 November 2026 is 21 Jumada al-Ula 1448 (Umm al-Qura), joined with the Arabic comma.
        XCTAssertTrue(message.contains("٢١ جمادى الأولى، ١ نوفمبر"), message)
        XCTAssertFalse(message.contains("·"))

        let bare = AssistantProblem.quotaExceeded(limit: nil, resetsOn: nil).message(formatter: formatter)
        XCTAssertEqual(bare, "استعملت كل طلبات المساعد لهذا الشهر، ولم يبقَ منها شيء.")
    }

    func testDecodesQuotaErrorBodyFields() throws {
        // The transport decodes these from { error: { code, message, limit, resetsOn } }.
        let error = APIError(status: 429, code: "ai_quota_exceeded", message: "limit", limit: 300, resetsOn: "2026-11-01")
        XCTAssertEqual(error.limit, 300)
        XCTAssertEqual(error.resetsOn, "2026-11-01")
        XCTAssertNil(APIError(status: 503, code: "ai_unavailable", message: "").limit)
    }

    func testDeviceTimeIsSentWithItsOffset() {
        let date = Date(timeIntervalSince1970: 1_791_878_400) // 2026-10-13T08:00:00Z
        let text = APIClient.isoString(date, timeZone: TimeZone(identifier: "Asia/Riyadh")!)
        XCTAssertEqual(text, "2026-10-13T11:00:00+03:00")
    }
}
