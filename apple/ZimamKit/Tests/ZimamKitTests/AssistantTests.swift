import Foundation
import Testing
@testable import ZimamKit

struct AssistantTests {
    private let formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"),
                                              timeZone: TimeZone(identifier: "Asia/Riyadh")!)

    @Test func decodesTaskSuggestionInTheServerShape() throws {
        // As in api/test/assistant-ai.test.ts: a prayer-anchored task with a named priority.
        let json = #"{"title":"مراجعة العقد","dueDate":"2026-10-15","duePrayer":"maghrib","duePrayerOffset":0,"priority":"medium","tags":["عمل"]}"#
        let suggestion = try JSONDecoder().decode(TaskSuggestion.self, from: Data(json.utf8))
        #expect(suggestion.title == "مراجعة العقد")
        #expect(suggestion.dueDate == "2026-10-15")
        #expect(suggestion.dueTime == nil)
        #expect(suggestion.duePrayer == .maghrib)
        #expect(suggestion.duePrayerOffset == 0)
        #expect(suggestion.priority == .medium)
        #expect(suggestion.tags == ["عمل"])
        #expect(suggestion.projectId == nil)
        #expect(suggestion.notes == nil)
    }

    @Test func decodesSuggestionWithTimeAndLowercaseProject() throws {
        let json = #"{"title":"شراء الخبز","dueDate":"2026-10-13","dueTime":"21:30","priority":"high","tags":[],"projectId":"2a3b4c5d-6e7f-4801-9234-56789abcdef0","notes":"من المخبز"}"#
        let suggestion = try JSONDecoder().decode(TaskSuggestion.self, from: Data(json.utf8))
        #expect(suggestion.dueTime == "21:30")
        #expect(suggestion.priority == .high)
        #expect(suggestion.projectId == UUID(uuidString: "2A3B4C5D-6E7F-4801-9234-56789ABCDEF0"))
        #expect(suggestion.notes == "من المخبز")
        #expect(suggestion.duePrayer == nil)
    }

    @Test func suggestionToleratesMissingAndUnknownFields() throws {
        // Only the title is required; a numeric priority and an unknown prayer still decode.
        let minimal = try JSONDecoder().decode(TaskSuggestion.self, from: Data(#"{"title":"مهمة"}"#.utf8))
        #expect(minimal.priority == TaskPriority.none)
        #expect(minimal.tags == [])

        let odd = try JSONDecoder().decode(TaskSuggestion.self, from: Data(#"{"title":"مهمة","priority":2,"duePrayer":"jumuah"}"#.utf8))
        #expect(odd.priority == .medium)
        #expect(odd.duePrayer == nil)
    }

    @Test func priorityNames() {
        #expect(TaskPriority(name: "none") == TaskPriority.none)
        #expect(TaskPriority(name: "low") == .low)
        #expect(TaskPriority(name: "HIGH") == .high)
        #expect(TaskPriority(name: "urgent") == nil)
        #expect(TaskPriority.high.arabicName == "عالية")
    }

    @Test func decodesSubtasksAndSummary() throws {
        let subtasks = try JSONDecoder().decode(SubtaskSuggestions.self,
                                                from: Data(#"{"subtasks":["جمع المستندات","تعبئة النموذج","حجز الموعد"]}"#.utf8))
        #expect(subtasks.subtasks.count == 3)
        #expect(subtasks.subtasks[0] == "جمع المستندات")

        let summary = try JSONDecoder().decode(DaySummary.self,
                                               from: Data(#"{"date":"2026-10-20","text":"لا مهام لهذا اليوم ولا مهام متأخرة. يومك متاح."}"#.utf8))
        #expect(summary == DaySummary(date: "2026-10-20", text: "لا مهام لهذا اليوم ولا مهام متأخرة. يومك متاح."))
    }

    @Test func classifiesAssistantErrors() {
        let quota = APIError(status: 429, code: "ai_quota_exceeded", message: "", limit: 300, resetsOn: "2026-11-01")
        #expect(AssistantProblem(quota) == .quotaExceeded(limit: 300, resetsOn: "2026-11-01"))
        #expect(AssistantProblem(APIError(status: 503, code: "ai_unavailable", message: "")) == .unavailable)
        #expect(AssistantProblem(APIError(status: 404, code: "not_found", message: "")) == .notFound)
        #expect(AssistantProblem(APIError(status: 400, code: "invalid", message: "")) == .invalidInput)
        #expect(AssistantProblem(APIError(status: 401, code: "unauthorized", message: "")) == .signedOut)
        #expect(AssistantProblem(URLError(.notConnectedToInternet)) == .offline)
        #expect(AssistantProblem(URLError(.badServerResponse)) == .other)
    }

    @Test func quotaMessageNamesTheLimitAndBothCalendars() {
        let message = AssistantProblem.quotaExceeded(limit: 300, resetsOn: "2026-11-01").message(formatter: formatter)
        #expect(message.contains("٣٠٠"), Comment(rawValue: message))
        #expect(message.contains("لم يبقَ"), Comment(rawValue: message))
        // 1 November 2026 is 21 Jumada al-Ula 1448 (Umm al-Qura), joined with the Arabic comma.
        #expect(message.contains("٢١ جمادى الأولى، ١ نوفمبر"), Comment(rawValue: message))
        #expect(!message.contains("·"))

        let bare = AssistantProblem.quotaExceeded(limit: nil, resetsOn: nil).message(formatter: formatter)
        #expect(bare == "استعملت كل طلبات المساعد لهذا الشهر، ولم يبقَ منها شيء.")
    }

    @Test func decodesQuotaErrorBodyFields() throws {
        // The transport decodes these from { error: { code, message, limit, resetsOn } }.
        let error = APIError(status: 429, code: "ai_quota_exceeded", message: "limit", limit: 300, resetsOn: "2026-11-01")
        #expect(error.limit == 300)
        #expect(error.resetsOn == "2026-11-01")
        #expect(APIError(status: 503, code: "ai_unavailable", message: "").limit == nil)
    }

    @Test func deviceTimeIsSentWithItsOffset() {
        let date = Date(timeIntervalSince1970: 1_791_878_400) // 2026-10-13T08:00:00Z
        let text = APIClient.isoString(date, timeZone: TimeZone(identifier: "Asia/Riyadh")!)
        #expect(text == "2026-10-13T11:00:00+03:00")
    }
}
